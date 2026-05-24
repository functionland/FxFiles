package land.fx.files.dev

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * Custom Application class that creates notification channels early
 * and provides notification helpers for background sync.
 */
class FxFilesApplication : Application() {

    companion object {
        const val SYNC_CHANNEL_ID = "fxfiles_sync_channel"
        const val SYNC_NOTIFICATION_ID = 9001

        // Dump feature notification channel + IDs. Separate from sync
        // because the semantics are different (Dump is a finished
        // event, sync is ongoing progress). Received and complete
        // share the same ID so the OS updates in place; pendingAuth
        // and failed get their own IDs so they don't get clobbered.
        const val DUMP_CHANNEL_ID = "fxfiles_dump_channel"
        const val DUMP_RECEIVED_NOTIFICATION_ID = 9101
        const val DUMP_PENDING_AUTH_NOTIFICATION_ID = 9102
        const val DUMP_FAILED_NOTIFICATION_ID = 9103

        private var instance: FxFilesApplication? = null

        fun getInstance(): FxFilesApplication? = instance

        /**
         * Show a sync notification - can be called from anywhere including background workers
         */
        fun showSyncNotification(context: Context, title: String, text: String, progress: Int = -1) {
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            // Ensure channel exists
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                var channel = notificationManager.getNotificationChannel(SYNC_CHANNEL_ID)
                if (channel == null) {
                    channel = NotificationChannel(
                        SYNC_CHANNEL_ID,
                        "File Sync",
                        NotificationManager.IMPORTANCE_LOW
                    ).apply {
                        description = "Shows progress when syncing files to cloud"
                        setShowBadge(false)
                    }
                    notificationManager.createNotificationChannel(channel)
                }
            }

            val notification = buildSyncNotification(context, title, text, progress, true)
            notificationManager.notify(SYNC_NOTIFICATION_ID, notification)
        }

        /**
         * Hide the sync notification
         */
        fun hideSyncNotification(context: Context) {
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.cancel(SYNC_NOTIFICATION_ID)
        }

