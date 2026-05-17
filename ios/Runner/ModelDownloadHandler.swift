import Foundation
import Flutter

/// iOS counterpart of `ModelDownloadHandler.kt` — wraps the OS background
/// URLSession daemon (`nsurlsessiond`) for the on-device LLM model
/// download. Unlike Android, iOS doesn't have a single one-shot download
/// service primitive — the right tool is `URLSession` with
/// `URLSessionConfiguration.background(withIdentifier:)`.
///
/// Why this is the right primitive:
/// - The transfer is handled by a system daemon, not our app process.
///   The app can be suspended or even swipe-killed and the download
///   keeps going. iOS relaunches the app in the background on
///   completion via `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
/// - `isDiscretionary = false` ensures the OS starts the transfer
///   immediately rather than waiting for "optimal" conditions
///   (charging, Wi-Fi-and-idle). Right for a user-initiated download.
/// - No `UIBackgroundModes` entry needed in Info.plist. Both advisors
///   were explicit: declaring background modes you don't need is App
///   Store review heat.
///
/// Same method names as the Android handler (`start`, `query`, `cancel`,
/// `destinationPath`, `completedSinceLastCheck`) so Dart can share a
/// single code path.
///
/// Status persisted to `UserDefaults` keyed by
/// `land.fx.files.modelDownload.*`. Dart reads this on launch as the
/// reconciliation source of truth — "callbacks are wakeups, query state
/// is truth."
@objc class ModelDownloadHandler: NSObject {
    private static let sessionIdentifier = "land.fx.files.ai-model-download"

    private static let keyTaskIdentifier = "land.fx.files.modelDownload.taskIdentifier"
    private static let keyOriginalUrl = "land.fx.files.modelDownload.originalUrl"
    private static let keyFilename = "land.fx.files.modelDownload.filename"
    private static let keyExpectedSha = "land.fx.files.modelDownload.expectedSha"
    private static let keyCompletedAt = "land.fx.files.modelDownload.completedAtMs"
    private static let keyTotalBytes = "land.fx.files.modelDownload.totalBytes"
    private static let keyBytesDownloaded = "land.fx.files.modelDownload.bytesDownloaded"
    private static let keyStatus = "land.fx.files.modelDownload.status"
    private static let keyReasonText = "land.fx.files.modelDownload.reasonText"

    /// AppDelegate retains the handoff completion handler from
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// and invokes it after `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
    /// Stored as static so the AppDelegate can hand it off whenever the
    /// session is recreated (background relaunch case).
    static var backgroundSessionCompletionHandler: (() -> Void)?

