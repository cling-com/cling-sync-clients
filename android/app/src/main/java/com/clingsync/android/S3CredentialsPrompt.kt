package com.clingsync.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine

data class S3CredentialsResult(
    val accessKeyId: String,
    val accessKey: String,
)

data class S3CredentialsRequest(
    val onConfirm: (S3CredentialsResult) -> Unit,
    val onCancel: () -> Unit,
)

// Shows the S3 credentials prompt and suspends until the user confirms or
// cancels. `install` is called with the request the UI should render, then
// with `null` after the prompt resolves.
suspend fun awaitS3Credentials(install: (S3CredentialsRequest?) -> Unit): S3CredentialsResult =
    suspendCancellableCoroutine { cont ->
        install(
            S3CredentialsRequest(
                onConfirm = { result ->
                    install(null)
                    if (cont.isActive) {
                        cont.resumeWith(Result.success(result))
                    }
                },
                onCancel = {
                    install(null)
                    if (cont.isActive) {
                        cont.resumeWith(
                            Result.failure(CancellationException("S3 credentials prompt cancelled")),
                        )
                    }
                },
            ),
        )
        cont.invokeOnCancellation { install(null) }
    }

@Composable
fun S3CredentialsPromptDialog(
    onConfirm: (S3CredentialsResult) -> Unit,
    onDismiss: () -> Unit,
) {
    var accessKeyId by remember { mutableStateOf("") }
    var accessKey by remember { mutableStateOf("") }
    var secretVisible by remember { mutableStateOf(false) }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Card(
            modifier = Modifier.fillMaxWidth().padding(24.dp),
            elevation = CardDefaults.cardElevation(defaultElevation = 8.dp),
        ) {
            Column(
                modifier = Modifier.padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text(
                    text = "S3 Credentials",
                    style = MaterialTheme.typography.titleLarge,
                )
                Text(
                    text =
                        "Enter the S3 access key for this server. " +
                            "The credentials are encrypted with your passphrase before being stored.",
                    style = MaterialTheme.typography.bodyMedium,
                )

                OutlinedTextField(
                    value = accessKeyId,
                    onValueChange = { accessKeyId = it },
                    label = { Text("S3 Key ID") },
                    keyboardOptions =
                        KeyboardOptions(
                            autoCorrect = false,
                            capitalization = KeyboardCapitalization.None,
                        ),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )

                OutlinedTextField(
                    value = accessKey,
                    onValueChange = { accessKey = it },
                    label = { Text("S3 Access Key") },
                    visualTransformation =
                        if (secretVisible) VisualTransformation.None else PasswordVisualTransformation(),
                    keyboardOptions =
                        KeyboardOptions(
                            keyboardType = KeyboardType.Password,
                            autoCorrect = false,
                            capitalization = KeyboardCapitalization.None,
                        ),
                    singleLine = true,
                    trailingIcon = {
                        IconButton(onClick = { secretVisible = !secretVisible }) {
                            Icon(
                                imageVector =
                                    if (secretVisible) Icons.Filled.Visibility else Icons.Filled.VisibilityOff,
                                contentDescription =
                                    if (secretVisible) "Hide access key" else "Show access key",
                            )
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End,
                ) {
                    TextButton(onClick = onDismiss) {
                        Text("Cancel")
                    }
                    Button(
                        onClick = {
                            onConfirm(
                                S3CredentialsResult(
                                    accessKeyId = accessKeyId.trim(),
                                    accessKey = accessKey,
                                ),
                            )
                        },
                        enabled = accessKeyId.isNotBlank() && accessKey.isNotBlank(),
                    ) {
                        Text("Continue")
                    }
                }
            }
        }
    }
}
