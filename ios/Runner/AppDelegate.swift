import Flutter
import UIKit
import BackgroundTasks
import UserNotifications
import os

@main
@objc class AppDelegate: FlutterAppDelegate {
    private static let syncTaskIdentifier = "land.fx.files.sync"
    private static let refreshTaskIdentifier = "land.fx.files.refresh"
    private static let dumpDrainTaskIdentifier = "land.fx.files.dump"
    // Must match `ShareViewController.appGroupIdentifier` and the
    // entry in Runner.entitlements.
    private static let appGroupIdentifier = "group.land.fx.files"
    // Subdirectory layout used by both the Share Extension (writes to
    // App Group container) and the main app (reads + moves into the
    // app sandbox / Documents).
    private static let dumpPendingDirName = "dump_pending"
    private static let dumpManifestName = "manifest.json"
    private static let dumpStaleTxnTTLSeconds: TimeInterval = 7 * 24 * 60 * 60
    private var methodChannel: FlutterMethodChannel?
    private var notificationChannel: FlutterMethodChannel?
    private var deviceMemoryChannel: FlutterMethodChannel?
    private var modelDownloadChannel: FlutterMethodChannel?
    private var dumpBridgeChannel: FlutterMethodChannel?
    private var dumpNotificationChannel: FlutterMethodChannel?
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

            // Dump bridge — drains the Share Extension's App Group
            // staging directory and reports the descriptors back so
            // the Dart side can call DumpService.ingestAndSchedule.
            // See lib/core/services/dump_ios_bridge.dart for the
            // Dart-side contract.
            dumpBridgeChannel = FlutterMethodChannel(
                name: "land.fx.files/dump_ios_bridge",
                binaryMessenger: controller.binaryMessenger
            )
            dumpBridgeChannel?.setMethodCallHandler { [weak self] call, result in
                switch call.method {
                case "drainAppGroupContainer":
                    DispatchQueue.global(qos: .userInitiated).async {
                        let descriptors = self?.drainAppGroupContainerSync() ?? []
                        DispatchQueue.main.async {
                            result(descriptors)
                        }
                    }
                default:
                    result(FlutterMethodNotImplemented)
                }
            }

