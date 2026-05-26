package land.fx.files.dev

import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/**
 * Receives share-sheet intents (ACTION_SEND / ACTION_SEND_MULTIPLE) and
 * stages the payload into `<filesDir>/dump_pending/` so the main Flutter
 * app can drain + ingest on its next foreground / WorkManager tick (Shelf
 * plan revision R3 "Plan B" — Kotlin-only Activity, no Flutter engine
 * spin-up).
 *
 * The Activity is translucent + NoDisplay + noHistory; the user never
 * sees a transition. Side effects per share-transaction:
 *
 *  1. Copy each URI/text payload into `dump_pending/<filename>`.
 *  2. Write a descriptor JSON (`<txn>.json`) listing the files +
 *     mime hints + original names + optional textPayload.
 *  3. Post the "Shelf received — processing…" notification through
 *     [FxFilesApplication.showShelfReceivedNotification].
 *  4. `finish()`.
 *
 * Staging directory contract: Dart's
 * `path_provider.getApplicationDocumentsDirectory()` on Android maps to
 * `context.getDir("flutter", MODE_PRIVATE)` (i.e.
 * `/data/data/<pkg>/app_flutter/`), NOT `context.getFilesDir()`. We
 * stage into the SAME directory so the Dart `ShelfService.drainPendingDir`
 * sees what we write. If a future `path_provider` major upgrade
 * changes that mapping, this constant + the Dart side both need to
 * follow.
 */
class DumpShareActivity : Activity() {

