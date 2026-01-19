package land.fx.files.dev

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import androidx.core.app.NotificationCompat
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.PowerManager
import android.provider.Settings
import android.util.Rational
import android.view.View
import android.view.WindowManager
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Enable edge-to-edge display for Android 15+ compatibility
        setupEdgeToEdge()
        // Create notification channel for background sync
        createSyncNotificationChannel()
    }

    private fun createSyncNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channelId = "fxfiles_sync_channel"
            val channelName = "File Sync"
            val channelDescription = "Shows progress when syncing files to cloud"
            val importance = NotificationManager.IMPORTANCE_LOW // Low importance = no sound

            val channel = NotificationChannel(channelId, channelName, importance).apply {
                description = channelDescription
                setShowBadge(false)
            }

            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun setupEdgeToEdge() {
        // Let the app draw behind system bars
        WindowCompat.setDecorFitsSystemWindows(window, false)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            window.statusBarColor = Color.TRANSPARENT
            window.navigationBarColor = Color.TRANSPARENT
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }
    }
    private val STORAGE_CHANNEL = "land.fx.files/storage"
    private val PIP_CHANNEL = "land.fx.files/pip"
    private val NOTIFICATION_CHANNEL = "land.fx.files/notification"
    private val BATTERY_CHANNEL = "land.fx.files/battery_optimization"
    private val SYNC_NOTIFICATION_CHANNEL = "land.fx.files/sync_notification"
    private val SYNC_NOTIFICATION_ID = 9001
    private val SYNC_CHANNEL_ID = "fxfiles_sync_channel"
    private var pipEventSink: EventChannel.EventSink? = null
    private var isInPipMode = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Notification channel - for opening notification settings
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFICATION_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openNotificationSettings" -> {
                    try {
                        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            // Android 8.0+ - Open app notification settings directly
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            }
                        } else {
                            // Older Android - Open general app settings
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                            }
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ERROR", "Could not open notification settings: ${e.message}", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Sync notification channel - for showing sync progress in notification bar
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYNC_NOTIFICATION_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "showSyncNotification" -> {
                    try {
                        val title = call.argument<String>("title") ?: "Syncing files"
                        val body = call.argument<String>("body") ?: "Uploading files to cloud..."
                        val progress = call.argument<Int>("progress") ?: -1
                        val maxProgress = call.argument<Int>("maxProgress") ?: 100

                        showSyncNotification(title, body, progress, maxProgress)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ERROR", "Failed to show notification: ${e.message}", null)
                    }
                }
                "hideSyncNotification" -> {
                    try {
                        hideSyncNotification()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ERROR", "Failed to hide notification: ${e.message}", null)
                    }
                }
                "showSyncCompleteNotification" -> {
                    try {
                        val title = call.argument<String>("title") ?: "Sync complete"
                        val body = call.argument<String>("body") ?: "Files synced successfully"

                        showSyncCompleteNotification(title, body)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ERROR", "Failed to show notification: ${e.message}", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Battery optimization channel - for background sync
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BATTERY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoringBatteryOptimizations" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(powerManager.isIgnoringBatteryOptimizations(packageName))
                    } else {
                        // Battery optimization not applicable before Android 6.0
                        result.success(true)
                    }
                }
                "requestDisableBatteryOptimization" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        try {
                            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                data = Uri.parse("package:$packageName")
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ERROR", "Could not request battery optimization exemption: ${e.message}", null)
                        }
                    } else {
                        result.success(true)
                    }
                }
                "openBatteryOptimizationSettings" -> {
                    try {
                        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        } else {
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                            }
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ERROR", "Could not open battery settings: ${e.message}", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Storage channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openManageStorageSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        try {
                            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                            intent.data = Uri.parse("package:$packageName")
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                                startActivity(intent)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("ERROR", "Could not open settings: ${e2.message}", null)
                            }
                        }
                    } else {
                        result.error("UNSUPPORTED", "Android 11+ required", null)
                    }
                }
                "hasManageStoragePermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        result.success(Environment.isExternalStorageManager())
                    } else {
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // PiP channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PIP_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enterPip" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        try {
                            val aspectRatioWidth = call.argument<Int>("width") ?: 16
                            val aspectRatioHeight = call.argument<Int>("height") ?: 9
                            val rational = Rational(aspectRatioWidth, aspectRatioHeight)

                            val params = PictureInPictureParams.Builder()
                                .setAspectRatio(rational)
                                .build()

                            enterPictureInPictureMode(params)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("PIP_ERROR", "Failed to enter PiP: ${e.message}", null)
                        }
                    } else {
                        result.error("UNSUPPORTED", "PiP requires Android 8.0+", null)
                    }
                }
                "isPipSupported" -> {
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                }
                "isInPipMode" -> {
                    result.success(isInPipMode)
                }
                "setAutoPip" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        try {
                            val enabled = call.argument<Boolean>("enabled") ?: false
                            val aspectRatioWidth = call.argument<Int>("width") ?: 16
                            val aspectRatioHeight = call.argument<Int>("height") ?: 9
                            val rational = Rational(aspectRatioWidth, aspectRatioHeight)

                            val params = PictureInPictureParams.Builder()
                                .setAspectRatio(rational)
                                .setAutoEnterEnabled(enabled)
                                .build()

                            setPictureInPictureParams(params)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("PIP_ERROR", "Failed to set auto PiP: ${e.message}", null)
                        }
                    } else {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // PiP event channel for state changes
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "$PIP_CHANNEL/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    pipEventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    pipEventSink = null
                }
            }
        )
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        isInPipMode = isInPictureInPictureMode
        pipEventSink?.success(mapOf(
            "isInPipMode" to isInPictureInPictureMode
        ))
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Auto-enter PiP when user presses home during video playback
        // This is handled by setAutoPip in Flutter when video is playing
    }

    private fun showSyncNotification(title: String, body: String, progress: Int, maxProgress: Int) {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // Create intent to open app when notification is tapped
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(this, SYNC_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(pendingIntent)
            .setOngoing(true) // Can't be dismissed
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)

        // Set progress if determinate
        if (progress >= 0) {
            builder.setProgress(maxProgress, progress, false)
        } else {
            builder.setProgress(0, 0, true) // Indeterminate
        }

        notificationManager.notify(SYNC_NOTIFICATION_ID, builder.build())
    }

    private fun hideSyncNotification() {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(SYNC_NOTIFICATION_ID)
    }

    private fun showSyncCompleteNotification(title: String, body: String) {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // Create intent to open app when notification is tapped
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(this, SYNC_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true) // Dismiss when tapped
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)

        notificationManager.notify(SYNC_NOTIFICATION_ID, builder.build())
    }
}
