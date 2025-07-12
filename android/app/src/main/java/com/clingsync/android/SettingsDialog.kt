package com.clingsync.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog

@Composable
fun SettingsDialog(
    settings: AppSettings,
    onSave: (AppSettings) -> Unit,
    onDismiss: (() -> Unit)? = null,
) {
    var hostUrl by remember { mutableStateOf(settings.hostUrl) }
    var password by remember { mutableStateOf(settings.password) }
    var repoPathPrefix by remember { mutableStateOf(settings.repoPathPrefix) }

    Dialog(
        onDismissRequest = { onDismiss?.invoke() },
    ) {
        Card(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
            elevation = CardDefaults.cardElevation(defaultElevation = 8.dp),
        ) {
            Column(
                modifier = Modifier.padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text(
                    text = "Connect to Server",
                    style = MaterialTheme.typography.titleLarge,
                )

                OutlinedTextField(
                    value = hostUrl,
                    onValueChange = { hostUrl = it },
                    label = { Text("Host URL") },
                    placeholder = { Text("https://example.com") },
                    modifier = Modifier.fillMaxWidth(),
                )

                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text("Password") },
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth(),
                )

                OutlinedTextField(
                    value = repoPathPrefix,
                    onValueChange = { repoPathPrefix = it },
                    label = { Text("Destination Path") },
                    placeholder = { Text("/backup/photos") },
                    modifier = Modifier.fillMaxWidth(),
                )

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    onDismiss?.let {
                        TextButton(onClick = it) {
                            Text("Cancel")
                        }
                        Spacer(modifier = Modifier.width(8.dp))
                    }

                    Button(
                        onClick = {
                            val newSettings =
                                AppSettings(
                                    hostUrl = hostUrl.trim(),
                                    password = password,
                                    repoPathPrefix = repoPathPrefix.trim(),
                                )
                            onSave(newSettings)
                        },
                        enabled = hostUrl.isNotBlank() && password.isNotBlank() && repoPathPrefix.isNotBlank(),
                    ) {
                        Text("Save")
                    }
                }
            }
        }
    }
}
