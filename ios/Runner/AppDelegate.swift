import Flutter
import UIKit
import BackgroundTasks
import UserNotifications
import os

@main
@objc class AppDelegate: FlutterAppDelegate {
    private static let syncTaskIdentifier = "land.fx.files.sync"
    private static let refreshTaskIdentifier = "land.fx.files.refresh"
    private var methodChannel: FlutterMethodChannel?
    private var notificationChannel: FlutterMethodChannel?
    private var deviceMemoryChannel: FlutterMethodChannel?
    private var modelDownloadChannel: FlutterMethodChannel?
    // Retain the handler so its delegate (which holds the URLSession)
    // outlives method-call dispatch. Otherwise iOS won't deliver the
    // background-session events to a deallocated delegate.
    private let modelDownloadHandler = ModelDownloadHandler()

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        // Setup method channel for background sync control from Flutter
        if let controller = window?.rootViewController as? FlutterViewController {
            methodChannel = FlutterMethodChannel(
                name: "land.fx.files/background_sync",
                binaryMessenger: controller.binaryMessenger
            )

            methodChannel?.setMethodCallHandler { [weak self] call, result in
                switch call.method {
                case "scheduleSync":
                    self?.scheduleBackgroundSync()
                    result(true)
                case "cancelSync":
                    self?.cancelBackgroundSync()
                    result(true)
                default:
                    result(FlutterMethodNotImplemented)
                }
            }

            // Setup notification channel for sync progress
            notificationChannel = FlutterMethodChannel(
                name: "land.fx.files/ios_notification",
                binaryMessenger: controller.binaryMessenger
            )

            notificationChannel?.setMethodCallHandler { [weak self] call, result in
                switch call.method {
                case "updateBadge":
                    if let args = call.arguments as? [String: Any],
                       let badge = args["badge"] as? Int {
                        self?.updateAppBadge(badge)
                        result(true)
                    } else {
                        result(FlutterError(code: "INVALID_ARGS", message: "Badge number required", details: nil))
                    }
                case "showSyncComplete":
                    if let args = call.arguments as? [String: Any],
                       let fileCount = args["fileCount"] as? Int {
                        let hasErrors = args["hasErrors"] as? Bool ?? false
                        self?.showSyncCompleteNotification(fileCount: fileCount, hasErrors: hasErrors)
                        result(true)
                    } else {
                        result(FlutterError(code: "INVALID_ARGS", message: "File count required", details: nil))
                    }
                default:
                    result(FlutterMethodNotImplemented)
                }
            }

            // Request notification permission for sync progress
            requestNotificationPermission()

            // Device memory channel — used by the AI Automation feature to
            // gate on-device LLM loading. `totalRamBytes` is the device's
            // physical RAM (used at startup to classify the device into a
            // small/medium/large tier). `availableProcMemory` returns the
            // per-process headroom before jetsam kicks in, which is what
            // actually matters on iOS — total physical RAM is misleading
            // because iOS imposes a per-app cap well below it.
            deviceMemoryChannel = FlutterMethodChannel(
                name: "land.fx.files/device_memory",
                binaryMessenger: controller.binaryMessenger
            )

            deviceMemoryChannel?.setMethodCallHandler { call, result in
                switch call.method {
                case "totalRamBytes":
                    let total = ProcessInfo.processInfo.physicalMemory
                    result(NSNumber(value: total))
                case "availableProcMemory":
                    if #available(iOS 13.0, *) {
                        let available = os_proc_available_memory()
                        result(NSNumber(value: available))
                    } else {
                        // Pre-iOS-13: no honest API. Return nil so Dart
                        // treats it as "permissive — proceed".
                        result(nil)
                    }
                default:
                    result(FlutterMethodNotImplemented)
                }
            }