    /// Static, eagerly-constructed URLSession + delegate. iOS's
    /// background-URLSession contract: only one session per identifier
    /// per app, and on background relaunch the OS will deliver pending
    /// events to whatever delegate is associated with the session. If
    /// we constructed the session lazily on a per-instance basis, a
    /// background relaunch into a freshly-allocated app could race the
    /// OS event delivery before the session exists. Constructing
    /// statically (initialised at class-load time) means the delegate
    /// is alive before any URLSession delegate method can fire.
    static let sharedDelegate = ModelDownloadSessionDelegate()
    static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true // Dart enforces wifiOnly itself.
        return URLSession(configuration: config,
                          delegate: sharedDelegate,
                          delegateQueue: nil)
    }()

    private var session: URLSession { Self.sharedSession }

    @objc func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            handleStart(call, result: result)
        case "query":
            handleQuery(call, result: result)
        case "cancel":
            handleCancel(result: result)
        case "destinationPath":
            handleDestinationPath(call, result: result)
        case "completedSinceLastCheck":
            handleCompletedSinceLastCheck(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - start

    private func handleStart(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let urlStr = args["url"] as? String,
              let url = URL(string: urlStr),
              let filename = args["filename"] as? String
        else {
            result(FlutterError(code: "BAD_ARGS", message: "url and filename required", details: nil))
            return
        }
        let wifiOnly = args["wifiOnly"] as? Bool ?? true
        let expectedSha = args["expectedSha"] as? String ?? ""

        let defaults = UserDefaults.standard
        defaults.set(urlStr, forKey: Self.keyOriginalUrl)
        defaults.set(filename, forKey: Self.keyFilename)
        defaults.set(expectedSha, forKey: Self.keyExpectedSha)
        defaults.set("pending", forKey: Self.keyStatus)
        defaults.removeObject(forKey: Self.keyCompletedAt)

        // wifiOnly is enforced at the configuration level: when true,
        // we use a separate session config that disallows cellular.
        // For simplicity (and to avoid juggling multiple sessions),
        // we just set allowsCellularAccess on the request itself.
        var request = URLRequest(url: url)
        request.allowsCellularAccess = !wifiOnly

        // Resolve any in-flight task for the same URL before starting
        // a new one — idempotency for repeated start() calls.
        session.getAllTasks { existingTasks in
            for task in existingTasks {
                if task.state == .running || task.state == .suspended,
                   task.originalRequest?.url?.absoluteString == urlStr {
                    let id = task.taskIdentifier
                    defaults.set(id, forKey: Self.keyTaskIdentifier)
                    DispatchQueue.main.async { result(id) }
                    return
                }
            }
            let task = self.session.downloadTask(with: request)
            // Stash the target filename in the task description so the
            // delegate can move the temp file to the right place.
            task.taskDescription = filename
            defaults.set(task.taskIdentifier, forKey: Self.keyTaskIdentifier)
            task.resume()
            DispatchQueue.main.async { result(task.taskIdentifier) }
        }
    }

    // MARK: - query

    private func handleQuery(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let defaults = UserDefaults.standard
        let status = defaults.string(forKey: Self.keyStatus) ?? "unknown"
        let downloaded = defaults.integer(forKey: Self.keyBytesDownloaded)
        let total = defaults.object(forKey: Self.keyTotalBytes) as? Int ?? -1
        let reason = defaults.string(forKey: Self.keyReasonText)

        var localUri: String? = nil
        if status == "successful" {
            if let filename = defaults.string(forKey: Self.keyFilename) {
                localUri = self.finalDestinationPath(filename: filename)
            }
        }

        result([
            "status": status,
            "bytesDownloaded": downloaded,
            "totalBytes": total,
            "localUri": localUri as Any,
            "reasonText": reason as Any
        ])
    }

    // MARK: - cancel

    private func handleCancel(result: @escaping FlutterResult) {
        session.getAllTasks { tasks in
            for task in tasks { task.cancel() }
            UserDefaults.standard.removeObject(forKey: Self.keyTaskIdentifier)
            UserDefaults.standard.removeObject(forKey: Self.keyStatus)
            UserDefaults.standard.removeObject(forKey: Self.keyCompletedAt)
            DispatchQueue.main.async { result(true) }
        }
    }

    // MARK: - destinationPath

    private func handleDestinationPath(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let filename = args["filename"] as? String
        else {
            result(FlutterError(code: "BAD_ARGS", message: "filename required", details: nil))
            return
        }
        result(self.finalDestinationPath(filename: filename))
    }

    /// Returns the path inside ApplicationSupport where the file lives
    /// after the delegate's `didFinishDownloadingTo` moves it. On iOS
    /// we don't need an external-storage detour like Android — we can
    /// write directly to the app's sandbox.
    private func finalDestinationPath(filename: String) -> String {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent(filename).path
    }

    // MARK: - completedSinceLastCheck

    private func handleCompletedSinceLastCheck(result: @escaping FlutterResult) {
        let defaults = UserDefaults.standard
        let completedAt = defaults.integer(forKey: Self.keyCompletedAt)
        if completedAt > 0 {
            defaults.removeObject(forKey: Self.keyCompletedAt)
            result(completedAt)
        } else {
            result(0)
        }
    }
}

/// URLSession delegate that handles the four events we care about:
/// - Progress (didWriteData)
/// - Completion (didFinishDownloadingTo)
/// - Error (didCompleteWithError)
/// - End-of-background-events (urlSessionDidFinishEvents — calls the
///   AppDelegate's stashed completion handler so iOS finishes the
///   background relaunch cleanly).
class ModelDownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, URLSessionDelegate {

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let d = UserDefaults.standard
        d.set(Int(totalBytesWritten), forKey: "land.fx.files.modelDownload.bytesDownloaded")
        d.set(Int(totalBytesExpectedToWrite), forKey: "land.fx.files.modelDownload.totalBytes")
        d.set("running", forKey: "land.fx.files.modelDownload.status")
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // CRITICAL: the temp file at `location` is deleted as soon as
        // this delegate method returns. Move it synchronously to our
        // final destination before any await/dispatch.
        guard let filename = downloadTask.taskDescription else {
            NSLog("ModelDownloadHandler: didFinishDownloadingTo missing taskDescription")
            return
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Make sure the directory exists.
        try? FileManager.default.createDirectory(
            at: support, withIntermediateDirectories: true)
        let target = support.appendingPathComponent(filename)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: location, to: target)
            UserDefaults.standard.set("successful",
                forKey: "land.fx.files.modelDownload.status")
            UserDefaults.standard.set(Int(Date().timeIntervalSince1970 * 1000),
                forKey: "land.fx.files.modelDownload.completedAtMs")
        } catch {
            NSLog("ModelDownloadHandler: move failed: \(error)")
            UserDefaults.standard.set("failed",
                forKey: "land.fx.files.modelDownload.status")
            UserDefaults.standard.set("FILE_MOVE_FAILED: \(error.localizedDescription)",
                forKey: "land.fx.files.modelDownload.reasonText")
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error = error else { return } // success path handled above
        let d = UserDefaults.standard
        let nsError = error as NSError
        let isCancel = nsError.code == NSURLErrorCancelled
        d.set(isCancel ? "unknown" : "failed",
              forKey: "land.fx.files.modelDownload.status")
        d.set(nsError.localizedDescription,
              forKey: "land.fx.files.modelDownload.reasonText")
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // iOS background relaunch: call the stashed handler so the
        // system finishes its end of the cycle.
        DispatchQueue.main.async {
            ModelDownloadHandler.backgroundSessionCompletionHandler?()
            ModelDownloadHandler.backgroundSessionCompletionHandler = nil
        }
    }
}
