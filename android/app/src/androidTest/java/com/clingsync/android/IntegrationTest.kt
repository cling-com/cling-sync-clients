@file:OptIn(ExperimentalTestApi::class)

package com.clingsync.android

import android.Manifest
import android.content.Context
import android.os.Environment
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.test.espresso.Espresso
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import org.junit.Rule
import org.junit.Test
import org.junit.rules.ExternalResource
import org.junit.runner.RunWith
import java.io.File
import java.net.Socket

/**
 * End-to-end smoke/acceptance test driving the real app against real Go bridges
 * and in-process S3 servers started by the Go harness (android/go/main_test.go).
 * Config is delivered via instrumentation runner arguments; the fallbacks let
 * the happy-path test run against a manually-started server too.
 *
 * The scratch repository is wrapped in a fault injector reachable over its
 * `/__test/...` control endpoints, so the upload-failure and abort paths run
 * within a single emulator session. The Go side asserts which repositories did
 * (and did not) receive commits.
 */
@RunWith(AndroidJUnit4::class)
class IntegrationTest {
    private val args = InstrumentationRegistry.getArguments()
    private val serverUrl = args.getString("serverUrl") ?: "s3+http://10.0.2.2:9124"
    private val embeddedUrl = args.getString("embeddedUrl")
    private val switchUrl = args.getString("switchUrl")
    private val scratchUrl = args.getString("scratchUrl")
    private val reattachUrl = args.getString("reattachUrl")
    private val testPassphrase = args.getString("passphrase") ?: "testpassphrase"
    private val wrongPassphrase = args.getString("wrongPassphrase") ?: "definitely-the-wrong-passphrase"
    private val testS3AccessKeyId = args.getString("s3KeyId") ?: "minioadmin"
    private val testS3AccessKey = args.getString("s3Key") ?: "minioadmin"
    private val destination = args.getString("destination") ?: "/phone/"
    private val switchDestination = args.getString("switchDestination") ?: "/switched/"
    private val mediaSubUrl = args.getString("mediaSubUrl")
    private val docsSubUrl = args.getString("docsSubUrl")

    // Runs BEFORE the Activity launches (lower order = outer), so each test starts
    // with cleared settings/keychain. A plain @Before runs after the compose rule
    // has already launched the Activity, which would leave the prior test's saved
    // settings in place and break isolation.
    @get:Rule(order = 0)
    val clearState =
        object : ExternalResource() {
            override fun before() {
                val context = InstrumentationRegistry.getInstrumentation().targetContext
                context.getSharedPreferences("cling_sync_prefs", Context.MODE_PRIVATE).edit().clear().commit()
                // The encoded-URI store is a separate prefs file; a successful connect
                // persists a URI here that would otherwise skip the S3 prompt next test.
                context.getSharedPreferences("repository_uris", Context.MODE_PRIVATE).edit().clear().commit()
                PassphraseStore(context).deleteAll()
                scratchUrl?.let { runCatching { control(it, "reset") } }
                reattachUrl?.let { runCatching { control(it, "reset") } }
            }
        }

    @get:Rule(order = 1)
    val permissionRule: GrantPermissionRule =
        GrantPermissionRule.grant(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
            Manifest.permission.READ_EXTERNAL_STORAGE,
            Manifest.permission.WRITE_EXTERNAL_STORAGE,
            Manifest.permission.POST_NOTIFICATIONS,
        )

    @get:Rule(order = 2)
    val composeTestRule = createAndroidComposeRule<MainActivity>()

    // --- Helpers -------------------------------------------------------------

    // Toggles fault injection on an S3 server, e.g. "fail-writes?on=true".
    // Uses a raw socket: Android blocks cleartext HTTP through HttpURLConnection,
    // while the native Go bridge the app relies on is exempt from that policy.
    private fun control(
        serverUrl: String,
        query: String,
    ) {
        val authority = serverUrl.removePrefix("s3+http://")
        val host = authority.substringBefore(":")
        val port = authority.substringAfter(":").toInt()
        Socket(host, port).use { socket ->
            socket.soTimeout = 5000
            socket.getOutputStream().write(
                "POST /__test/$query HTTP/1.1\r\nHost: $authority\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
                    .toByteArray(),
            )
            val status = socket.getInputStream().bufferedReader().readLine() ?: ""
            check(status.contains("200")) { "control endpoint $query returned: $status" }
        }
    }

    private fun scratchControl(query: String) {
        control(scratchUrl ?: return, query)
    }

