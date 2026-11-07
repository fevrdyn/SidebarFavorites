import Foundation
import AppKit

/// One app or folder the studio keeps an icon for.
struct StudioIconItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case app
        case folder
    }

    var id: UUID = UUID()
    var kind: Kind
    /// Absolute path of the app bundle or folder.
    var path: String
    var addedAt: Date = Date()
    /// Folders only: the colour chosen in the folder editor, as "#RRGGBB".
    /// `nil` means the system folder as it is.
    var folderColorHex: String?
    /// Folders only: whether the designed icon is currently on the folder in
    /// Finder. `nil` (also how items saved before this existed read) means off.
    /// Optional on purpose: a plain Bool would make every older saved list fail to load.
    var customIconApplied: Bool?
    /// Folders only: symbols, emoji and pictures placed on the front panel.
    /// Optional for the same reason: older saved lists have no such key.
    var artwork: [FolderArtwork]?
    /// Apps only: the colours of the icon body. Optional for the same reason; nil is the dark grey.
    var appLook: AppIconLook?

    var url: URL { URL(fileURLWithPath: path) }

    var displayName: String {
        let name = url.lastPathComponent
        return kind == .app && name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// `~/Documents/...` rather than `/Users/you/Documents/...`.
    var displayPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Folders only: there is a designed icon to switch on.
    var hasCustomIcon: Bool { folderColorHex != nil || !(artwork ?? []).isEmpty }

    /// Folders only: the designed icon is on the folder right now.
    var isCustomIconOn: Bool { customIconApplied ?? false }

    /// Apps only: an icon has been designed (colour or artwork).
    var hasAppDesign: Bool { kind == .app && (appLook != nil || !(artwork ?? []).isEmpty) }

    /// Green dot when true. False means the item no longer points at anything.
    var isLinked: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// The icon macOS currently shows for this item.
    var currentIcon: NSImage? {
        guard isLinked else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }
}

/// The apps and folders the studio manages, saved on their own so this never
/// touches the Sidebar Favorites config.
final class StudioIconStore: ObservableObject {
    static let shared = StudioIconStore()

    @Published private(set) var items: [StudioIconItem] = []
    /// Bumped by `refresh()`, so rows reload their icons and status dots.
    @Published private(set) var refreshToken = 0

    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("ThemingStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("icon-items.json")
        load()
    }

    func items(of kind: StudioIconItem.Kind) -> [StudioIconItem] {
        items.filter { $0.kind == kind }
    }

    /// Returns false when this path is already in the list.
    @discardableResult
    func add(kind: StudioIconItem.Kind, url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard !items.contains(where: { $0.kind == kind && $0.path == path }) else { return false }
        items.append(StudioIconItem(kind: kind, path: path))
        save()
        return true
    }

    func update(_ item: StudioIconItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        save()
    }

    func remove(_ item: StudioIconItem) {
        items.removeAll { $0.id == item.id }
        AppIconCache.remove(for: item)
        save()
    }

    /// Re-reads icons and green/yellow status from disk.
    func refresh() {
        refreshToken += 1
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([StudioIconItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