            // Dump notification channel — Dart-side
            // DumpNotificationService posts stage-2 ("Dumped …")
            // notifications via this channel; the Share Extension
            // posts stage-1 ("queued") directly. See plan Phase 8 +
            // R15 (privacy-private visibility) + R5 (auth from main
            // app only).
            dumpNotificationChannel = FlutterMethodChannel(
                name: "land.fx.files/dump_notification_ios",
                binaryMessenger: controller.binaryMessenger
            )
            dumpNotificationChannel?.setMethodCallHandler { [weak self] call, result in
                self?.handleDumpNotificationCall(call, result: result)
            }
        }

        // Register background tasks
        registerBackgroundTasks()

        // Submit an initial drain BGTask — R4: only the main app
        // submits, never the Share Extension. The handler re-arms
        // itself after each fire.
        submitDumpDrainTask()

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

        // Register Dump drain task — see Dump plan revision R4. iOS
        // schedules this opportunistically (charging + Wi-Fi + recent
        // app use); the foreground `AppLifecycleState.resumed` drain
        // on the Dart side is the primary path.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppDelegate.dumpDrainTaskIdentifier,
            using: nil
        ) { task in
            self.handleDumpDrainTask(task: task as! BGProcessingTask)
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

    // MARK: - Dump drain (Share Extension handoff)

    private func handleDumpDrainTask(task: BGProcessingTask) {
        // Re-arm BEFORE doing the work so we always have a pending
        // request — iOS only ever has one of these in flight at once.
        submitDumpDrainTask()

        task.expirationHandler = {
            debugPrint("Dump drain BGTask expiring")
            task.setTaskCompleted(success: false)
        }

        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else {
                task.setTaskCompleted(success: false)
                return
            }
            let descriptors = self.drainAppGroupContainerSync()
            // The Dart side does the actual ingest the next time the
            // user opens the app. Here we just stage to the main app
            // sandbox so the descriptors survive until then.
            task.setTaskCompleted(success: true)
            debugPrint("Dump drain BGTask completed (\(descriptors.count) txns)")
        }
    }

    func submitDumpDrainTask() {
        let request = BGProcessingTaskRequest(
            identifier: AppDelegate.dumpDrainTaskIdentifier
        )
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Common failures: simulator (BGTaskScheduler unavailable),
            // app not in a launch-recent state, or quota exceeded.
            // Either way we surface to logs only — the foreground
            // drain path is the reliable channel.
            debugPrint("submitDumpDrainTask failed: \(error)")
        }
    }

    /// Reads the App Group's `dump_pending/<txn>/` directories that
    /// have a committed `manifest.json`. For each, moves the payloads
    /// into the main app's `Documents/dump_pending/` and returns one
    /// descriptor map per transaction. The App Group txn dir is
    /// deleted on successful move; orphan dirs older than 7 days are
    /// swept (R6).
    ///
    /// Returns descriptor list to the Dart side via
    /// `MethodChannel("land.fx.files/dump_ios_bridge").drainAppGroupContainer`.
    /// Synchronous + thread-safe — called from main-isolate
    /// MethodChannel dispatch and from the BGTask handler.
    private func drainAppGroupContainerSync() -> [[String: Any]] {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppDelegate.appGroupIdentifier
        ) else {
            debugPrint("Dump drain: App Group container not available")
            return []
        }
        let appGroupPending = groupURL
            .appendingPathComponent(AppDelegate.dumpPendingDirName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: appGroupPending.path) else {
            return []
        }
        let now = Date()
        var descriptors: [[String: Any]] = []
        guard let txnDirs = try? FileManager.default.contentsOfDirectory(
            at: appGroupPending,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        guard let documentsDir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else {
            return []
        }
        let appPendingDir = documentsDir
            .appendingPathComponent(AppDelegate.dumpPendingDirName, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: appPendingDir,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        for txnDir in txnDirs {
            let isDir = (try? txnDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir { continue }
            let manifestURL = txnDir.appendingPathComponent(AppDelegate.dumpManifestName)

            if !FileManager.default.fileExists(atPath: manifestURL.path) {
                // Incomplete txn — keep it for now; sweep if older
                // than the TTL.
                if let created = try? txnDir.resourceValues(forKeys: [.creationDateKey]).creationDate,
                   now.timeIntervalSince(created) > AppDelegate.dumpStaleTxnTTLSeconds {
                    try? FileManager.default.removeItem(at: txnDir)
                    debugPrint("Dump drain: pruned stale incomplete txn \(txnDir.lastPathComponent)")
                }
                continue
            }

            guard let data = try? Data(contentsOf: manifestURL),
                  let raw = try? JSONSerialization.jsonObject(with: data),
                  let manifest = raw as? [String: Any] else {
                debugPrint("Dump drain: manifest unreadable in \(txnDir.lastPathComponent)")
                continue
            }
            guard let items = manifest["items"] as? [[String: Any]],
                  !items.isEmpty else {
                try? FileManager.default.removeItem(at: txnDir)
                continue
            }

            var movedPaths: [String] = []
            var mimeTypes: [Any] = []
            var originalNames: [String] = []
            var textPayload: String? = nil
            var moveFailed = false

            for item in items {
                guard let localFile = item["localFile"] as? String else {
                    moveFailed = true
                    break
                }
                let sourceURL = txnDir.appendingPathComponent(localFile)
                if !FileManager.default.fileExists(atPath: sourceURL.path) {
                    // Payload missing — skip the whole txn and let TTL
                    // sweep it later.
                    moveFailed = true
                    break
                }
                let dest = uniqueDestination(
                    in: appPendingDir,
                    filename: localFile
                )
                do {
                    try FileManager.default.moveItem(at: sourceURL, to: dest)
                    try? FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                        ofItemAtPath: dest.path
                    )
                    movedPaths.append(dest.path)
                    mimeTypes.append(item["mimeType"] ?? NSNull())
                    if let originalName = item["originalName"] as? String {
                        originalNames.append(originalName)
                    } else {
                        originalNames.append(localFile)
                    }
                    if textPayload == nil, let tp = item["textPayload"] as? String {
                        textPayload = tp
                    }
                } catch {
                    debugPrint("Dump drain move failed: \(error)")
                    moveFailed = true
                    break
                }
            }

            if moveFailed || movedPaths.isEmpty {
                // Don't ack — leave the txn dir for retry next pass.
                continue
            }

            var descriptor: [String: Any] = [
                "txnId": manifest["txnId"] ?? txnDir.lastPathComponent,
                "paths": movedPaths,
                "mimeTypes": mimeTypes,
                "originalNames": originalNames,
                "sourceApp": manifest["sourceApp"] ?? "ios-share",
            ]
            if let tp = textPayload {
                descriptor["textPayload"] = tp
            }
            descriptors.append(descriptor)

            // Successful import — delete the App Group txn dir.
            try? FileManager.default.removeItem(at: txnDir)
        }

        return descriptors
    }

    /// Returns a URL inside [dir] that doesn't yet exist by prepending
    /// a UUID prefix on collision. Bounded loop (1 try is normally
    /// enough; the original filename already includes a UUID prefix
    /// from the Share Extension).
    private func uniqueDestination(in dir: URL, filename: String) -> URL {
        var candidate = dir.appendingPathComponent(filename)
        var attempts = 0
        while FileManager.default.fileExists(atPath: candidate.path) && attempts < 16 {
            attempts += 1
            candidate = dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(filename)")
        }
        return candidate
    }

    // MARK: - Dump notification (stage 2 — "uploaded")

    /// Called by Dart's `DumpNotificationService` on iOS. Mirrors the
    /// shape of the Android MethodChannel handler in MainActivity.kt.
    private func handleDumpNotificationCall(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        switch call.method {
        case "requestAuthorization":
            // R5 — main app owns this prompt, not the Share Extension.
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound]
            ) { granted, error in
                if let error = error {
                    debugPrint("Dump notification permission error: \(error)")
                    result(false)
                } else {
                    result(granted)
                }
            }
        case "showDumpQueued",
             "showDumpReceived",
             "showDumpComplete",
             "showDumpPendingAuth",
             "showDumpFailed":
            postDumpNotification(call: call, result: result)
        case "dismissQueued":
            // Called by stage 2 to clear the stage-1 notifications.
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                let ids = delivered
                    .map { $0.request.identifier }
                    .filter { $0.hasPrefix("dump.queued.") }
                if !ids.isEmpty {
                    UNUserNotificationCenter.current()
                        .removeDeliveredNotifications(withIdentifiers: ids)
                }
                result(true)
            }
        case "hideDumpNotification":
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                let ids = delivered
                    .map { $0.request.identifier }
                    .filter { $0.hasPrefix("dump.") }
                if !ids.isEmpty {
                    UNUserNotificationCenter.current()
                        .removeDeliveredNotifications(withIdentifiers: ids)
                }
                result(true)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func postDumpNotification(
        call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        let args = (call.arguments as? [String: Any]) ?? [:]
        let title = (args["title"] as? String) ?? "Dump"
        let body = (args["body"] as? String) ?? ""
        let deepLink = args["deepLink"] as? String
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if #available(iOS 12.0, *) {
            content.threadIdentifier = "dump"
        }
        if let deepLink = deepLink {
            content.userInfo = ["deepLink": deepLink]
        }
        // Distinct identifier per call so multiple posts coexist if
        // they arrive in quick succession. Stage-1 IDs use the
        // `dump.queued.*` prefix; stage-2 use `dump.uploaded.*` so
        // `dismissQueued` can target the right cohort.
        let prefix: String
        switch call.method {
        case "showDumpQueued":      prefix = "dump.queued"
        case "showDumpReceived":    prefix = "dump.received"
        case "showDumpComplete":    prefix = "dump.uploaded"
        case "showDumpPendingAuth": prefix = "dump.pendingAuth"
        case "showDumpFailed":      prefix = "dump.failed"
        default:                    prefix = "dump"
        }
        let request = UNNotificationRequest(
            identifier: "\(prefix).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                debugPrint("postDumpNotification failed: \(error)")
                result(false)
            } else {
                result(true)
            }
        }
    }
}