    private fun fillFreshSettings(
        hostUrl: String,
        dest: String,
    ) {
        composeTestRule.waitUntilExactlyOneExists(hasText("Host URL"), 5000)
        composeTestRule.onNodeWithText("Host URL").performClick()
        composeTestRule.onNodeWithText("Host URL").performTextInput(hostUrl)
        composeTestRule.onNodeWithText("Destination Path (optional)").performClick()
        composeTestRule.onNodeWithText("Destination Path (optional)").performTextInput(dest)
        composeTestRule.onNodeWithText("Author").performClick()
        composeTestRule.onNodeWithText("Author").performTextReplacement("Testinger")
    }

    private fun enterPassphrase(passphrase: String) {
        composeTestRule.waitUntilExactlyOneExists(hasText("Enter Passphrase"), 5000)
        composeTestRule.onNodeWithText("Passphrase").performClick()
        composeTestRule.onNodeWithText("Passphrase").performTextInput(passphrase)
        composeTestRule.onNodeWithText("Continue").performClick()
    }

    private fun enterS3Credentials() {
        composeTestRule.waitUntilExactlyOneExists(hasText("S3 Credentials"), 5000)
        composeTestRule.onNodeWithText("S3 Key ID").performClick()
        composeTestRule.onNodeWithText("S3 Key ID").performTextInput(testS3AccessKeyId)
        composeTestRule.onNodeWithText("S3 Access Key").performClick()
        composeTestRule.onNodeWithText("S3 Access Key").performTextInput(testS3AccessKey)
        composeTestRule.onNodeWithText("Continue").performClick()
    }

    // Configures a fresh repo and connects (Test -> passphrase -> S3 creds),
    // leaving the still-open Settings dialog ready for Save.
    private fun connectFreshRepo(
        hostUrl: String,
        dest: String,
        passphrase: String,
    ) {
        fillFreshSettings(hostUrl, dest)
        composeTestRule.onNodeWithText("Test").performClick()
        enterPassphrase(passphrase)
        enterS3Credentials()
    }

