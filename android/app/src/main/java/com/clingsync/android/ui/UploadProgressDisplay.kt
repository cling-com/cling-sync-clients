package com.clingsync.android.ui

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.text.style.TextOverflow
import com.clingsync.android.UploadInfo

@Composable
fun UploadProgressDisplay(
    uploadInfo: UploadInfo,
    totalSizeMB: Long,
    uploadedSizeMB: Long,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        when {
            uploadInfo.currentFile?.startsWith("Committing") == true -> {
                Text(
                    text = uploadInfo.currentFile,
                    style = MaterialTheme.typography.bodyMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
            }
            uploadInfo.currentFile != null -> {
                // Filename with start ellipsis.
                Text(
                    text = uploadInfo.currentFile,
                    style =
                        LocalTextStyle.current.copy(
                            textDirection = TextDirection.Rtl,
                            fontSize = MaterialTheme.typography.bodyMedium.fontSize,
                        ),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )

                // Progress info - always visible.
                val uploadedStr = formatFileSize(uploadedSizeMB * 1024 * 1024)
                val totalStr = formatFileSize(totalSizeMB * 1024 * 1024)
                Text(
                    text = " (${uploadInfo.currentIndex}/${uploadInfo.totalFiles}) • $uploadedStr / $totalStr",
                    style = MaterialTheme.typography.bodyMedium,
                    maxLines = 1,
                )
            }
            else -> {
                Text(
                    text = "Preparing...",
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
    }
}
