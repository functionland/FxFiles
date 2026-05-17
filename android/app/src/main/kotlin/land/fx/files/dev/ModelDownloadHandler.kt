package land.fx.files.dev

import android.app.DownloadManager
import android.content.Context
import android.content.SharedPreferences
import android.database.Cursor
import android.net.Uri
import android.os.Environment
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Platform-channel handler that wraps Android's [DownloadManager] for the
 * on-device LLM model download. DownloadManager is a system service —
 * the actual transfer continues after our app process is killed and is
 * NOT subject to App Standby / Doze the way WorkManager is.
 *
 * Design notes:
 *
 * - **Destination is `setDestinationInExternalFilesDir(..., DIRECTORY_DOWNLOADS, filename)`**.
 *   App-scoped external storage. The system download daemon (not our
 *   app) writes here; it CAN'T write to our internal `/data/user/0/...`
 *   sandbox (SELinux). The Dart side reads from this same external path
 *   via `path_provider.getExternalStorageDirectory()`, so there's no
 *   "promote" copy step. This avoids the disk-space gotcha flagged by
 *   the advisors (verification + 770 MB extra copy = ~1.5 GB needed).
 *
 * - **Enqueue the ORIGINAL Hugging Face URL** (e.g.
 *   `https://huggingface.co/.../resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf`)
 *   never the resolved `cas-bridge.xethub.hf.co/...?X-Amz-Signature=...`
 *   redirect target. HF's signed CDN URLs have 1-hour expiry; if a slow
 *   cellular download spans the expiry, retrying against the cached
 *   signed URL hard-fails (403 SignatureDoesNotMatch). The fix lives in
 *   Dart: poll status, on FAILED-with-HTTP-reason `remove()` + re-enqueue
 *   from the original URL, which yields a fresh redirect.
 *
 * - **Persist `downloadId` to SharedPreferences** at enqueue time. The
 *   manifest BroadcastReceiver and Dart-side reconciliation both rely
 *   on it surviving an app-process death.
 */
