package land.fx.files.dev

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Static (manifest-registered) BroadcastReceiver that catches
 * `android.intent.action.DOWNLOAD_COMPLETE` events fired by Android's
 * [DownloadManager] service.
 *
 * Why static (manifest) and not dynamic: if the user swipes the app
 * away during a download, our process is gone — dynamic receivers
 * registered in [MainActivity] die with it. A manifest receiver wakes
 * the app process on the broadcast even if it's been killed, which is
 * exactly what we need for a 770 MB download that may complete while
 * the user is in another app.
 *
 * What this does is intentionally minimal: it stamps a "completed at"
 * timestamp into SharedPreferences. The Dart side polls
 * `completedSinceLastCheck` on app launch / resume and runs the SHA +
 * GGUF-magic verification, then transitions the UI to ready. Doing the
 * verification here in Kotlin would mean re-implementing the integrity
 * defenses (the SHA pin, the fingerprint cache, the
 * ModelCorruptException → heuristic-fallback flow), all of which live
 * in Dart by design. Per both advisors: "broadcasts are wakeups; query
 * state is truth" — keep this receiver as the wakeup, not the
 * decision-maker.
 *
 * Manifest entry must use `android:exported="false"` — the broadcast is
 * targeted at our app by the DOWNLOAD_COMPLETE intent's package field,
 * so we don't need to be exported and shouldn't be.
 */
class ModelDownloadCompleteReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "ModelDownloadComplete"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
        val completedId = intent.getLongExtra(
            DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
        if (completedId < 0) return

        // Only react to OUR download. Other apps can use DownloadManager
        // too and we'd receive their broadcasts as well (system level).
        val prefs = context.getSharedPreferences(
            ModelDownloadHandler.PREFS_NAME, Context.MODE_PRIVATE)
        val ourId = prefs.getLong(ModelDownloadHandler.KEY_DOWNLOAD_ID, -1L)
        if (completedId != ourId) {
            Log.d(TAG, "ignoring DOWNLOAD_COMPLETE for id=$completedId " +
                "(ours is $ourId)")
            return
        }

        Log.i(TAG, "DOWNLOAD_COMPLETE for our model download id=$completedId")
        prefs.edit()
            .putLong(ModelDownloadHandler.KEY_COMPLETED_AT,
                System.currentTimeMillis())
            .apply()
    }
}
