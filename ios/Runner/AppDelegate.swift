import Flutter
import UIKit
import BackgroundTasks

@main
@objc class AppDelegate: FlutterAppDelegate {
    private static let syncTaskIdentifier = "land.fx.files.sync"
    private static let refreshTaskIdentifier = "land.fx.files.refresh"
    private var methodChannel: FlutterMethodChannel?

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

        // Set expiration handler
        task.expirationHandler = {
            // Clean up if task expires
            debugPrint("Background sync task expired")
        }

        // Notify Flutter to process sync queue
        DispatchQueue.main.async { [weak self] in
            self?.methodChannel?.invokeMethod("onBackgroundSync", arguments: nil) { result in
                // Task completion handled by Flutter callback
                if let success = result as? Bool, success {
                    task.setTaskCompleted(success: true)
                } else {
                    task.setTaskCompleted(success: false)
                }
            }
        }

        // Fallback: complete after timeout if Flutter doesn't respond
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            // If task is still running, complete it
            task.setTaskCompleted(success: true)
        }
    }

    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        // Schedule next refresh
        scheduleBackgroundRefresh()

        // Set expiration handler
        task.expirationHandler = {
            debugPrint("Background refresh task expired")
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

        // Fallback timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            task.setTaskCompleted(success: true)
        }
    }

    override func applicationDidEnterBackground(_ application: UIApplication) {
        // Schedule sync when app goes to background
        scheduleBackgroundSync()
    }
}
