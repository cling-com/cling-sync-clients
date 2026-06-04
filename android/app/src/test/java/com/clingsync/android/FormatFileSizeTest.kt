package com.clingsync.android

import com.clingsync.android.ui.formatFileSize
import com.clingsync.android.ui.formatTotalFileSize
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.Locale

class FormatFileSizeTest {
    private lateinit var previousLocale: Locale

    @Before
    fun setup() {
        // formatFileSize uses DecimalFormat, whose decimal separator follows the
        // default locale. Pin it so the asserted strings are deterministic.
        previousLocale = Locale.getDefault()
        Locale.setDefault(Locale.US)
    }

    @After
    fun tearDown() {
        Locale.setDefault(previousLocale)
    }

    @Test
    fun zeroAndNegativeRenderAsZeroBytes() {
        assertEquals("0B", formatFileSize(0))
        assertEquals("0B", formatFileSize(-1))
        assertEquals("0B", formatFileSize(-1000))
    }

    @Test
    fun bytesHaveNoDecimal() {
        assertEquals("1B", formatFileSize(1))
        assertEquals("500B", formatFileSize(500))
        assertEquals("999B", formatFileSize(999))
    }

    @Test
    fun kilobytesHaveNoDecimal() {
        assertEquals("1KB", formatFileSize(1000))
        assertEquals("1KB", formatFileSize(1500))
        assertEquals("100KB", formatFileSize(100_000))
    }

    @Test
    fun megabytesBelowTenShowOneDecimal() {
        assertEquals("1.2MB", formatFileSize(1_200_000))
        assertEquals("9.9MB", formatFileSize(9_900_000))
    }

    @Test
    fun megabytesAtOrAboveTenHaveNoDecimal() {
        assertEquals("11MB", formatFileSize(11_000_000))
        assertEquals("123MB", formatFileSize(123_000_000))
    }

    @Test
    fun gigabytesAndTerabytes() {
        assertEquals("1.2GB", formatFileSize(1_200_000_000))
        assertEquals("2TB", formatFileSize(2_000_000_000_000))
    }

    @Test
    fun valuesBeyondTerabytesStayInTerabytes() {
        assertEquals("5000TB", formatFileSize(5_000_000_000_000_000))
    }

    @Test
    fun totalSumsFileLengths() {
        val dir = Files.createTempDirectory("formatsize").toFile()
        try {
            File(dir, "a").apply { writeBytes(ByteArray(400_000)) }
            File(dir, "b").apply { writeBytes(ByteArray(800_000)) }
            assertEquals("1.2MB", formatTotalFileSize(dir.listFiles()!!.toList()))
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun totalOfEmptyCollectionIsZero() {
        assertEquals("0B", formatTotalFileSize(emptyList()))
    }
}
