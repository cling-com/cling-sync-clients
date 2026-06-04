package com.clingsync.android.effect

// Pure mapping of a Storage Access Framework tree document id (e.g.
// "primary:Pictures/Camera") to an absolute filesystem path. Returns null when
// the tree is not on primary external storage, where no real path exists. The
// caller supplies the external storage root so this stays Android-free.
object SafPathDecoder {
    fun decode(
        treeDocumentId: String,
        externalStorageRoot: String,
    ): String? {
        val parts = treeDocumentId.split(":")
        if (parts.size != 2 || parts[0] != "primary") {
            return null
        }
        return "$externalStorageRoot/${parts[1]}"
    }
}
