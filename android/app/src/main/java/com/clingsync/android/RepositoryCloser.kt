package com.clingsync.android

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.work.WorkManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

// Closes the open repository after the whole app (any Activity, including the share
// screen) has been in the background past a grace period, so the decrypted repository
// does not linger in memory. Observes the process lifecycle, not a single Activity,
// so a side trip to a system screen (folder picker, storage settings) within the
// grace period costs no re-authentication. An upload survives backgrounding in
// WorkManager, so the close waits for it and runs as soon as it finishes. The
// persisted file-hash index is kept (closeRepository keeps it), so a running scan
// and the headless merge reminder keep answering. Each Activity re-opens on its
// next start via MainViewModel.onResumed.
class RepositoryCloser(
    // Resolved lazily: WorkManager and the bridge may not be initialized yet when
    // the Application registers this observer.
    private val workManager: () -> WorkManager,
    private val scope: CoroutineScope,
    private val graceMillis: Long = GRACE_MILLIS,
    private val bridge: () -> IGoBridge = { GoBridgeProvider.getInstance() },
) : DefaultLifecycleObserver {
    private var closeJob: Job? = null

    override fun onStop(owner: LifecycleOwner) {
        closeJob?.cancel()
        closeJob =
            scope.launch {
                delay(graceMillis)
                workManager()
                    .getWorkInfosForUniqueWorkFlow(UploadWorker.WORK_NAME)
                    .first { infos -> infos.all { it.state.isFinished } }
                // Past the last suspension point a cancel can no longer stop this job,
                // and a process frozen by the OS resumes the delay exactly when the
                // user returns: never drop the repository under a foreground app.
                if (owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) return@launch
                bridge().closeRepository()
            }
    }

    override fun onStart(owner: LifecycleOwner) {
        closeJob?.cancel()
        closeJob = null
    }

    companion object {
        const val GRACE_MILLIS = 30_000L
    }
}
