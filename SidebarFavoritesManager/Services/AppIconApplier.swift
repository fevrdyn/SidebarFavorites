import AppKit
import SwiftUI

/// Puts an app's designed icon on the app itself, and takes it off again.
///
/// Like the folder icons this is a plain custom icon that macOS stores with the
/// app, so nothing has to keep running. Switching off removes the custom icon and
/// the app shows its own icon again. Before the first change to an app its
/// original icon is copied to OriginalIcons (AppIconCache); if that copy cannot
/// be made, nothing is changed.
///
/// Only items in the Apps list are ever touched.
enum AppIconApplier {
    struct ApplyError: LocalizedError {
        let message: String
        /// The likely cause is a missing permission, so the alert points at System Settings.
        var needsPermission = false
        var errorDescription: String? { message }
    }

    // MARK: - What the list row's switch does

    /// On: puts the designed icon on the app. Off: takes it off.
    static func setEnabled(_ enabled: Bool, for item: StudioIconItem, store: StudioIconStore) async {
        log("APP SWITCH \(enabled ? "on" : "off")  \(item.path)")
        guard await isListItem(item, store: store) else {
            log("  -> REFUSED: not an item in the Apps list")
            return
        }
        var updated = item
        do {
            if enabled {
                let image = try await iconToApply(for: item)
                try await putOn(image, atPath: item.path)
            } else {
                try await setIcon(nil, atPath: item.path)
            }
            updated.customIconApplied = enabled
            let result = updated
            await MainActor.run { store.update(result) }
        } catch {
            await report(error, enabled: enabled)
        }
        await MainActor.run { store.refresh() }
    }

    // MARK: - What Save does

    /// After the editor stored a changed design for an app whose icon is switched on:
    /// draws the new design and puts it on the app (or takes the icon off if the
    /// design was cleared).
    static func saved(_ item: StudioIconItem, store: StudioIconStore) async {
        log("APP SAVE  \(item.path)  (design changed while on)")
        guard await isListItem(item, store: store) else {
            log("  -> REFUSED: not an item in the Apps list")
            return
        }
        var updated = item
        do {
            if item.hasAppDesign {
                let image = try await iconToApply(for: item)
                try await putOn(image, atPath: item.path)
                updated.customIconApplied = true
            } else {
                try await setIcon(nil, atPath: item.path)
                updated.customIconApplied = false
            }
            let result = updated
            await MainActor.run { store.update(result) }
        } catch {
            await report(error, enabled: true)
        }
        await MainActor.run { store.refresh() }
    }

    /// When an app is removed from the list: it gets its own icon back.
    static func restoreOnRemoval(_ item: StudioIconItem) async {
        log("APP REMOVE from list  \(item.path)")
        try? await setIcon(nil, atPath: item.path)
        try? FileManager.default.removeItem(at: renderedURL(for: item))
    }

    // MARK: - Drawing

    private static func iconToApply(for item: StudioIconItem) async throws -> NSImage {
        guard item.kind == .app, item.hasAppDesign else {
            throw ApplyError(message: "This app has no designed icon yet. Use the pencil to design one.")
        }
        guard FileManager.default.fileExists(atPath: item.path) else {
            throw ApplyError(message: "The app can\u{2019}t be found any more.")
        }
        // The original is saved before anything on the app is changed.
        let original = await AppIconCache.ensureOriginal(for: item)
        guard original != nil else {
            throw ApplyError(message: "The app\u{2019}s own icon could not be saved first, so nothing was changed.")
        }
        guard let image = await AppIconRenderer.render(item, pixels: 1024) else {
            throw ApplyError(message: "The icon could not be drawn.")
        }
        if let data = pngData(image) {
            try? FileManager.default.createDirectory(at: renderedFolder, withIntermediateDirectories: true)
            try? data.write(to: renderedURL(for: item), options: .atomic)
        }
        return image
    }