    private fun saveAndWaitForList() {
        composeTestRule.waitUntilExactlyOneExists(hasText("Save"), 15000)
        composeTestRule.onNodeWithText("Save").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("select_all_button"), 15000)
    }

    private fun selectFile(name: String) {
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("checkbox_$name"), 10000)
        composeTestRule.onNodeWithText(name, substring = true).performClick()
    }

    private fun upload() {
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("upload_button").and(isEnabled()), 5000)
        composeTestRule.onNodeWithText("Upload").performClick()
    }

    // Replaces the Source Directory field (which shows the DCIM default on a fresh
    // install) with the given path.
    private fun setSourceDirectory(path: String) {
        composeTestRule.onNodeWithText(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM).absolutePath,
        ).performTextReplacement(path)
    }

    private fun uncheckMediaOnly() {
        composeTestRule.onNodeWithTag("media_only_checkbox").performScrollTo().performClick()
    }

    // Opens Settings on the already-connected screen. Changes saved here reach the
    // reducer as a genuine settings diff, unlike on the first-run dialog where a
    // preceding "Test" already commits the dialog values into the state.
    private fun reopenSettings() {
        composeTestRule.onNode(hasContentDescription("Settings")).performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("Source Directory"), 5000)
    }

    // --- Tests ---------------------------------------------------------------

    @Test
    fun testBackupFiles() {
        composeTestRule.waitForIdle()

        // First-run setup: an invalid Host URL must surface the validation dialog.
        composeTestRule.waitUntilExactlyOneExists(hasText("Host URL"), 5000)
        composeTestRule.onNodeWithText("Host URL").performClick()
        composeTestRule.onNodeWithText("Host URL").performTextInput("https://wrong.example.com")
        composeTestRule.onNodeWithText("Author").performClick()
        composeTestRule.onNodeWithText("Author").performTextReplacement("Testinger")
        composeTestRule.onNodeWithText("Test").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("Invalid Host URL"), 5000)
        composeTestRule.onNodeWithText("OK").performClick()
        composeTestRule.onNodeWithText("Host URL").performTextReplacement(serverUrl)
        composeTestRule.onNodeWithText("Destination Path (optional)").performClick()
        composeTestRule.onNodeWithText("Destination Path (optional)").performTextInput(destination)

        composeTestRule.onNodeWithText("Test").performClick()
        enterPassphrase(testPassphrase)
        enterS3Credentials()
        saveAndWaitForList()

        // Upload three DCIM files (leaving green_grass and its subfolder peer alone).
        selectFile("blue_sky.jpg")
        selectFile("red_earth.jpg")
        selectFile("sunset.jpg")
        upload()
        composeTestRule.waitUntilNodeCount(hasContentDescription("Synced"), 3, 15000)

        // Relaunch: the in-process bridge keeps repo A open, so the app must
        // reconnect WITHOUT a passphrase prompt and, on the fresh scan, report
        // the three uploaded files as already-synced (dedup via the real bridge).
        composeTestRule.activityRule.scenario.recreate()
        composeTestRule.waitForIdle()
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("select_all_button"), 15000)
        composeTestRule.waitUntilNodeCount(hasContentDescription("Synced"), 3, 15000)
        composeTestRule.onAllNodesWithText("Enter Passphrase").assertCountEquals(0)
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("checkbox_green_grass.jpg"), 10000)

        // Select All must pick only the still-new file (green_grass), not the synced ones.
        composeTestRule.onNodeWithTag("select_all_button").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("1 file", substring = true), 5000)
        upload()
        composeTestRule.waitUntilNodeCount(hasContentDescription("Synced"), 4, 15000)

        // Switch to a custom folder with a new destination prefix.
        composeTestRule.onNode(hasContentDescription("Settings")).performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("Source Directory"), 5000)
        val customDir = "${Environment.getExternalStorageDirectory().path}/ClingSyncTest"
        composeTestRule.onNodeWithText("Source Directory").performClick()
        composeTestRule.onNodeWithText(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM).absolutePath,
        ).performTextReplacement(customDir)
        composeTestRule.onNodeWithText("Destination Path (optional)").performClick()
        composeTestRule.onNodeWithText(destination).performTextReplacement("/backup")
        composeTestRule.onNodeWithText("Save").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("select_all_button"), 15000)

        // media-only: photo.jpg and video.mp4 are listed, notes.txt/report.pdf are not.
        composeTestRule.waitUntilExactlyOneExists(hasText("photo.jpg", substring = true), 5000)
        composeTestRule.waitUntilExactlyOneExists(hasText("video.mp4", substring = true), 5000)

        // Search filters the list; uploading while filtered must upload only the match.
        composeTestRule.onNode(hasContentDescription("Search")).performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("Filter files..."), 5000)
        composeTestRule.onNodeWithText("Filter files...").performTextInput("photo")
        composeTestRule.waitUntilDoesNotExist(hasText("video.mp4", substring = true), 5000)
        composeTestRule.onNodeWithText("photo.jpg", substring = true).performClick()
        upload()
        composeTestRule.waitUntilNodeCount(hasContentDescription("Synced"), 1, 15000)
    }

    @Test
    fun testEmbeddedCredentialsUrlSkipsS3Prompt() {
        val url = embeddedUrl ?: return
        composeTestRule.waitForIdle()

        fillFreshSettings(url, destination)
        composeTestRule.onNodeWithText("Test").performClick()
        enterPassphrase(testPassphrase)

        // Connection succeeds after only the passphrase; no S3 dialog appears.
        composeTestRule.waitUntilExactlyOneExists(hasText("Save"), 15000)
        composeTestRule.onAllNodesWithText("S3 Credentials").assertCountEquals(0)
    }

    @Test
    fun testWrongPassphraseShowsConnectionError() {
        val url = scratchUrl ?: return
        composeTestRule.waitForIdle()

        fillFreshSettings(url, destination)
        composeTestRule.onNodeWithText("Test").performClick()
        enterPassphrase(wrongPassphrase)
        enterS3Credentials()

        composeTestRule.waitUntilExactlyOneExists(hasText("Connection Error"), 20000)
        composeTestRule.onNodeWithText("OK").performClick()
        composeTestRule.onAllNodesWithText("Connecting to server...").assertCountEquals(0)

        // The user can recover: dismiss settings and the Connect affordance is offered.
        composeTestRule.onNodeWithText("Cancel").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("Repository access needed"), 5000)
    }

    @Test
    fun testRepositorySwitchResetsAndUploadsToNewRepo() {
        val source = scratchUrl ?: return
        val target = switchUrl ?: return
        composeTestRule.waitForIdle()

        connectFreshRepo(source, destination, testPassphrase)
        saveAndWaitForList()

        // Change the Host URL: switching repository must reset the connection.
        composeTestRule.onNode(hasContentDescription("Settings")).performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("Host URL"), 5000)
        composeTestRule.onNodeWithText(source).performTextReplacement(target)
        composeTestRule.onNodeWithText(destination).performTextReplacement(switchDestination)
        composeTestRule.onNodeWithText("Save").performClick()

        composeTestRule.waitUntilExactlyOneExists(hasText("Repository access needed"), 10000)

        // Reconnect to the new repository (fresh passphrase + S3 prompt) and upload.
        composeTestRule.onNodeWithText("Connect").performClick()
        enterPassphrase(testPassphrase)
        enterS3Credentials()
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("select_all_button"), 15000)

        selectFile("blue_sky.jpg")
        upload()
        composeTestRule.waitUntilNodeCount(hasContentDescription("Synced"), 1, 15000)
    }

    @Test
    fun testUploadFailureShowsDialog() {
        val url = scratchUrl ?: return
        composeTestRule.waitForIdle()

        connectFreshRepo(url, destination, testPassphrase)
        saveAndWaitForList()

        scratchControl("fail-writes?on=true")
        selectFile("blue_sky.jpg")
        upload()

        composeTestRule.waitUntilExactlyOneExists(hasText("Upload Failed"), 30000)
        composeTestRule.onNodeWithText("OK").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("Failed", substring = true), 10000)

        scratchControl("reset")
    }

    @Test
    fun testAbortMidUpload() {
        val url = scratchUrl ?: return
        composeTestRule.waitForIdle()

        connectFreshRepo(url, destination, testPassphrase)
        saveAndWaitForList()

        // Slow the uploads so the abort lands while work is in flight.
        scratchControl("latency?ms=4000")
        selectFile("blue_sky.jpg")
        selectFile("red_earth.jpg")
        upload()

        composeTestRule.waitUntilExactlyOneExists(hasText("Abort"), 15000)
        composeTestRule.onNodeWithText("Abort").performClick()
        // Aborting stops the upload and returns the screen to a usable, non-uploading
        // state. (We assert this rather than the per-row "Aborted" label, which the
        // current code can race-overwrite with a late progress update.)
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("select_all_button"), 15000)
        composeTestRule.onAllNodesWithText("Abort").assertCountEquals(0)

        scratchControl("reset")
    }

    @Test
    fun testUploadSurvivesViewModelLossAndReattaches() {
        val url = reattachUrl ?: return
        composeTestRule.waitForIdle()

        connectFreshRepo(url, destination, testPassphrase)
        saveAndWaitForList()

        // Slow the uploads so we can drop the ViewModel mid-flight.
        control(url, "latency?ms=4000")
        selectFile("blue_sky.jpg")
        selectFile("red_earth.jpg")
        upload()
        composeTestRule.waitUntilExactlyOneExists(hasText("Abort"), 15000)

        // Simulate the app process being recreated while the foreground-service
        // upload keeps running: drop the (retained) ViewModel, then recreate the
        // Activity. A FRESH ViewModel (currentUploadId == null) must re-attach to
        // the still-running work and surface it.
        composeTestRule.activityRule.scenario.onActivity { it.viewModelStore.clear() }
        composeTestRule.activityRule.scenario.recreate()
        composeTestRule.waitForIdle()

        // The fresh ViewModel reconnects and picks the upload back up (still running)...
        composeTestRule.waitUntilExactlyOneExists(hasText("Abort"), 20000)
        // ...and it runs to completion, marking both files synced.
        control(url, "reset")
        composeTestRule.waitUntilNodeCount(hasContentDescription("Synced"), 2, 30000)
    }

    @Test
    fun testCancelPassphrasePromptIsRecoverable() {
        val url = scratchUrl ?: return
        composeTestRule.waitForIdle()

        fillFreshSettings(url, destination)
        composeTestRule.onNodeWithText("Test").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("Enter Passphrase"), 5000)
        // Back-press dismisses the passphrase dialog (the Settings dialog behind it
        // also has a "Cancel", so a text match would be ambiguous).
        Espresso.pressBack()
        composeTestRule.waitUntilDoesNotExist(hasText("Enter Passphrase"), 5000)

        // No stuck connecting overlay; the Settings dialog is still usable.
        composeTestRule.onAllNodesWithText("Connecting to server...").assertCountEquals(0)
        composeTestRule.waitUntilExactlyOneExists(hasText("Save"), 5000)
    }

    @Test
    fun testSubdirectoryMediaFilesAreSynced() {
        val url = mediaSubUrl ?: return
        composeTestRule.waitForIdle()

        // Set the custom source on the first-run dialog and connect via "Test" before
        // saving. This also guards that a Test-then-Save still rebuilds the file
        // list (Test commits the settings, so Save sees no diff to react to).
        fillFreshSettings(url, "/backup/")
        setSourceDirectory("${Environment.getExternalStorageDirectory().path}/MediaSub")
        composeTestRule.onNodeWithText("Test").performClick()
        enterPassphrase(testPassphrase)
        enterS3Credentials()
        saveAndWaitForList()

        // media-only (default): the image nested in a subdirectory is listed, the
        // text file sharing that subdirectory is not.
        composeTestRule.waitUntilExactlyOneExists(hasText("beach.jpg", substring = true), 5000)
        composeTestRule.waitUntilExactlyOneExists(hasText("root.jpg", substring = true), 5000)
        composeTestRule.onAllNodesWithText("readme.txt", substring = true).assertCountEquals(0)

        composeTestRule.onNodeWithTag("select_all_button").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("2 file", substring = true), 5000)
        upload()
        composeTestRule.waitUntilNodeCount(hasContentDescription("Synced"), 2, 15000)
    }

    @Test
    fun testNonMediaSubdirectoryFilesAreSyncedWhenMediaFilterIsOff() {
        val url = docsSubUrl ?: return
        composeTestRule.waitForIdle()

        // Back up from the app's own external-files directory: it holds non-media files
        // in subdirectories and is readable without all-files access, so this exercises
        // the recursive scan + media filter without the storage-permission gate.
        val source =
            File(
                InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null),
                "SubDocs",
            )
        source.deleteRecursively()
        File(source, "letters").mkdirs()
        File(source, "reports").mkdirs()
        File(source, "letters/hello.txt").writeText("Hello letter")
        File(source, "reports/q1.pdf").writeText("Q1 report")

        connectFreshRepo(url, "/backup/", testPassphrase)
        saveAndWaitForList()

        reopenSettings()
        setSourceDirectory(source.absolutePath)
        uncheckMediaOnly()
        composeTestRule.onNodeWithText("Save").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("select_all_button"), 15000)

        // Both documents, each nested in its own subdirectory, are listed and upload
        // with their subdirectory structure preserved (asserted on the Go side).
        composeTestRule.waitUntilExactlyOneExists(hasText("hello.txt", substring = true), 5000)
        composeTestRule.waitUntilExactlyOneExists(hasText("q1.pdf", substring = true), 5000)

        composeTestRule.onNodeWithTag("select_all_button").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("2 file", substring = true), 5000)
        upload()
        composeTestRule.waitUntilNodeCount(hasContentDescription("Synced"), 2, 15000)
    }

    @Test
    fun testEmptyFolderDoesNotRequestStoragePermission() {
        val url = scratchUrl ?: return
        composeTestRule.waitForIdle()

        // An empty app-owned source with the media filter off shows the empty list,
        // never the access prompt: the app can fully read its own directories, so
        // nothing can be hiding there.
        val empty =
            File(
                InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null),
                "EmptyBackup",
            )
        empty.deleteRecursively()
        empty.mkdirs()

        connectFreshRepo(url, "/backup/", testPassphrase)
        saveAndWaitForList()

        reopenSettings()
        setSourceDirectory(empty.absolutePath)
        uncheckMediaOnly()
        composeTestRule.onNodeWithText("Save").performClick()

        composeTestRule.waitUntilExactlyOneExists(hasText("No Files Found", substring = true), 15000)
        composeTestRule.onAllNodesWithText("Storage Permission Required").assertCountEquals(0)
    }

    @Test
    fun testNonMediaBackupFromSharedStorageRequestsAllFilesAccess() {
        val url = scratchUrl ?: return
        composeTestRule.waitForIdle()

        connectFreshRepo(url, "/backup/", testPassphrase)
        saveAndWaitForList()

        reopenSettings()
        setSourceDirectory("${Environment.getExternalStorageDirectory().path}/ClingSyncTest")
        uncheckMediaOnly()
        composeTestRule.onNodeWithText("Save").performClick()

        // Scoped storage hides other apps' files (like the adb-pushed ones in
        // ClingSyncTest) from the listing entirely, so a non-media backup from shared
        // storage must ask for All files access even though the scan reports no error.
        composeTestRule.waitUntilExactlyOneExists(hasText("Storage Permission Required"), 15000)
        composeTestRule.onNodeWithText("Cancel").performClick()
        composeTestRule.waitUntilDoesNotExist(hasText("Storage Permission Required"), 5000)
    }
}
