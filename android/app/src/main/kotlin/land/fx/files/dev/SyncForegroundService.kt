package land.fx.files.dev

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Foreground Service that hosts the sync upload notification and runs a
 * dedicated Dart isolate so an in-flight upload survives `MainActivity`
 * destruction (the user swiping the app away from the recents stack).
 *
 * Architecture:
 *   - Manifest declares `foregroundServiceType="dataSync"` so the system
 *     allows long-running uploads (Android 14+ enforces a 6h/24h window
 *     for this type — fine for typical user uploads, see the design
 *     notes for the multi-file fallback).
 *   - `stopWithTask="false"` so swiping the app away does NOT stop the
 *     service. The process stays alive because of the foreground
 *     notification, and the Dart isolate spawned here keeps running.
 *   - `onCreate` spawns a fresh [FlutterEngine] via [FlutterEngineCache]
 *     and runs the `syncBackgroundEntrypoint` Dart entrypoint defined in
 *     `lib/sync_background_entrypoint.dart`. That entrypoint re-inits
 *     RustLib/Hive/auth in the service's isolate and drains the queue.
 *
 * Cross-isolate coordination with `MainActivity`'s isolate is handled
 * on the Dart side via a file-system lock on `<documentsDir>/
 * sync_queue.lock`. Both isolates contend for the lock before
 * processing the queue, so at most one drains it at a time. See the
 * design notes in `DIAGNOSIS_sync_a3_design_notes.md`.
 */
class SyncForegroundService : Service() {
    companion object {
        /** Cache key for the background FlutterEngine. */
        const val SYNC_ENGINE_KEY = "fxfiles_sync_engine"

        /** Dart entrypoint to launch; must be top-level + `@pragma('vm:entry-point')`. */
        const val DART_ENTRYPOINT = "syncBackgroundEntrypoint"

        /**
         * Library URI containing [DART_ENTRYPOINT]. **MUST match the
         * actual library where the function is declared**; without this
         * the 2-arg `DartEntrypoint` constructor defaults to
         * `package:<app>/main.dart` and Flutter AOT in release mode
         * fails with `Could not resolve main entrypoint function`.
         */
        const val DART_ENTRYPOINT_LIBRARY =
            "package:fula_files/sync_background_entrypoint.dart"

        /** Method channel used between the service and its Dart isolate. */
        const val METHOD_CHANNEL = "land.fx.files/sync_foreground_bridge"

        /** Intent action: stop the service (used by MainActivity on resume). */
        const val ACTION_STOP = "land.fx.files.SYNC_STOP"

        /** Intent action: update the foreground notification with new progress. */
        const val ACTION_UPDATE_PROGRESS = "land.fx.files.SYNC_UPDATE_PROGRESS"

        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_MAX_PROGRESS = "max_progress"
        const val EXTRA_ETA = "eta"

        /** Convenience for MainActivity / SyncNotificationService bridge. */
        fun startIntent(context: Context): Intent =
            Intent(context, SyncForegroundService::class.java)

        fun stopIntent(context: Context): Intent =
            Intent(context, SyncForegroundService::class.java).apply { action = ACTION_STOP }

        fun updateProgressIntent(
            context: Context,
            title: String,
            body: String,
            progress: Int,
            maxProgress: Int = 100,
            eta: String? = null,
        ): Intent = Intent(context, SyncForegroundService::class.java).apply {
            action = ACTION_UPDATE_PROGRESS
            putExtra(EXTRA_TITLE, title)
            putExtra(EXTRA_BODY, body)
            putExtra(EXTRA_PROGRESS, progress)
            putExtra(EXTRA_MAX_PROGRESS, maxProgress)
            if (eta != null) putExtra(EXTRA_ETA, eta)
        }
    }

    private var engine: FlutterEngine? = null
    private var methodChannel: MethodChannel? = null

