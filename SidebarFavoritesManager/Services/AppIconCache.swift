import Foundation
import AppKit

/// Keeps a copy of each app's original icon, so there is always something to
/// put back when the custom icon is switched off, or the app is updated.
///
/// Copies live in ~/Library/Application Support/ThemingStudio/OriginalIcons,
/// one .icns per list item. An existing copy is never overwritten.
enum AppIconCache {
    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ThemingStudio/OriginalIcons", isDirectory: true)
    }

    static func url(for item: StudioIconItem) -> URL {
        folder.appendingPathComponent(item.id.uuidString + ".icns")
    }

    static func hasOriginal(for item: StudioIconItem) -> Bool {
        FileManager.default.fileExists(atPath: url(for: item).path)
    }

    /// Saves the app's own icon if there is no copy yet. Returns where it is,
    /// or nil if it could not be saved.
    ///
    /// First choice is the .icns inside the app, which is the true original
    /// even if someone has put a custom icon on the app since. Apps that keep
    /// their icon in an asset catalogue have no .icns, so for those the icon
    /// macOS shows right now is exported instead.
    static func ensureOriginal(for item: StudioIconItem) async -> URL? {
        let destination = url(for: item)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { return destination }
        guard item.kind == .app, fm.fileExists(atPath: item.path) else { return nil }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        if let source = bundleIcon(of: item.url),
           (try? fm.copyItem(at: source, to: destination)) != nil {
            return destination
        }
        try? await IconExporter.writeICNS(for: item.url, to: destination)
        return fm.fileExists(atPath: destination.path) ? destination : nil
    }

    static func remove(for item: StudioIconItem) {
        try? FileManager.default.removeItem(at: url(for: item))
    }

    private static func bundleIcon(of app: URL) -> URL? {
        guard let bundle = Bundle(url: app),
              let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              !name.isEmpty else { return nil }
        let file = name.hasSuffix(".icns") ? name : name + ".icns"
        let candidate = app.appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
