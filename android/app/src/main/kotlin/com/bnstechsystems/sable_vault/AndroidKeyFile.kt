package com.bnstechsystems.sable_vault

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import java.io.IOException

/** Reuses the exact document in the user-selected tree instead of CREATE_DOCUMENT. */
class AndroidKeyFile(private val resolver: ContentResolver) {
    companion object {
        const val NAME = "spar-vault-master-key.txt"
        private const val MAX_BYTES = 512
    }

    fun write(directory: String, bytes: ByteArray) {
        try {
            require(bytes.size in 1..MAX_BYTES)
            val text = bytes.toString(Charsets.UTF_8).replace(Regex("[\\s-]"), "")
            require(Regex("^[0-9a-fA-F]{64}$").matches(text))
            val tree = Uri.parse(directory)
            if (tree.scheme != "content" || resolver.persistedUriPermissions.none {
                it.uri == tree && it.isReadPermission && it.isWritePermission
            }) throw SecurityException("Select the key folder again.")
            val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            var existing: Uri? = null
            resolver.query(children, arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE
            ), null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    if (cursor.getString(1) != NAME) continue
                    if (existing != null || cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) {
                        throw IOException("The key filename is not a unique file.")
                    }
                    existing = DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0))
                }
            } ?: throw IOException("Cannot list the key folder.")
            val target = existing ?: DocumentsContract.createDocument(resolver, parent, "text/plain", NAME)
                ?: throw IOException("Cannot create the key file.")
            // Keep the previous bytes for rollback if this provider fails while replacing.
            var previous: ByteArray? = null
            try {
                if (existing != null) {
                    previous = read(target)
                    if (previous.contentEquals(bytes)) return
                }
                replace(target, bytes)
            } catch (error: Exception) {
                try {
                    if (previous != null) replace(target, previous)
                    else if (existing == null) DocumentsContract.deleteDocument(resolver, target)
                } catch (rollback: Exception) {
                    error.addSuppressed(rollback)
                }
                throw error
            } finally {
                previous?.fill(0)
            }
        } finally {
            bytes.fill(0)
        }
    }

    private fun read(uri: Uri): ByteArray = resolver.openInputStream(uri)?.use { stream ->
        val buffer = ByteArray(MAX_BYTES + 1)
        try {
            var size = 0
            while (size < buffer.size) {
                val count = stream.read(buffer, size, buffer.size - size)
                if (count == -1) break
                if (count == 0) throw IOException("Cannot read the key file.")
                size += count
            }
            if (size > MAX_BYTES) throw IOException("Existing key file is too large to replace.")
            buffer.copyOf(size)
        } finally {
            buffer.fill(0)
        }
    } ?: throw IOException("Cannot read the key file.")

    private fun replace(uri: Uri, bytes: ByteArray) {
        resolver.openOutputStream(uri, "wt")?.use { stream ->
            stream.write(bytes)
            stream.flush()
        } ?: throw IOException("Cannot write the key file.")
        val saved = read(uri)
        try {
            if (!saved.contentEquals(bytes)) throw IOException("Key-file verification failed.")
        } finally {
            saved.fill(0)
        }
    }
}