    override fun onCreate() {
        super.onCreate()
        // Promote the process to foreground BEFORE any Dart work. The 5s
        // grace period for calling startForeground after the Service is
        // created is short on Android 14+; do it first thing.
        startForegroundWithInitialNotification()
        ensureEngineRunning()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                // MainActivity resumed and wants the main isolate to take
                // over. We stop here; the Dart entrypoint observes the
                // released file lock and bails out cleanly on its next
                // iteration.
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_UPDATE_PROGRESS -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "Syncing files"
                val body = intent.getStringExtra(EXTRA_BODY) ?: ""
                val progress = intent.getIntExtra(EXTRA_PROGRESS, -1)
                val maxProgress = intent.getIntExtra(EXTRA_MAX_PROGRESS, 100)
                val eta = intent.getStringExtra(EXTRA_ETA)
                updateNotification(title, body, progress, maxProgress, eta)
            }
        }
        // START_STICKY so the system restarts us if it kills the process
        // under memory pressure mid-upload. On restart, the Dart isolate
        // re-bootstraps from the persistent SyncTask queue.
        return START_STICKY
    }

    override fun onDestroy() {
        // Tear down the method channel; the engine is allowed to live in
        // the cache momentarily but we destroy it explicitly so the next
        // service spin-up re-bootstraps cleanly (avoids stale Hive state
        // surviving across service lifetimes).
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        engine?.let { e ->
            FlutterEngineCache.getInstance().remove(SYNC_ENGINE_KEY)
            e.destroy()
        }
        engine = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * `stopForeground(STOP_FOREGROUND_REMOVE)` is the API 24+ form;
     * the legacy `stopForeground(boolean)` was deprecated in API 33
     * but is the only thing available below API 24. We have callers
     * on the legacy form pinned via Flutter's minSdk default (21).
     */
    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    // ---- Foreground notification helpers --------------------------------

    private fun startForegroundWithInitialNotification() {
        val notification = buildNotification(
            title = "Syncing files",
            body = "Preparing to sync…",
            progress = -1,
            maxProgress = 100,
            eta = null,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                FxFilesApplication.SYNC_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            @Suppress("DEPRECATION")
            startForeground(FxFilesApplication.SYNC_NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(
        title: String,
        body: String,
        progress: Int,
        maxProgress: Int,
        eta: String?,
    ) {
        val notification = buildNotification(title, body, progress, maxProgress, eta)
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(FxFilesApplication.SYNC_NOTIFICATION_ID, notification)
    }

    private fun buildNotification(
        title: String,
        body: String,
        progress: Int,
        maxProgress: Int,
        eta: String?,
    ): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        val contentText = if (eta != null && progress >= 0) "$body\n$eta remaining" else body

        val builder = NotificationCompat.Builder(this, FxFilesApplication.SYNC_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(title)
            .setContentText(contentText)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setStyle(NotificationCompat.BigTextStyle().bigText(contentText))
        pendingIntent?.let { builder.setContentIntent(it) }
        if (progress >= 0) {
            builder.setProgress(maxProgress, progress, false)
            builder.setSubText("$progress%")
        } else {
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }

    // ---- FlutterEngine bootstrap ----------------------------------------

    private fun ensureEngineRunning() {
        if (engine != null) return

        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(applicationContext)
        }
        loader.ensureInitializationComplete(applicationContext, null)

        val cached = FlutterEngineCache.getInstance().get(SYNC_ENGINE_KEY)
        engine = cached ?: FlutterEngine(applicationContext).also { e ->
            // Run the dedicated entrypoint. This is NOT main(); it's a
            // separate top-level function annotated with
            // `@pragma('vm:entry-point')` in `lib/sync_background_entrypoint.dart`.
            //
            // **MUST use the 3-arg DartEntrypoint constructor.** The
            // 2-arg form `DartEntrypoint(bundle, functionName)` defaults
            // the library to `package:<app>/main.dart` — Flutter's AOT
            // snapshot in release mode then can't find
            // `syncBackgroundEntrypoint` there and surfaces:
            //
            //   E/flutter: Could not resolve main entrypoint function.
            //   E/flutter: Could not run the run main Dart entrypoint.
            //   E/flutter: Could not create root isolate.
            //
            // Debug mode silently "works" because the kernel has every
            // library loaded, so it finds the symbol regardless of the
            // library hint. Release-only failure. The 3-arg form passes
            // the correct library URI for symbol resolution.
            val entrypoint = DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                DART_ENTRYPOINT_LIBRARY,
                DART_ENTRYPOINT,
            )
            e.dartExecutor.executeDartEntrypoint(entrypoint)
            FlutterEngineCache.getInstance().put(SYNC_ENGINE_KEY, e)
        }

        // Bridge the Dart side back to the service so the entrypoint can
        // post progress updates and request shutdown when the queue
        // drains.
        methodChannel = MethodChannel(
            engine!!.dartExecutor.binaryMessenger,
            METHOD_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateProgress" -> {
                        val title = call.argument<String>("title") ?: "Syncing files"
                        val body = call.argument<String>("body") ?: ""
                        val progress = call.argument<Int>("progress") ?: -1
                        val maxProgress = call.argument<Int>("maxProgress") ?: 100
                        val eta = call.argument<String?>("eta")
                        updateNotification(title, body, progress, maxProgress, eta)
                        result.success(true)
                    }
                    "stopService" -> {
                        // Queue drained from the Dart side — service can
                        // shut down. We tear down here so the engine and
                        // notification go away atomically.
                        stopForegroundCompat()
                        stopSelf()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}