    companion object {
        private const val TAG = "DumpShareActivity"
        private const val DESCRIPTOR_VERSION = 1
        private const val PENDING_DIR_NAME = "dump_pending"

        // Matches Flutter's `getApplicationDocumentsDirectory()` on Android.
        fun pendingDir(context: Context): File {
            val docs = context.getDir("flutter", Context.MODE_PRIVATE)
            return File(docs, PENDING_DIR_NAME)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Process synchronously inside onCreate BEFORE finish() — file
        // URIs from ACTION_SEND only carry temporary read grants for
        // the lifetime of this Activity. The copy MUST complete before
        // we hand off / die.
        try {
            handleShareIntent(intent)
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to stage share payload", t)
        }
        finish()
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return

        val pendingDir = pendingDir(applicationContext).apply {
            if (!exists()) mkdirs()
        }

        val txnId = UUID.randomUUID().toString()
        val items = mutableListOf<StagedItem>()
        val referrerPackage: String? = referrer?.host

        when (action) {
            Intent.ACTION_SEND -> {
                val streamUri: Uri? =
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                val text: String? = intent.getStringExtra(Intent.EXTRA_TEXT)
                val mimeHint: String? = intent.type

                if (streamUri != null) {
                    stageUri(streamUri, pendingDir, txnId, mimeHint)?.let {
                        items.add(it)
                    }
                } else if (!text.isNullOrEmpty()) {
                    stageText(text, pendingDir, txnId)?.let {
                        items.add(it)
                    }
                }
                if (items.isEmpty()) {
                    Log.w(TAG, "ACTION_SEND with neither EXTRA_STREAM nor "
                            + "EXTRA_TEXT — ignoring")
                    return
                }
                writeDescriptor(
                    pendingDir = pendingDir,
                    txnId = txnId,
                    items = items,
                    textPayload = if (streamUri == null) text else null,
                    sourcePackage = referrerPackage,
                )
                postReceivedNotification(items.size)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris: ArrayList<Uri>? =
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                val mimeHint: String? = intent.type
                if (uris.isNullOrEmpty()) {
                    Log.w(TAG, "ACTION_SEND_MULTIPLE with empty EXTRA_STREAM")
                    return
                }
                for (uri in uris) {
                    stageUri(uri, pendingDir, txnId, mimeHint)?.let {
                        items.add(it)
                    }
                }
                if (items.isEmpty()) return
                writeDescriptor(
                    pendingDir = pendingDir,
                    txnId = txnId,
                    items = items,
                    textPayload = null,
                    sourcePackage = referrerPackage,
                )
                postReceivedNotification(items.size)
            }
            else -> {
                Log.w(TAG, "Unsupported share action: $action")
            }
        }
    }

    // ---- Staging --------------------------------------------------------

    private data class StagedItem(
        val localFile: String,      // filename only — relative to pendingDir
        val originalName: String,
        val mimeType: String?,
    )

    private fun stageUri(
        uri: Uri,
        pendingDir: File,
        txnId: String,
        defaultMime: String?,
    ): StagedItem? {
        val resolver: ContentResolver = contentResolver
        val originalName = queryDisplayName(uri) ?: deriveNameFromUri(uri)
        val safeName = sanitizeFilename(originalName)
        // Prefix with the share-txn id so files from the same share are
        // grouped, and so collisions across shares are impossible.
        val target = File(pendingDir, "$txnId-$safeName")
        return try {
            resolver.openInputStream(uri).use { input ->
                if (input == null) {
                    Log.w(TAG, "openInputStream returned null for $uri")
                    return null
                }
                FileOutputStream(target).use { output ->
                    input.copyTo(output)
                }
            }
            val mime = resolver.getType(uri) ?: defaultMime
            StagedItem(
                localFile = target.name,
                originalName = originalName,
                mimeType = mime,
            )
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to copy $uri to $target", t)
            try { target.delete() } catch (_: Throwable) { }
            null
        }
    }

    private fun stageText(
        text: String,
        pendingDir: File,
        txnId: String,
    ): StagedItem? {
        val target = File(pendingDir, "$txnId-note.txt")
        return try {
            target.writeText(text, Charsets.UTF_8)
            StagedItem(
                localFile = target.name,
                originalName = "Note.txt",
                mimeType = "text/plain",
            )
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to write text payload", t)
            null
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null, null, null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        } catch (t: Throwable) {
            Log.w(TAG, "DISPLAY_NAME query failed for $uri", t)
            null
        }
    }

    private fun deriveNameFromUri(uri: Uri): String {
        val last = uri.lastPathSegment
        if (!last.isNullOrEmpty()) return last
        return "shared-${System.currentTimeMillis()}"
    }

    private fun sanitizeFilename(name: String): String {
        // Replace path separators + control chars; preserve dots so the
        // extension survives MIME-from-filename fallback in Dart.
        val cleaned = name.replace(Regex("[\\\\/:*?\"<>|\\r\\n\\t]"), "_")
        return if (cleaned.isBlank()) "file" else cleaned
    }

    // ---- Descriptor -----------------------------------------------------

    private fun writeDescriptor(
        pendingDir: File,
        txnId: String,
        items: List<StagedItem>,
        textPayload: String?,
        sourcePackage: String?,
    ) {
        val json = JSONObject().apply {
            put("v", DESCRIPTOR_VERSION)
            put("txnId", txnId)
            put("createdAtMs", System.currentTimeMillis())
            put("sourcePackage", sourcePackage ?: JSONObject.NULL)
            put("textPayload", textPayload ?: JSONObject.NULL)
            put("items", JSONArray().apply {
                items.forEach { item ->
                    put(JSONObject().apply {
                        put("localFile", item.localFile)
                        put("originalName", item.originalName)
                        put("mimeType", item.mimeType ?: JSONObject.NULL)
                    })
                }
            })
        }
        // Atomic write: write to .json.tmp then rename. The Dart drain
        // only looks at *.json so an interrupted write is never picked
        // up as committed.
        val tmp = File(pendingDir, "$txnId.json.tmp")
        val out = File(pendingDir, "$txnId.json")
        tmp.writeText(json.toString(), Charsets.UTF_8)
        if (!tmp.renameTo(out)) {
            Log.w(TAG, "Atomic rename failed for ${tmp.name}; "
                    + "falling back to copy + delete")
            tmp.copyTo(out, overwrite = true)
            tmp.delete()
        }
    }

    // ---- Notification ---------------------------------------------------

    private fun postReceivedNotification(count: Int) {
        try {
            FxFilesApplication.showShelfReceivedNotification(
                context = applicationContext,
                count = count,
            )
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to post received notification", t)
        }
    }
}