            // Model download channel — wraps background URLSession for
            // the on-device LLM model. Same method names as Android's
            // ModelDownloadHandler so Dart shares one code path.
            modelDownloadChannel = FlutterMethodChannel(
                name: "land.fx.files/model_download",
                binaryMessenger: controller.binaryMessenger
            )
            modelDownloadChannel?.setMethodCallHandler { [weak self] call, result in
                self?.modelDownloadHandler.handle(call, result: result)
            }
        }

        // Register background tasks
        registerBackgroundTasks()

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func registerBackgroundTasks() {
        // Register processing task (for long-running sync)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppDelegate.syncTaskIdentifier,
            using: nil
        ) { task in
            self.handleBackgroundSync(task: task as! BGProcessingTask)
        }

        // Register refresh task (for quick checks)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppDelegate.refreshTaskIdentifier,
            using: nil
        ) { task in
            self.handleBackgroundRefresh(task: task as! BGAppRefreshTask)
        }
    }

    func scheduleBackgroundSync() {
        // Schedule processing task for sync
        let request = BGProcessingTaskRequest(identifier: AppDelegate.syncTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
            debugPrint("Scheduled background sync task")
        } catch {
            debugPrint("Failed to schedule background sync: \(error)")
        }

        // Also schedule refresh task
        scheduleBackgroundRefresh()
    }

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: AppDelegate.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes

        do {
            try BGTaskScheduler.shared.submit(request)
            debugPrint("Scheduled background refresh task")
        } catch {
            debugPrint("Failed to schedule background refresh: \(error)")
        }
    }

    func cancelBackgroundSync() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppDelegate.syncTaskIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppDelegate.refreshTaskIdentifier)
        debugPrint("Cancelled background sync tasks")
    }

    private func handleBackgroundSync(task: BGProcessingTask) {
        // Schedule next sync
        scheduleBackgroundSync()

        // Set expiration handler — iOS calls this when time is almost up
        task.expirationHandler = { [weak self] in
            debugPrint("Background sync task expiring — notifying Flutter")
            self?.methodChannel?.invokeMethod("onBackgroundSyncExpiring", arguments: nil, result: nil)
            task.setTaskCompleted(success: false)
        }

        // Notify Flutter to process sync queue
        DispatchQueue.main.async { [weak self] in
            self?.methodChannel?.invokeMethod("onBackgroundSync", arguments: nil) { result in
                if let success = result as? Bool, success {
                    task.setTaskCompleted(success: true)
                } else {
                    task.setTaskCompleted(success: false)
                }
            }
        }
    }

    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        // Schedule next refresh
        scheduleBackgroundRefresh()

        // Set expiration handler — iOS calls this when time is almost up
        task.expirationHandler = { [weak self] in
            debugPrint("Background refresh task expiring — notifying Flutter")
            self?.methodChannel?.invokeMethod("onBackgroundSyncExpiring", arguments: nil, result: nil)
            task.setTaskCompleted(success: false)
        }

        // Quick check - notify Flutter
        DispatchQueue.main.async { [weak self] in
            self?.methodChannel?.invokeMethod("onBackgroundRefresh", arguments: nil) { result in
                if let success = result as? Bool, success {
                    task.setTaskCompleted(success: true)
                } else {
                    task.setTaskCompleted(success: false)
                }
            }
        }
    }

    override func applicationDidEnterBackground(_ application: UIApplication) {
        // Schedule sync when app goes to background
        scheduleBackgroundSync()
    }

    /// iOS relaunches the app in the background when a background
    /// URLSession completes a transfer. We stash the OS completion
    /// handler on the ModelDownloadHandler static; the
    /// `urlSessionDidFinishEvents` delegate callback invokes it after
    /// dispatching all pending events. Without this, the OS won't
    /// finalize its end of the cycle and may delay future events.
    override func application(_ application: UIApplication,
                              handleEventsForBackgroundURLSession identifier: String,
                              completionHandler: @escaping () -> Void) {
        // Only one identifier — the model-download one. If you ever add
        // more background sessions, dispatch by identifier here.
        // CRITICAL: touch the static session FIRST so the URLSession
        // (and its delegate) exists before the OS starts delivering
        // events. Then stash the completion handler. The delegate's
        // urlSessionDidFinishEvents calls back into the static.
        _ = ModelDownloadHandler.sharedSession
        ModelDownloadHandler.backgroundSessionCompletionHandler = completionHandler
    }

    // MARK: - Notification Support

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error = error {
                debugPrint("Notification permission error: \(error)")
            }
            debugPrint("Notification permission granted: \(granted)")
        }
    }

    private func updateAppBadge(_ badge: Int) {
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = badge
        }
    }

    private func showSyncCompleteNotification(fileCount: Int, hasErrors: Bool) {
        // Clear badge
        updateAppBadge(0)

        // Show local notification
        let content = UNMutableNotificationContent()
        content.title = hasErrors ? "Sync completed with errors" : "Sync complete"
        content.body = hasErrors
            ? "Synced \(fileCount) files. Some files failed to sync."
            : "Successfully synced \(fileCount) files"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "sync_complete",
            content: content,
            trigger: nil  // Show immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                debugPrint("Failed to show sync complete notification: \(error)")
            }
        }
    }
}
