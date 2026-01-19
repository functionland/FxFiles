package land.fx.files.dev

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
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
        createNotificationChannel()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                SYNC_CHANNEL_ID,
                "File Sync",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows progress when syncing files to cloud"
                setShowBadge(false)
            }

            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }
}
