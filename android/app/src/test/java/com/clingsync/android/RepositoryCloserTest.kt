package com.clingsync.android

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.work.WorkInfo
import androidx.work.WorkManager
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Test
import org.mockito.kotlin.mock
import org.mockito.kotlin.never
import org.mockito.kotlin.verify
import org.mockito.kotlin.whenever
import java.util.UUID

@OptIn(ExperimentalCoroutinesApi::class)
class RepositoryCloserTest {
    private val lifecycle = mock<Lifecycle>()
    private val owner = mock<LifecycleOwner>()
    private val bridge = mock<IGoBridge>()

    init {
        whenever(owner.lifecycle).thenReturn(lifecycle)
        whenever(lifecycle.currentState).thenReturn(Lifecycle.State.CREATED)
    }

    private fun workManagerWith(infos: MutableStateFlow<List<WorkInfo>>): () -> WorkManager {
        val workManager = mock<WorkManager>()
        whenever(workManager.getWorkInfosForUniqueWorkFlow(UploadWorker.WORK_NAME)).thenReturn(infos)
        return { workManager }
    }

    private fun workInfo(state: WorkInfo.State) = WorkInfo(UUID.randomUUID(), state, emptySet())

    @Test
    fun closesAfterTheGracePeriod() =
        runTest {
            val workManager = workManagerWith(MutableStateFlow(emptyList()))
            val closer = RepositoryCloser(workManager, backgroundScope, graceMillis = 30_000) { bridge }
            closer.onStop(owner)
            advanceTimeBy(29_999)
            runCurrent()
            verify(bridge, never()).closeRepository()
            advanceTimeBy(2)
            runCurrent()
            verify(bridge).closeRepository()
        }

    @Test
    fun returningWithinTheGracePeriodCancelsTheClose() =
        runTest {
            val workManager = workManagerWith(MutableStateFlow(emptyList()))
            val closer = RepositoryCloser(workManager, backgroundScope, graceMillis = 30_000) { bridge }
            closer.onStop(owner)
            advanceTimeBy(10_000)
            closer.onStart(owner)
            advanceTimeBy(60_000)
            runCurrent()
            verify(bridge, never()).closeRepository()
        }

    @Test
    fun waitsForARunningUploadThenCloses() =
        runTest {
            val infos = MutableStateFlow(listOf(workInfo(WorkInfo.State.RUNNING)))
            val closer = RepositoryCloser(workManagerWith(infos), backgroundScope, graceMillis = 30_000) { bridge }
            closer.onStop(owner)
            advanceTimeBy(60_000)
            runCurrent()
            verify(bridge, never()).closeRepository()
            infos.value = listOf(workInfo(WorkInfo.State.SUCCEEDED))
            runCurrent()
            verify(bridge).closeRepository()
        }

    @Test
    fun returningWhileWaitingForAnUploadCancelsTheClose() =
        runTest {
            val infos = MutableStateFlow(listOf(workInfo(WorkInfo.State.RUNNING)))
            val closer = RepositoryCloser(workManagerWith(infos), backgroundScope, graceMillis = 30_000) { bridge }
            closer.onStop(owner)
            advanceTimeBy(60_000)
            closer.onStart(owner)
            infos.value = listOf(workInfo(WorkInfo.State.SUCCEEDED))
            runCurrent()
            verify(bridge, never()).closeRepository()
        }

    @Test
    fun skipsTheCloseWhenTheAppIsAlreadyForegroundAgain() =
        runTest {
            val workManager = workManagerWith(MutableStateFlow(emptyList()))
            val closer = RepositoryCloser(workManager, backgroundScope, graceMillis = 30_000) { bridge }
            closer.onStop(owner)
            whenever(lifecycle.currentState).thenReturn(Lifecycle.State.STARTED)
            advanceTimeBy(60_000)
            runCurrent()
            verify(bridge, never()).closeRepository()
        }
}