        /**
         * Build a sync notification
         */
        fun buildSyncNotification(context: Context, title: String, text: String, progress: Int = -1, ongoing: Boolean = true): Notification {
            // Get launch intent for when notification is tapped
            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            val pendingIntent = if (launchIntent != null) {
                PendingIntent.getActivity(
                    context, 0, launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            } else null

            return NotificationCompat.Builder(context, SYNC_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(pendingIntent)
                .setOngoing(ongoing)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .apply {
                    if (progress >= 0) {
                        setProgress(100, progress, false)
                    } else if (ongoing) {
                        setProgress(0, 0, true)
                    }
                }
                .build()
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannels()
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val syncChannel = NotificationChannel(
            SYNC_CHANNEL_ID,
            "File Sync",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shows progress when syncing files to cloud"
            setShowBadge(false)
        }
        notificationManager.createNotificationChannel(syncChannel)

        // Dump channel — IMPORTANCE_DEFAULT so finished-event posts
        // surface to the user without being silenced. Lock-screen
        // visibility deliberately PRIVATE (R15) so filenames don't
        // leak on a locked device.
        val dumpChannel = NotificationChannel(
            DUMP_CHANNEL_ID,
            "Dump",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "Notifies when shared content lands in your Dump"
            setShowBadge(true)
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        }
        notificationManager.createNotificationChannel(dumpChannel)
    }
}

// ---------------------------------------------------------------------------
// Dump notification helpers (declared at file-scope, used by the
// DumpShareActivity AND the MainActivity MethodChannel handler). Each
// helper ensures the channel exists (idempotent) so they're safe even
// if some future startup path skips Application.onCreate.
// ---------------------------------------------------------------------------

private fun ensureDumpChannel(context: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE)
            as NotificationManager
    if (mgr.getNotificationChannel(FxFilesApplication.DUMP_CHANNEL_ID) == null) {
        val ch = NotificationChannel(
            FxFilesApplication.DUMP_CHANNEL_ID,
            "Dump",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "Notifies when shared content lands in your Dump"
            setShowBadge(true)
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        }
        mgr.createNotificationChannel(ch)
    }
}

private fun dumpDeepLinkIntent(context: Context, deepLink: String?): PendingIntent? {
    val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    val intent = if (deepLink != null) {
        Intent(Intent.ACTION_VIEW, Uri.parse(deepLink)).setPackage(context.packageName)
    } else {
        context.packageManager.getLaunchIntentForPackage(context.packageName)
    } ?: return null
    return PendingIntent.getActivity(context, 0, intent, flags)
}

fun FxFilesApplication.Companion.showDumpReceivedNotification(
    context: Context,
    count: Int,
) {
    ensureDumpChannel(context)
    val body = if (count == 1) "Processing 1 dump…" else "Processing $count dumps…"
    val notif = NotificationCompat.Builder(context, DUMP_CHANNEL_ID)
        .setSmallIcon(android.R.drawable.stat_sys_upload)
        .setContentTitle("FxFiles Dump")
        .setContentText(body)
        .setContentIntent(dumpDeepLinkIntent(context, "fxfiles://dump"))
        .setOngoing(false)
        .setPriority(NotificationCompat.PRIORITY_DEFAULT)
        .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        .setAutoCancel(false)
        .setProgress(0, 0, true)
        .build()
    (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
        .notify(DUMP_RECEIVED_NOTIFICATION_ID, notif)
}

fun FxFilesApplication.Companion.showDumpCompleteNotification(
    context: Context,
    title: String,
    body: String,
    deepLink: String?,
    hasErrors: Boolean,
) {
    ensureDumpChannel(context)
    val icon = if (hasErrors)
        android.R.drawable.stat_sys_warning
    else
        android.R.drawable.stat_sys_upload_done
    val notif = NotificationCompat.Builder(context, DUMP_CHANNEL_ID)
        .setSmallIcon(icon)
        .setContentTitle(title)
        .setContentText(body)
        .setContentIntent(dumpDeepLinkIntent(context, deepLink))
        .setAutoCancel(true)
        .setPriority(NotificationCompat.PRIORITY_DEFAULT)
        .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        .build()
    // Reuse the RECEIVED id so the OS updates in-place rather than
    // stacking. Per the plan: "The Android notification ID stays
    // stable across the two posts so the OS updates in place".
    (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
        .notify(DUMP_RECEIVED_NOTIFICATION_ID, notif)
}

fun FxFilesApplication.Companion.showDumpDuplicateNotification(
    context: Context,
    title: String,
    body: String,
    deepLink: String?,
) {
    ensureDumpChannel(context)
    val notif = NotificationCompat.Builder(context, DUMP_CHANNEL_ID)
        .setSmallIcon(android.R.drawable.stat_sys_upload_done)
        .setContentTitle(title)
        .setContentText(body)
        .setContentIntent(dumpDeepLinkIntent(context, deepLink))
        .setAutoCancel(true)
        .setPriority(NotificationCompat.PRIORITY_DEFAULT)
        .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        .build()
    // Reuse the RECEIVED id so the OS replaces the hanging
    // "Processing…" notification in-place rather than stacking
    // a second entry alongside it.
    (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
        .notify(DUMP_RECEIVED_NOTIFICATION_ID, notif)
}

fun FxFilesApplication.Companion.showDumpPendingAuthNotification(
    context: Context,
    title: String,
    body: String,
    deepLink: String?,
) {
    ensureDumpChannel(context)
    val notif = NotificationCompat.Builder(context, DUMP_CHANNEL_ID)
        .setSmallIcon(android.R.drawable.stat_sys_warning)
        .setContentTitle(title)
        .setContentText(body)
        .setContentIntent(dumpDeepLinkIntent(context, deepLink))
        .setAutoCancel(true)
        .setPriority(NotificationCompat.PRIORITY_DEFAULT)
        .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        .build()
    (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
        .notify(DUMP_PENDING_AUTH_NOTIFICATION_ID, notif)
}

fun FxFilesApplication.Companion.showDumpFailedNotification(
    context: Context,
    title: String,
    body: String,
    deepLink: String?,
) {
    ensureDumpChannel(context)
    val notif = NotificationCompat.Builder(context, DUMP_CHANNEL_ID)
        .setSmallIcon(android.R.drawable.stat_sys_warning)
        .setContentTitle(title)
        .setContentText(body)
        .setContentIntent(dumpDeepLinkIntent(context, deepLink))
        .setAutoCancel(true)
        .setPriority(NotificationCompat.PRIORITY_DEFAULT)
        .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        .build()
    (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
        .notify(DUMP_FAILED_NOTIFICATION_ID, notif)
}

fun FxFilesApplication.Companion.hideDumpNotification(context: Context) {
    val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE)
            as NotificationManager
    mgr.cancel(DUMP_RECEIVED_NOTIFICATION_ID)
    mgr.cancel(DUMP_PENDING_AUTH_NOTIFICATION_ID)
    mgr.cancel(DUMP_FAILED_NOTIFICATION_ID)
}