class ModelDownloadHandler(private val context: Context) :
    MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "ModelDownloadHandler"
        const val PREFS_NAME = "land.fx.files.model_download"
        const val KEY_DOWNLOAD_ID = "downloadId"
        const val KEY_ORIGINAL_URL = "originalUrl"
        const val KEY_FILENAME = "filename"
        const val KEY_EXPECTED_SHA = "expectedSha"
        const val KEY_COMPLETED_AT = "completedAtMs"

        /**
         * Compute the absolute path Dart needs to read the downloaded
         * file from. Mirrors `setDestinationInExternalFilesDir(ctx,
         * DIRECTORY_DOWNLOADS, filename)`. Exposed so MainActivity can
         * return it via the `getDestinationPath` channel method —
         * Dart's `path_provider.getExternalStorageDirectory()` returns
         * the parent dir; we still need to know the `Download/<file>`
         * portion to land at the same path as the system daemon.
         */
        fun destinationFile(context: Context, filename: String): java.io.File {
            val dir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                ?: throw IllegalStateException(
                    "External files dir unavailable — device may be in shared-storage state")
            if (!dir.exists()) dir.mkdirs()
            return java.io.File(dir, filename)
        }
    }

    private val prefs: SharedPreferences by lazy {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    private val dm: DownloadManager by lazy {
        context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> handleStart(call, result)
            "query" -> handleQuery(call, result)
            "cancel" -> handleCancel(call, result)
            "destinationPath" -> handleDestinationPath(call, result)
            "completedSinceLastCheck" -> handleCompletedSinceLastCheck(result)
            else -> result.notImplemented()
        }
    }

    /**
     * Start a download. Args: url, filename, wifiOnly (bool),
     * expectedSha (string — opaque to us, persisted for Dart's
     * post-completion verification).
     *
     * Returns the long `downloadId`. Idempotent at the persisted-id
     * level: if a previous download is already enqueued for the same
     * filename + URL, returns its id rather than starting a second.
     */
    private fun handleStart(call: MethodCall, result: MethodChannel.Result) {
        try {
            val url = call.argument<String>("url")
                ?: return result.error("BAD_ARGS", "url required", null)
            val filename = call.argument<String>("filename")
                ?: return result.error("BAD_ARGS", "filename required", null)
            val wifiOnly = call.argument<Boolean>("wifiOnly") ?: true
            val expectedSha = call.argument<String>("expectedSha") ?: ""
            val title = call.argument<String>("title") ?: "Downloading AI model"
            val description = call.argument<String>("description") ?: ""

            // Idempotency: if we already have a live download for this
            // filename/url, return its id. Lets Dart safely call start()
            // on every screen open without spawning duplicates.
            val existingId = prefs.getLong(KEY_DOWNLOAD_ID, -1L)
            if (existingId > 0 && prefs.getString(KEY_FILENAME, "") == filename
                    && prefs.getString(KEY_ORIGINAL_URL, "") == url
                    && queryStatus(existingId) != null) {
                Log.i(TAG, "start: reusing existing downloadId=$existingId")
                return result.success(existingId)
            }

            // Make sure the destination dir exists.
            destinationFile(context, filename)

            val request = DownloadManager.Request(Uri.parse(url))
                .setTitle(title)
                .setDescription(description)
                .setNotificationVisibility(
                    DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                .setDestinationInExternalFilesDir(
                    context, Environment.DIRECTORY_DOWNLOADS, filename)
                .setMimeType("application/octet-stream")
                .setAllowedOverMetered(!wifiOnly)
                .setAllowedOverRoaming(!wifiOnly)

            // setAllowedNetworkTypes is the legacy "wifi only" knob. The
            // setAllowedOverMetered/Roaming combo above is the modern
            // equivalent and works on all API levels.

            val id = dm.enqueue(request)
            prefs.edit()
                .putLong(KEY_DOWNLOAD_ID, id)
                .putString(KEY_ORIGINAL_URL, url)
                .putString(KEY_FILENAME, filename)
                .putString(KEY_EXPECTED_SHA, expectedSha)
                .remove(KEY_COMPLETED_AT)
                .apply()
            Log.i(TAG, "start: enqueued downloadId=$id for $filename")
            result.success(id)
        } catch (e: Exception) {
            Log.e(TAG, "start failed: ${e.message}", e)
            result.error("START_FAILED", e.message, null)
        }
    }

    /**
     * Query current status. Args: downloadId (long).
     * Returns a map of:
     *   - status: one of "pending", "running", "paused", "successful",
     *     "failed", "unknown"
     *   - bytesDownloaded: long
     *   - totalBytes: long (-1 if unknown)
     *   - localUri: string? (when successful)
     *   - reason: int? (DM's REASON_* constant)
     *   - reasonText: string? (human-readable mapping)
     */
    private fun handleQuery(call: MethodCall, result: MethodChannel.Result) {
        val id = (call.argument<Number>("downloadId"))?.toLong()
            ?: prefs.getLong(KEY_DOWNLOAD_ID, -1L)
        if (id <= 0) {
            return result.success(mapOf("status" to "unknown"))
        }
        val map = queryStatus(id)
        if (map == null) {
            // Row gone — DM evicted it (rare) or never enqueued.
            return result.success(mapOf("status" to "unknown"))
        }
        result.success(map)
    }

    private fun queryStatus(id: Long): Map<String, Any?>? {
        val q = DownloadManager.Query().setFilterById(id)
        var cursor: Cursor? = null
        try {
            cursor = dm.query(q)
            if (cursor == null || !cursor.moveToFirst()) return null
            val statusCol = cursor.getColumnIndex(DownloadManager.COLUMN_STATUS)
            val byteCol = cursor.getColumnIndex(
                DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
            val totalCol = cursor.getColumnIndex(
                DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
            val reasonCol = cursor.getColumnIndex(DownloadManager.COLUMN_REASON)

            val status = cursor.getInt(statusCol)
            val downloaded = cursor.getLong(byteCol)
            val total = cursor.getLong(totalCol)
            val reason = cursor.getInt(reasonCol)

            val statusStr = when (status) {
                DownloadManager.STATUS_PENDING -> "pending"
                DownloadManager.STATUS_RUNNING -> "running"
                DownloadManager.STATUS_PAUSED -> "paused"
                DownloadManager.STATUS_SUCCESSFUL -> "successful"
                DownloadManager.STATUS_FAILED -> "failed"
                else -> "unknown"
            }
            val localUri: String? = if (status == DownloadManager.STATUS_SUCCESSFUL) {
                // COLUMN_LOCAL_FILENAME is deprecated on API 24+ and
                // returns null on API 29+. getUriForDownloadedFile is
                // the supported API.
                dm.getUriForDownloadedFile(id)?.toString()
            } else null

            return mapOf(
                "status" to statusStr,
                "bytesDownloaded" to downloaded,
                "totalBytes" to total,
                "localUri" to localUri,
                "reason" to reason,
                "reasonText" to reasonToString(status, reason)
            )
        } finally {
            cursor?.close()
        }
    }

    /**
     * Cancel the in-flight download and delete the partial file. Args:
     * downloadId. Also clears persisted state so the next `start()` is
     * a fresh enqueue.
     */
    private fun handleCancel(call: MethodCall, result: MethodChannel.Result) {
        val id = (call.argument<Number>("downloadId"))?.toLong()
            ?: prefs.getLong(KEY_DOWNLOAD_ID, -1L)
        if (id > 0) dm.remove(id)
        prefs.edit()
            .remove(KEY_DOWNLOAD_ID)
            .remove(KEY_ORIGINAL_URL)
            .remove(KEY_FILENAME)
            .remove(KEY_EXPECTED_SHA)
            .remove(KEY_COMPLETED_AT)
            .apply()
        result.success(true)
    }

    /**
     * Return the absolute path where DM will write the file. Lets Dart
     * skip path_provider's `getExternalStorageDirectory()` heuristics
     * and just read from the exact path.
     */
    private fun handleDestinationPath(call: MethodCall,
                                       result: MethodChannel.Result) {
        try {
            val filename = call.argument<String>("filename")
                ?: return result.error("BAD_ARGS", "filename required", null)
            result.success(destinationFile(context, filename).absolutePath)
        } catch (e: Exception) {
            result.error("PATH_FAILED", e.message, null)
        }
    }

    /**
     * Read-and-clear: returns true if the manifest receiver flagged a
     * completion since the last call. Dart polls this on app launch /
     * resume to know whether to trigger the verification + ready flow
     * for a download that completed while the app was dead.
     */
    private fun handleCompletedSinceLastCheck(result: MethodChannel.Result) {
        val completedAt = prefs.getLong(KEY_COMPLETED_AT, 0L)
        if (completedAt > 0) {
            prefs.edit().remove(KEY_COMPLETED_AT).apply()
            result.success(completedAt)
        } else {
            result.success(0L)
        }
    }

    private fun reasonToString(status: Int, reason: Int): String? {
        if (status == DownloadManager.STATUS_FAILED) {
            return when (reason) {
                DownloadManager.ERROR_CANNOT_RESUME -> "ERROR_CANNOT_RESUME"
                DownloadManager.ERROR_DEVICE_NOT_FOUND -> "ERROR_DEVICE_NOT_FOUND"
                DownloadManager.ERROR_FILE_ALREADY_EXISTS -> "ERROR_FILE_ALREADY_EXISTS"
                DownloadManager.ERROR_FILE_ERROR -> "ERROR_FILE_ERROR"
                DownloadManager.ERROR_HTTP_DATA_ERROR -> "ERROR_HTTP_DATA_ERROR"
                DownloadManager.ERROR_INSUFFICIENT_SPACE -> "ERROR_INSUFFICIENT_SPACE"
                DownloadManager.ERROR_TOO_MANY_REDIRECTS -> "ERROR_TOO_MANY_REDIRECTS"
                DownloadManager.ERROR_UNHANDLED_HTTP_CODE -> "ERROR_UNHANDLED_HTTP_CODE (likely $reason)"
                DownloadManager.ERROR_UNKNOWN -> "ERROR_UNKNOWN"
                else -> "HTTP $reason"
            }
        }
        if (status == DownloadManager.STATUS_PAUSED) {
            return when (reason) {
                DownloadManager.PAUSED_QUEUED_FOR_WIFI -> "PAUSED_QUEUED_FOR_WIFI"
                DownloadManager.PAUSED_WAITING_FOR_NETWORK -> "PAUSED_WAITING_FOR_NETWORK"
                DownloadManager.PAUSED_WAITING_TO_RETRY -> "PAUSED_WAITING_TO_RETRY"
                else -> "PAUSED_$reason"
            }
        }
        return null
    }
}
