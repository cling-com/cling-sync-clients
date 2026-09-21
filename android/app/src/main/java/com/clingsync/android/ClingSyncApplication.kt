package com.clingsync.android

import android.app.Application
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.work.WorkManager
import com.clingsync.android.ui.removeBrowseTempFiles
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

class ClingSyncApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Decrypted leftovers of a process that died with browse open.
        removeBrowseTempFiles(this)
        ProcessLifecycleOwner.get().lifecycle.addObserver(
            RepositoryCloser(
                workManager = { WorkManager.getInstance(this) },
                scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
            ),
        )
    }
}
