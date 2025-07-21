package com.clingsync.android.ui

import java.text.DecimalFormat
import kotlin.math.ln
import kotlin.math.pow

/**
 * Formats file size in bytes to human-readable format using decimal (base 1000) units.
 * Rules:
 * - Shows next unit when reaching 4 digits (e.g., 1000KB -> 1.0MB)
 * - Shows one decimal place for values < 10 starting from MB
 * - Examples: 100KB, 1.2MB, 11MB, 123MB, 1.2GB
 */
fun formatFileSize(bytes: Long): String {
    if (bytes <= 0) return "0B"

    val units = arrayOf("B", "KB", "MB", "GB", "TB")
    val base = 1000.0

    // Calculate the appropriate unit index
    val digitGroups = (ln(bytes.toDouble()) / ln(base)).toInt()
    val unitIndex = digitGroups.coerceIn(0, units.size - 1)

    // Calculate the value in the selected unit
    val value = bytes / base.pow(unitIndex)

    // Format based on rules
    return when {
        unitIndex == 0 -> "${bytes.toInt()}B" // Bytes - no decimal
        unitIndex == 1 -> "${value.toInt()}KB" // KB - no decimal
        value < 10 -> {
            // MB and above, value < 10: show 1 decimal place
            DecimalFormat("#.#").format(value) + units[unitIndex]
        }
        else -> {
            // MB and above, value >= 10: no decimal
            "${value.toInt()}${units[unitIndex]}"
        }
    }
}

/**
 * Calculates total size in a human-readable format for a collection of files.
 */
fun formatTotalFileSize(files: Collection<java.io.File>): String {
    val totalBytes = files.sumOf { it.length() }
    return formatFileSize(totalBytes)
}
