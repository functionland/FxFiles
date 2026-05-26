import UIKit
import UniformTypeIdentifiers
import UserNotifications
import os

/// Custom headless share-extension controller for the FxFiles Shelf
/// feature.
///
/// Hardening (Shelf plan Session 4 / R4–R7, R12, R13):
/// - R12: uses `UniformTypeIdentifiers` (`UTType.image` / `.movie` /
///        `.fileURL` / `.url` / `.plainText`), not the deprecated
///        `kUTType*` constants from `MobileCoreServices`.
/// - R13: prefers `loadFileRepresentation(forTypeIdentifier:)` for
///        non-text attachments — avoids in-memory decode/transcode
///        for large media and stays under the 120 MB extension cap.
/// - R7:  per-share-transaction directory + write-temp-then-rename +
///        `manifest.json` is the **last** thing written (commit
///        marker). Drain only ingests a txn dir that contains a
///        `manifest.json`.
/// - R6:  every file written into the App Group gets
///        `NSFileProtectionCompleteUntilFirstUserAuthentication`
///        applied so the OS keeps it encrypted at rest while the
///        device is locked.
/// - R4:  does NOT call `BGTaskScheduler.submit`. The main app
///        registers + submits the drain task on launch.
/// - R5:  does NOT request notification authorization. The main app
///        owns that flow. If the user hasn't authorized, the
///        `UNUserNotificationCenter.add` below fails silently — the
///        share still works (the next time FxFiles foregrounds the
///        drain ingests the staged payload).
@objc(ShareViewController)
class ShareViewController: UIViewController {

    static let appGroupIdentifier = "group.land.fx.files"
    static let pendingDirName = "dump_pending"
    static let manifestName = "manifest.json"
    private static let logger = Logger(
        subsystem: "land.fx.files.ShelfShare",
        category: "ShareViewController"
    )

