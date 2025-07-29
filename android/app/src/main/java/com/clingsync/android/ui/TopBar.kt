package com.clingsync.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.clingsync.android.UploadInfo
import java.io.File

@Composable
fun TopBar(
    selectedFiles: Set<File>,
    isUploading: Boolean,
    uploadInfo: UploadInfo?,
    selectAllChecked: Boolean,
    onSelectAllChange: (Boolean) -> Unit,
    onUploadClick: () -> Unit,
    onUploadAllClick: () -> Unit,
    onAbortClick: () -> Unit,
    modifier: Modifier = Modifier,
    isSelectAllEnabled: Boolean = true,
    uploadedSizeMB: Long = 0L,
) {
    Surface(
        modifier = modifier.fillMaxWidth().height(80.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        shadowElevation = 8.dp,
    ) {
        Row(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Start,
        ) {
            // Left side: Progress indicator during upload or empty space
            if (isUploading && uploadInfo != null) {
                Box(
                    modifier = Modifier.size(40.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    if (uploadInfo.currentFile == null) {
                        // Preparing state - show indeterminate spinner
                        CircularProgressIndicator(
                            modifier = Modifier.size(24.dp),
                            strokeWidth = 2.dp,
                        )
                    } else {
                        // Uploading state - show progress
                        val progress =
                            if (uploadInfo.totalFiles > 0) {
                                uploadInfo.currentIndex.toFloat() / uploadInfo.totalFiles
                            } else {
                                0f
                            }
                        CircularProgressIndicator(
                            progress = { progress },
                            modifier = Modifier.size(24.dp),
                            strokeWidth = 2.dp,
                        )
                    }
                }
                Spacer(modifier = Modifier.width(12.dp))
            }

            // Middle: Status text.
            Box(
                modifier = Modifier.weight(1f),
                contentAlignment = Alignment.CenterStart,
            ) {
                when {
                    isUploading && uploadInfo != null -> {
                        // During upload: show current file and progress.
                        UploadProgressDisplay(
                            uploadInfo = uploadInfo,
                            uploadedSizeMB = uploadedSizeMB,
                        )
                    }
                    isUploading -> {
                        // Upload initiated but no info yet - show preparing
                        Text(
                            text = "Preparing upload...",
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                    selectedFiles.isNotEmpty() -> {
                        // Files selected: show count and size.
                        val totalSize = formatTotalFileSize(selectedFiles)
                        Text(
                            text = "${selectedFiles.size} file${if (selectedFiles.size == 1) "" else "s"} ($totalSize)",
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                    else -> {
                        // No files selected: show status.
                        Text(
                            text = "No files selected",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.width(12.dp))

            // Right side: Upload/Abort button.
            when {
                isUploading -> {
                    TextButton(
                        onClick = onAbortClick,
                        modifier = Modifier.height(40.dp),
                    ) {
                        Text(
                            text = "Abort",
                            color = MaterialTheme.colorScheme.error,
                            fontWeight = FontWeight.Medium,
                        )
                    }
                }
                selectedFiles.isNotEmpty() -> {
                    // Show Upload Selected button
                    Button(
                        onClick = onUploadClick,
                        modifier =
                            Modifier
                                .height(40.dp)
                                .testTag("upload_button"),
                        colors =
                            ButtonDefaults.buttonColors(
                                containerColor = MaterialTheme.colorScheme.primary,
                            ),
                    ) {
                        Text(
                            text = "Upload Selected",
                            fontWeight = FontWeight.Medium,
                        )
                    }
                }
                else -> {
                    // Show Upload All button when no files selected
                    Button(
                        onClick = onUploadAllClick,
                        modifier =
                            Modifier
                                .height(40.dp)
                                .testTag("upload_all_button"),
                        colors =
                            ButtonDefaults.buttonColors(
                                containerColor = MaterialTheme.colorScheme.primary,
                            ),
                    ) {
                        Text(
                            text = "Upload All",
                            fontWeight = FontWeight.Medium,
                        )
                    }
                }
            }
        }
    }
}
