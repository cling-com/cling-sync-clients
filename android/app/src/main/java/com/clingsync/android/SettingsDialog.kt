package com.clingsync.android

import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

@Composable
fun SettingsDialog(
    settings: AppSettings,
    onSave: (AppSettings) -> Unit,
    onTestConnection: (AppSettings) -> Unit,
    onBrowseDirectory: (onResult: (String) -> Unit) -> Unit,
    onDismiss: (() -> Unit)? = null,
) {
    var hostUrl by remember { mutableStateOf(settings.hostUrl) }
    var repoPathPrefix by remember { mutableStateOf(settings.repoPathPrefix) }
    var author by remember { mutableStateOf(settings.author) }
    var sourceDirectory by remember { mutableStateOf(settings.sourceDirectory) }
    var mediaOnly by remember { mutableStateOf(settings.mediaOnly) }

    val currentSettings =
        AppSettings(
            hostUrl = hostUrl.trim(),
            repoPathPrefix = repoPathPrefix.trim(),
            author = author.trim(),
            sourceDirectory = sourceDirectory.trim(),
            mediaOnly = mediaOnly,
        )

    Dialog(
        onDismissRequest = { onDismiss?.invoke() },
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Card(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(24.dp)
                    .heightIn(max = (LocalConfiguration.current.screenHeightDp * 0.9f).dp),
            elevation = CardDefaults.cardElevation(defaultElevation = 8.dp),
        ) {
            Column(
                modifier = Modifier.padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text(
                    text = "Settings",
                    style = MaterialTheme.typography.titleLarge,
                )

                // Scrollable body; the action row below stays pinned so Save is
                // always reachable regardless of how tall this section grows.
                Column(
                    modifier =
                        Modifier
                            .weight(1f, fill = false)
                            .verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    OutlinedTextField(
                        value = hostUrl,
                        onValueChange = { hostUrl = it },
                        label = { Text("Host URL") },
                        placeholder = { Text("s3+https://bucket.s3.region.example.com") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )

                    OutlinedTextField(
                        value = repoPathPrefix,
                        onValueChange = { repoPathPrefix = it },
                        label = { Text("Destination Path (optional)") },
                        placeholder = { Text("/backup/photos") },
                        modifier = Modifier.fillMaxWidth(),
                    )

                    OutlinedTextField(
                        value = author,
                        onValueChange = { author = it },
                        label = { Text("Author") },
                        placeholder = { Text("Your Name") },
                        modifier = Modifier.fillMaxWidth(),
                    )

                    OutlinedTextField(
                        value = sourceDirectory,
                        onValueChange = { sourceDirectory = it },
                        label = { Text("Source Directory") },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    TextButton(
                        onClick = { onBrowseDirectory { path -> sourceDirectory = path } },
                    ) {
                        Text("Browse")
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Checkbox(
                            checked = mediaOnly,
                            onCheckedChange = { mediaOnly = it },
                        )
                        Text(
                            text = "Media files only",
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }

                    if (BuildConfig.REMINDER_TEST_CONTROLS) {
                        ReminderTestControls()
                    }

                    Text(
                        text = "Version ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    OutlinedButton(
                        onClick = { onTestConnection(currentSettings) },
                        enabled = hostUrl.isNotBlank(),
                    ) {
                        Text("Test")
                    }

                    Spacer(modifier = Modifier.weight(1f))

                    onDismiss?.let {
                        TextButton(onClick = it) {
                            Text("Cancel")
                        }
                        Spacer(modifier = Modifier.width(8.dp))
                    }

                    Button(
                        onClick = { onSave(currentSettings) },
                        enabled = hostUrl.isNotBlank() && author.isNotBlank(),
                    ) {
                        Text("Save")
                    }
                }
            }
        }
    }
}

// Debug-only controls (gated by BuildConfig.REMINDER_TEST_CONTROLS) that fire the
// backup reminder in a few seconds, forced onto the daily or weekly path, so the
// notification flow can be exercised by hand.
@Composable
private fun ReminderTestControls() {
    val context = LocalContext.current
    HorizontalDivider()
    Text(
        text = "Debug: reminder test",
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    OutlinedButton(
        onClick = {
            MergeReminderScheduler.scheduleTest(context, weekly = false)
            Toast.makeText(
                context,
                "Daily reminder in ${MergeReminderScheduler.TEST_DELAY_SECONDS}s",
                Toast.LENGTH_SHORT,
            ).show()
        },
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text("Test daily reminder")
    }
    OutlinedButton(
        onClick = {
            MergeReminderScheduler.scheduleTest(context, weekly = true)
            Toast.makeText(
                context,
                "Weekly reminder in ${MergeReminderScheduler.TEST_DELAY_SECONDS}s",
                Toast.LENGTH_SHORT,
            ).show()
        },
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text("Test weekly reminder")
    }
}
