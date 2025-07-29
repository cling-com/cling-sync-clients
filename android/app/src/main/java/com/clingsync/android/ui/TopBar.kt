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
import androidx.compose.material3.Checkbox
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
    onAbortClick: () -> Unit,
    modifier: Modifier = Modifier,
    isSelectAllEnabled: Boolean = true,
    totalSizeMB: Long = 0L,
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
                    .padding(horizontal = 32.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Start,
        ) {
            // Left side: Checkbox or circular progress.
            Box(
                modifier = Modifier.size(40.dp),
                contentAlignment = Alignment.Center,
            ) {
                if (isUploading && uploadInfo != null) {
                    // Show circular progress during upload.
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
                } else {
                    // Show checkbox when not uploading.
                    Checkbox(
                        checked = selectAllChecked,
                        onCheckedChange = onSelectAllChange,
                        modifier = Modifier.testTag("select_all"),
                        enabled = isSelectAllEnabled && !isUploading,
                    )
                }
            }

            Spacer(modifier = Modifier.width(12.dp))

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
                            totalSizeMB = totalSizeMB,
                            uploadedSizeMB = uploadedSizeMB,
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
                            text = "Upload",
                            fontWeight = FontWeight.Medium,
                        )
                    }
                }
                else -> {
                    // Disabled upload button when no files selected.
                    Button(
                        onClick = { },
                        modifier = Modifier.height(40.dp),
                        enabled = false,
                    ) {
                        Text(
                            text = "Upload",
                            fontWeight = FontWeight.Medium,
                        )
                    }
                }
            }
        }
    }
}
