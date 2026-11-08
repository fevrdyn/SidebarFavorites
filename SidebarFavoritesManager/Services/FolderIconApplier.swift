import AppKit
import CryptoKit
import SwiftUI

/// Puts a folder's designed icon on the folder in Finder, and takes it off again.
///
/// It is a plain custom icon: macOS stores it with the folder and keeps showing
/// it with this app closed, so nothing runs in the background. Turning it off
/// removes the custom icon, and the folder goes back to what Finder shows by
/// itself - a tag colour included. The designed icon stays in a small cache, so
/// turning it back on is instant.
enum FolderIconApplier {
    struct ApplyError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - What the list row's switch does

    /// On: puts the designed icon on the folder. Off: takes it off.
    static func setEnabled(_ enabled: Bool, for item: StudioIconItem, store: StudioIconStore) async {
        log("SWITCH \(enabled ? "on" : "off")  \(item.path)")
        var updated = item
        do {
            if enabled {
                let image = try await iconToApply(for: item)
                try await putOn(image, atPath: item.path)
            } else {
                try await setIcon(nil, atPath: item.path)
            }
            updated.customIconApplied = enabled
            await MainActor.run {
                store.update(updated)
            }
        } catch {
            await showError(enabled ? "Couldn\u{2019}t apply the icon" : "Couldn\u{2019}t restore the folder",
                            error.localizedDescription)
        }
        await MainActor.run {
            store.refresh()
        }
    }

    // MARK: - What Save does

    /// After the editor stored an item: draws the icon afresh and puts it on the
    /// folder - or, if the colour was cleared, takes the custom icon off.
    static func saved(_ item: StudioIconItem, previousPath: String, wasOn: Bool, store: StudioIconStore) async {
        log("SAVE  \(item.path)  (was on: \(wasOn), colour: \(item.folderColorHex ?? "none"))")
        var updated = item
        do {
            // The editor pointed this item at another folder: free the old one.
            if wasOn, previousPath != item.path {
                try? await setIcon(nil, atPath: previousPath)
            }

            if item.hasCustomIcon {
                let image = try await design(item)
                try await putOn(image, atPath: item.path)
                updated.customIconApplied = true
            } else {
                if wasOn {
                    try await setIcon(nil, atPath: item.path)
                }
                clearCache(for: item.id)
                updated.customIconApplied = false
            }
            await MainActor.run {
                store.update(updated)
            }
        } catch {
            // The settings are saved; only putting the icon on the folder failed.
            updated.customIconApplied = false
            await MainActor.run {
                store.update(updated)
            }
            await showError("Couldn\u{2019}t apply the icon", error.localizedDescription)
        }
        await MainActor.run {
            store.refresh()
        }
    }

    /// When an item is removed from the list: the folder gets its own icon back.
    static func restoreOnRemoval(_ item: StudioIconItem) async {
        log("REMOVE from list  \(item.path)")
        try? await setIcon(nil, atPath: item.path)
        clearCache(for: item.id)
    }

    // MARK: - Drawing and the cache

    /// Draws the icon from the item's saved settings and keeps it in the cache.
    private static func design(_ item: StudioIconItem) async throws -> NSImage {
        guard item.hasCustomIcon else {
            throw ApplyError(message: "This folder has no custom icon yet.")
        }
        guard let image = await composite(tintHex: item.folderColorHex, artworks: item.artwork ?? [], pixels: 1024) else {
            throw ApplyError(message: "The icon could not be drawn.")
        }
        clearCache(for: item.id)
        if let data = pngData(image) {
            try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
            try? data.write(to: cacheURL(for: item), options: .atomic)
        }
        return image
    }