    // Re-entry guard (Session 6 / advisor R-S6-A1): the OS can call
    // viewDidAppear more than once during the extension's lifecycle
    // (e.g. animation re-entry, OS-driven resize). Without this flag,
    // each redundant call would spin up a fresh `processShare()` Task,
    // creating duplicate transaction directories + uploads from the
    // same user gesture.
    private var didKickOffProcessing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // Headless — never show a sheet, never block the share gesture.
        view.backgroundColor = .clear
        view.isHidden = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Kick off after the view tree is mounted so `extensionContext`
        // is guaranteed non-nil. `Task { ... }` detaches from the
        // controller's lifecycle so `completeRequest` still runs even
        // if the OS tears down the view mid-flight. Guarded so a
        // re-entrant viewDidAppear doesn't double-process the share.
        if didKickOffProcessing { return }
        didKickOffProcessing = true
        Task { [weak self] in
            await self?.processShare()
        }
    }

    private func processShare() async {
        guard let context = extensionContext else {
            await complete()
            return
        }

        let txnId = UUID().uuidString
        do {
            let txnDir = try ensureTxnDirectory(txnId: txnId)
            let items = await collectInputItems(from: context, into: txnDir)

            if items.isEmpty {
                // No supported attachments — clean up the empty dir.
                try? FileManager.default.removeItem(at: txnDir)
                await complete()
                return
            }

            // R7 — manifest.json is the commit marker, written via
            // atomic temp+rename AFTER all payloads have landed.
            try writeManifest(
                txnId: txnId,
                items: items,
                in: txnDir
            )

            await postQueuedNotification(count: items.count, txnId: txnId)
        } catch {
            Self.logger.error("processShare failed: \(String(describing: error), privacy: .public)")
        }

        await complete()
    }

    // MARK: - Filesystem layout

    private func ensureTxnDirectory(txnId: String) throws -> URL {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            throw NSError(
                domain: "land.fx.files.ShelfShare",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "App Group container not available — entitlement misconfigured?",
                ]
            )
        }
        let pendingDir = groupURL.appendingPathComponent(Self.pendingDirName, isDirectory: true)
        let txnDir = pendingDir.appendingPathComponent(txnId, isDirectory: true)
        try FileManager.default.createDirectory(
            at: txnDir,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        return txnDir
    }

    // MARK: - Input collection

    /// Iterates every attachment on every input item and stages each
    /// supported one into `txnDir`. Returns the list of manifest items
    /// (paths + originalNames + mimes + optional text payload).
    private func collectInputItems(
        from context: NSExtensionContext,
        into txnDir: URL
    ) async -> [[String: Any]] {
        var items: [[String: Any]] = []
        for raw in context.inputItems {
            guard let inputItem = raw as? NSExtensionItem else { continue }
            for provider in inputItem.attachments ?? [] {
                if let staged = await stageProvider(provider, in: txnDir) {
                    items.append(staged)
                }
            }
        }
        return items
    }

    /// R13 — try file-representation first (avoids in-memory decode).
    /// Falls back to URL or text for link / plain text shares.
    private func stageProvider(
        _ provider: NSItemProvider,
        in txnDir: URL
    ) async -> [String: Any]? {
        let fileLikeTypes: [UTType] = [
            .image, .movie, .audio, .pdf, .fileURL, .data,
        ]
        for type in fileLikeTypes {
            if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                if let staged = await stageFileLike(
                    provider, typeIdentifier: type.identifier, in: txnDir
                ) {
                    return staged
                }
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return await stageURL(provider, in: txnDir)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return await stageText(provider, in: txnDir)
        }
        return nil
    }

    private func stageFileLike(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        in txnDir: URL
    ) async -> [String: Any]? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any]?, Never>) in
            // `loadFileRepresentation` calls the completion with a temp
            // URL that's valid ONLY for the duration of the completion
            // — we must copy synchronously before returning.
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error = error {
                    Self.logger.error("loadFileRepresentation failed: \(String(describing: error), privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                guard let url = url else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    let originalName = url.lastPathComponent
                    let safeName = self.sanitize(originalName)
                    let localFile = "\(UUID().uuidString)-\(safeName)"
                    let dest = txnDir.appendingPathComponent(localFile)
                    let tmp = dest.appendingPathExtension("tmp")
                    try FileManager.default.copyItem(at: url, to: tmp)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    self.applyProtection(to: dest)
                    let mime = UTType(typeIdentifier)?.preferredMIMEType
                    // Codex review (Session 6): `mime as Any` boxes
                    // `Optional.none` into an `Any` slot, which
                    // `JSONSerialization` rejects. Use `NSNull()`
                    // explicitly when the UTType has no preferred
                    // MIME so the manifest serializes cleanly.
                    continuation.resume(returning: [
                        "localFile": localFile,
                        "originalName": originalName,
                        "mimeType": (mime as Any?) ?? NSNull(),
                    ])
                } catch {
                    Self.logger.error("file stage failed: \(String(describing: error), privacy: .public)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func stageURL(
        _ provider: NSItemProvider,
        in txnDir: URL
    ) async -> [String: Any]? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any]?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { value, _ in
                let urlString: String?
                if let url = value as? URL {
                    urlString = url.absoluteString
                } else if let data = value as? Data,
                          let s = String(data: data, encoding: .utf8) {
                    urlString = s
                } else if let s = value as? String {
                    urlString = s
                } else {
                    urlString = nil
                }
                guard let text = urlString, !text.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: self.stageTextPayload(text, in: txnDir, mime: "text/plain", originalName: "Shared link"))
            }
        }
    }

    private func stageText(
        _ provider: NSItemProvider,
        in txnDir: URL
    ) async -> [String: Any]? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any]?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { value, _ in
                let text: String?
                if let s = value as? String {
                    text = s
                } else if let data = value as? Data,
                          let s = String(data: data, encoding: .utf8) {
                    text = s
                } else {
                    text = nil
                }
                guard let s = text, !s.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: self.stageTextPayload(s, in: txnDir, mime: "text/plain", originalName: "Shared text"))
            }
        }
    }

    /// Writes a UTF-8 text payload to a `.txt` file with atomic
    /// temp+rename. Returns the manifest entry. The original payload
    /// is ALSO recorded as `textPayload` so the Dart side can route
    /// it as a Link (URL detection) or Note without re-reading the
    /// file.
    private func stageTextPayload(
        _ text: String,
        in txnDir: URL,
        mime: String,
        originalName: String
    ) -> [String: Any]? {
        let localFile = "\(UUID().uuidString)-note.txt"
        let dest = txnDir.appendingPathComponent(localFile)
        let tmp = dest.appendingPathExtension("tmp")
        do {
            guard let data = text.data(using: .utf8) else { return nil }
            try data.write(to: tmp, options: .atomic)
            try FileManager.default.moveItem(at: tmp, to: dest)
            applyProtection(to: dest)
            return [
                "localFile": localFile,
                "originalName": originalName,
                "mimeType": mime,
                "textPayload": text,
            ]
        } catch {
            Self.logger.error("text stage failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Manifest

    private func writeManifest(
        txnId: String,
        items: [[String: Any]],
        in txnDir: URL
    ) throws {
        let descriptor: [String: Any] = [
            "v": 1,
            "txnId": txnId,
            "createdAtMs": Int(Date().timeIntervalSince1970 * 1000),
            // Use the same field name Android writes (Session 2's
            // DumpShareActivity.kt → "sourcePackage") so the
            // Dart-side `_drainOneDescriptor` reads one schema for
            // both platforms.
            "sourcePackage": "ios-share",
            "items": items,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: descriptor,
            options: [.sortedKeys]
        )
        let manifestURL = txnDir.appendingPathComponent(Self.manifestName)
        let tmpURL = manifestURL.appendingPathExtension("tmp")
        try data.write(to: tmpURL, options: .atomic)
        try FileManager.default.moveItem(at: tmpURL, to: manifestURL)
        applyProtection(to: manifestURL)
    }

    // MARK: - Notification (stage 1 of 2 — "queued")

    private func postQueuedNotification(count: Int, txnId: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Shelf"
        content.body = count == 1
            ? "Queued 1 item — will upload when FxFiles next runs"
            : "Queued \(count) items — will upload when FxFiles next runs"
        // Per R15 / plan Phase 8 — keep lock-screen content masked.
        if #available(iOS 12.0, *) {
            content.threadIdentifier = "dump.queued"
        }
        // Distinct identifier so multiple queued posts don't collapse
        // when the user shares several batches quickly. The main app
        // dismisses these (via removeDeliveredNotifications) once the
        // uploaded notification fires.
        let request = UNNotificationRequest(
            identifier: "dump.queued.\(txnId)",
            content: content,
            trigger: nil
        )
        // R5 — extension does NOT request authorization; if not
        // granted this fails silently and the share still works.
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Self.logger.error("postQueuedNotification failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Helpers

    private func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\r\n\t")
        let scrubbed = name.components(separatedBy: illegal).joined(separator: "_")
        return scrubbed.isEmpty ? "file" : scrubbed
    }

    private func applyProtection(to url: URL) {
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            Self.logger.error("applyProtection failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func complete() async {
        await MainActor.run {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
