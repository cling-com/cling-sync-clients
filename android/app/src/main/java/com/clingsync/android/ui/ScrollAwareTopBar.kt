package com.clingsync.android.ui

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.clingsync.android.UploadInfo
import java.io.File

@Composable
fun ScrollAwareTopBar(
    lazyListState: LazyListState,
    selectedFiles: Set<File>,
    isUploading: Boolean,
    uploadInfo: UploadInfo?,
    selectAllChecked: Boolean,
    onSelectAllChange: (Boolean) -> Unit,
    onUploadClick: () -> Unit,
    onUploadAllClick: () -> Unit,
    onAbortClick: () -> Unit,
    isSelectAllEnabled: Boolean = true,
    uploadedSizeMB: Long = 0L,
) {
    // Derive scroll state.
    val firstVisibleIndex by remember { derivedStateOf { lazyListState.firstVisibleItemIndex } }
    val scrollOffset by remember { derivedStateOf { lazyListState.firstVisibleItemScrollOffset } }

    // Track previous scroll position.
    var previousIndex by remember { mutableStateOf(0) }
    var previousOffset by remember { mutableStateOf(0) }

    // Determine if scrolling down.
    val isScrollingDown =
        remember(firstVisibleIndex, scrollOffset) {
            val scrollingDown =
                when {
                    firstVisibleIndex > previousIndex -> true
                    firstVisibleIndex < previousIndex -> false
                    else -> scrollOffset > previousOffset
                }
            previousIndex = firstVisibleIndex
            previousOffset = scrollOffset
            scrollingDown
        }

    // Always show when:
    // 1. Uploading
    // 2. Files are selected
    // 3. At the very top of the list
    // 4. Scrolling up
    val shouldShow =
        isUploading ||
            selectedFiles.isNotEmpty() ||
            (firstVisibleIndex == 0 && scrollOffset == 0) ||
            !isScrollingDown

    // Animate the offset.
    val offsetY by animateDpAsState(
        targetValue = if (shouldShow) 0.dp else (-80).dp,
        animationSpec = tween(durationMillis = 300),
        label = "topBarOffset",
    )

    Box(modifier = Modifier.offset(y = offsetY)) {
        TopBar(
            selectedFiles = selectedFiles,
            isUploading = isUploading,
            uploadInfo = uploadInfo,
            selectAllChecked = selectAllChecked,
            onSelectAllChange = onSelectAllChange,
            onUploadClick = onUploadClick,
            onUploadAllClick = onUploadAllClick,
            onAbortClick = onAbortClick,
            isSelectAllEnabled = isSelectAllEnabled,
            uploadedSizeMB = uploadedSizeMB,
        )
    }
}