    /// The system folder in `tintHex` (or as it is) with `artworks` drawn on the
    /// front panel, `pixels` x `pixels`. Used for the icon itself and for the
    /// pictures in the lists.
    static func composite(tintHex: String?, artworks: [FolderArtwork], pixels: Int) async -> NSImage? {
        let tint = tintHex.flatMap { FolderRecolor.Tint(hex: $0) }
        guard let base = await FolderRecolor.render(pixels: pixels, tint: tint) else { return nil }
        if artworks.isEmpty { return base }
        return await MainActor.run {
            let renderer = ImageRenderer(content: FolderCompositeView(base: base, artworks: artworks, side: CGFloat(pixels)))
            renderer.scale = 1
            return renderer.nsImage
        }
    }

    /// The cached picture if there is one for these settings, otherwise a fresh drawing.
    private static func iconToApply(for item: StudioIconItem) async throws -> NSImage {
        if let cached = NSImage(contentsOf: cacheURL(for: item)) {
            return cached
        }
        return try await design(item)
    }

    private static var cacheFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ThemingStudio/Rendered", isDirectory: true)
    }

    /// One file per folder, colour and arrangement of artwork, so a changed design
    /// never reuses an old picture.
    private static func cacheURL(for item: StudioIconItem) -> URL {
        let colour = (item.folderColorHex ?? "none").replacingOccurrences(of: "#", with: "")
        let artwork = (item.artwork ?? [])
            .map { "\($0.kind.rawValue)|\($0.value)|\($0.x)|\($0.y)|\($0.size)|\($0.angle)|\($0.colorHex ?? "")|\($0.fontStyle ?? "")|\($0.hasShadow)" }
            .joined(separator: ";")
        let digest = SHA256.hash(data: Data(("clip1;" + artwork).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return cacheFolder.appendingPathComponent("\(item.id.uuidString)-\(colour)-\(digest).png")
    }

    private static func clearCache(for id: UUID) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheFolder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(id.uuidString) {
            try? fm.removeItem(at: file)
        }
    }

    private static func pngData(_ image: NSImage) -> Data? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    // MARK: - macOS

    /// Puts the icon on the folder. Replacing a custom icon in place can leave
    /// Finder drawing the old one until the folder changes again, so a folder that
    /// already has one is cleared first.
    private static func putOn(_ image: NSImage, atPath path: String) async throws {
        if hasCustomIconFile(atPath: path) {
            log("  (clearing the old icon first so Finder redraws)")
            try? await setIcon(nil, atPath: path)
            // Give Finder a moment to show the plain folder first, like the switch does.
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        try await setIcon(image, atPath: path)
    }

    /// Finder keeps a folder's custom icon in a hidden file called "Icon" followed
    /// by a carriage return.
    private static func hasCustomIconFile(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("Icon\r"))
    }

    /// Finder redraws a folder's icon when it sees the folder change, and changing
    /// the icon does not always count. Setting the modification date to the value
    /// it already has makes Finder look again without changing anything the user
    /// can see.
    private static func nudgeFinder(atPath path: String) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return }
        try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        log("  -> nudged Finder to redraw  \(path)")
    }

    /// macOS icons are at most 512 pt, drawn from a 1024 px picture at 2x scale.
    /// A 1024 pt image is out of range and fills the console with "Invalid image
    /// size", so the same 1024 px picture is declared as 512 pt.
    private static func iconSized(_ image: NSImage) -> NSImage {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return image }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: 512, height: 512)
        let result = NSImage(size: NSSize(width: 512, height: 512))
        result.addRepresentation(rep)
        return result
    }

    /// A custom icon on the folder, or - with `nil` - none, so Finder shows its default again.
    private static func setIcon(_ image: NSImage?, atPath path: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ApplyError(message: "The folder can\u{2019}t be found any more.")
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
        }
        guard succeeded else {
            throw ApplyError(message: image == nil
                ? "macOS would not take the custom icon off this folder."
                : "macOS would not let the icon be set on this folder. It may be protected, or this app may not have permission to change it.")
        }
    }

    /// A plain text record of every change this app makes to a folder's icon, in
    /// ~/Library/Application Support/ThemingStudio/apply.log - so if an icon ever
    /// changes that should not have, the exact path and the reason are written down.
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

    private static func showError(_ title: String, _ message: String) async {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