    private static var renderedFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ThemingStudio/Rendered", isDirectory: true)
    }

    private static func renderedURL(for item: StudioIconItem) -> URL {
        renderedFolder.appendingPathComponent("\(item.id.uuidString)-app.png")
    }

    private static func pngData(_ image: NSImage) -> Data? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    // MARK: - macOS

    private static func isListItem(_ item: StudioIconItem, store: StudioIconStore) async -> Bool {
        await MainActor.run {
            store.items.contains { $0.id == item.id && $0.kind == .app && $0.path == item.path }
        }
    }

    /// An app that already carries a custom icon is cleared first, so Finder redraws.
    private static func putOn(_ image: NSImage, atPath path: String) async throws {
        if hasCustomIconFile(atPath: path) {
            log("  (clearing the old icon first so Finder redraws)")
            try? await setIcon(nil, atPath: path)
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        try await setIcon(image, atPath: path)
    }

    private static func hasCustomIconFile(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("Icon\r"))
    }

    /// Same trick as for folders: setting the modification date to the value it
    /// already has makes Finder look again.
    private static func nudgeFinder(atPath path: String) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return }
        try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        log("  -> nudged Finder to redraw  \(path)")
    }

    /// 1024 px picture declared as 512 pt, as for folders.
    private static func iconSized(_ image: NSImage) -> NSImage {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return image }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: 512, height: 512)
        let result = NSImage(size: NSSize(width: 512, height: 512))
        result.addRepresentation(rep)
        return result
    }

    /// A custom icon on the app, or - with `nil` - none, so the app shows its own again.
    private static func setIcon(_ image: NSImage?, atPath path: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ApplyError(message: "The app can\u{2019}t be found any more.")
        }
        log("  -> \(image == nil ? "take custom icon OFF" : "put custom icon ON")  \(path)")
        let prepared = image.map { iconSized($0) }
        let succeeded = await MainActor.run {
            NSWorkspace.shared.setIcon(prepared, forFile: path, options: [])
        }
        log("  -> macOS said: \(succeeded ? "ok" : "REFUSED")")
        if succeeded {
            nudgeFinder(atPath: path)
            await MainActor.run { NSWorkspace.shared.noteFileSystemChanged(path) }
            return
        }

        let name = ProcessInfo.processInfo.processName
        var text = "macOS refused to change this app. Apps in /Applications are protected, and macOS asks for permission first:\n\n"
        text += "1. Open System Settings \u{2192} Privacy & Security \u{2192} App Management.\n"
        text += "2. Switch on \u{201C}\(name)\u{201D}. If it is not in the list, press + and add it.\n"
        text += "3. macOS may ask you to quit and reopen \(name). Then flip the switch again."
        if !FileManager.default.isWritableFile(atPath: path) {
            text += "\n\nThis app also belongs to another user (or came from the App Store), so even with permission it may not be changeable."
        }
        if image == nil {
            text += "\n\nYour original icon for this app is kept in ~/Library/Application Support/ThemingStudio/OriginalIcons."
        }
        throw ApplyError(message: text, needsPermission: true)
    }

    // MARK: - Messages and the log

    private static func report(_ error: Error, enabled: Bool) async {
        let needsPermission = (error as? ApplyError)?.needsPermission ?? false
        let title = enabled ? "Couldn\u{2019}t apply the icon" : "Couldn\u{2019}t restore the app\u{2019}s icon"
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if needsPermission {
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")
            }
            let response = alert.runModal()
            if needsPermission, response == .alertFirstButtonReturn {
                openPrivacySettings()
            }
        }
    }

    /// Opens the App Management page; if macOS does not know that page name, the
    /// Privacy & Security page opens instead.
    private static func openPrivacySettings() {
        let addresses = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for address in addresses {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Same plain-text record as for folders: ~/Library/Application Support/ThemingStudio/apply.log
    private static func log(_ line: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("ThemingStudio/apply.log")
        let data = Data("\(ISO8601DateFormatter().string(from: Date()))  \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
