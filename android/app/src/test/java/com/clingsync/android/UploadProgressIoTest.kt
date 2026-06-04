package com.clingsync.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.clingsync.android.data.UploadProgressIo
import com.clingsync.android.data.UploadStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [28])
class UploadProgressIoTest {
    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun progressMapsEveryStatus() {
        val file = tmp.newFile("status.json")
        UploadProgressIo.write(
            file,
            mapOf(
                "a" to UploadStatus.WAITING,
                "b" to UploadStatus.UPLOADING,
                "c" to UploadStatus.UPLOADED,
                "d" to UploadStatus.SKIPPED,
                "e" to UploadStatus.COMMITTING,
            ),
        )

        val progress = UploadProgressIo.readProgress(file)

        assertEquals(FileStatus.Waiting, progress["a"])
        assertEquals(FileStatus.Uploading, progress["b"])
        assertEquals(FileStatus.Uploaded, progress["c"])
        assertEquals(FileStatus.Exists(""), progress["d"])
        assertEquals(FileStatus.Committing, progress["e"])
    }

    @Test
    fun resultKeepsTerminalStatusesAndDropsInProgressOnes() {
        val file = tmp.newFile("result.json")
        UploadProgressIo.write(
            file,
            mapOf(
                "committed" to UploadStatus.COMMITTING,
                "uploaded" to UploadStatus.UPLOADED,
                "skipped" to UploadStatus.SKIPPED,
                "waiting" to UploadStatus.WAITING,
                "uploading" to UploadStatus.UPLOADING,
            ),
        )

        val result = UploadProgressIo.readResult(file)

        assertEquals(FileStatus.Done, result["committed"])
        assertEquals(FileStatus.Done, result["uploaded"])
        assertEquals(FileStatus.Exists(""), result["skipped"])
        // Non-terminal states must not overwrite existing UI state on completion.
        assertNull(result["waiting"])
        assertNull(result["uploading"])
        assertEquals(3, result.size)
    }

    @Test
    fun unknownWireStringIsTreatedAsNewAndNonTerminal() {
        val file = tmp.newFile("legacy.json")
        file.writeText("""{"x":"some-future-status"}""")

        assertEquals(FileStatus.New, UploadProgressIo.readProgress(file)["x"])
        assertNull(UploadProgressIo.readResult(file)["x"])
    }
}
