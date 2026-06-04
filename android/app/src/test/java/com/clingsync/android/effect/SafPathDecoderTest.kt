package com.clingsync.android.effect

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SafPathDecoderTest {
    @Test
    fun decodesPrimaryStorageTrees() {
        assertEquals(
            "/storage/emulated/0/Pictures/Camera",
            SafPathDecoder.decode("primary:Pictures/Camera", "/storage/emulated/0"),
        )
        assertEquals("/sdcard/DCIM", SafPathDecoder.decode("primary:DCIM", "/sdcard"))
    }

    @Test
    fun rejectsNonPrimaryOrMalformedIds() {
        // Secondary volumes (SD cards) have no usable real path here.
        assertNull(SafPathDecoder.decode("0000-0000:DCIM", "/sdcard"))
        assertNull(SafPathDecoder.decode("home:docs", "/sdcard"))
        // Missing or extra colons.
        assertNull(SafPathDecoder.decode("primary", "/sdcard"))
        assertNull(SafPathDecoder.decode("primary:a:b", "/sdcard"))
    }
}
