import Foundation

/// Where the Studio keeps its data, how big it is, and the care of the sidebar
/// icon files (ThemingStudio/SidebarIcons).
///
/// The original Sidebar Favorites app keeps its custom SVGs in
/// .../SidebarFavorites/Icons. That folder is only ever READ here, never changed:
/// the original app may still use it.
enum StudioStorage {
    /// ~/Library/Application Support/ThemingStudio
    static var folder: URL {
        var support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if DEBUG
        // Screenshot mode runs on a sandbox directory, never the real one.
        if let sandbox = ProcessInfo.processInfo.environment["SBF_SUPPORT_DIR"], !sandbox.isEmpty {
            support = URL(fileURLWithPath: sandbox, isDirectory: true)
        }
        #endif
        return support.appendingPathComponent("ThemingStudio", isDirectory: true)
    }

    /// Where this app keeps the sidebar favorites' custom SVGs.
    static var sidebarIconsFolder: URL {
        folder.appendingPathComponent("SidebarIcons", isDirectory: true)
    }

    /// `~/Library/...` rather than `/Users/you/Library/...`.
    static var displayPath: String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Size

    /// Total size in bytes of everything inside the Studio folder.
    static func folderSize() -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Sidebar icon files

    /// Runs once at launch, BEFORE anything reads the icons.
    ///
    /// 1. Copies every icon a favorite uses from the original app's folder into
    ///    SidebarIcons, if it is not there yet. Nothing is moved or deleted in
    ///    the original folder.
    /// 2. Deletes SVGs in SidebarIcons that no favorite uses any more.
    ///
    /// Safety: step 2 is skipped when the config could not be read or has no
    /// favorites; the spacer artwork is always kept; only .svg files are touched;
    /// files changed in the last hour are left alone (an icon picked in a sheet
    /// that is not saved yet).
    static func syncSidebarIcons() {
        let manager = ConfigManager.shared
        let fm = FileManager.default
        let target = manager.iconsDirectoryURL            // creates SidebarIcons
        let legacy = manager.legacyIconsDirectoryURL
        let favorites = manager.config.favorites

        var used = Set<String>()
        for favorite in favorites {
            if let path = favorite.customSVGPath, !path.isEmpty {
                used.insert((path as NSString).lastPathComponent)
            }
        }

        // 1. Copy what is used and missing.
        for name in used {
            let destination = target.appendingPathComponent(name)
            let source = legacy.appendingPathComponent(name)
            if !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: source.path) {
                try? fm.copyItem(at: source, to: destination)
            }
        }

        // 2. Delete what nothing uses.
        guard manager.loadDiagnostic == nil, !favorites.isEmpty else { return }
        used.insert(SpacerStore.artworkFileName)
        guard let files = try? fm.contentsOfDirectory(
            at: target,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let recent = Date().addingTimeInterval(-3600)
        for file in files where file.pathExtension.lowercased() == "svg" {
            if used.contains(file.lastPathComponent) { continue }
            let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let changed, changed > recent { continue }
            try? fm.removeItem(at: file)
        }
    }
}
