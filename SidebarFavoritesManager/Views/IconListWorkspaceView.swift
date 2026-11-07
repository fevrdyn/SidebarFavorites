import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// What differs between the Apps and the Folders list.
struct IconListConfig {
    let kind: StudioIconItem.Kind
    let title: String
    let emptySymbol: String
    let emptyTitle: String
    let emptyMessage: String
    let addHelp: String
    let exportHelp: String
    let revealHelp: String
}

/// The list screen shared by Apps and Folders. It looks like the Sidebar list,
/// minus the "In Sidebar" text: a green dot means the item exists, an orange dot
/// means it points at nothing.
struct IconListWorkspaceView: View {
    let config: IconListConfig

    @ObservedObject private var store = StudioIconStore.shared
    @State private var itemPendingRemoval: StudioIconItem?
    @State private var isDropTargeted = false

    private var items: [StudioIconItem] {
        store.items(of: config.kind)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if items.isEmpty {
                emptyState
            } else {
                list
            }

            Divider()
            footer
        }
        // Folders can be dropped onto the list from Finder.
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFolderDrop(providers)
        }
        .overlay {
            if isDropTargeted && config.kind == .folder {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { store.refresh() }
        // Coming back from Finder, a moved or deleted item should turn orange.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
        }
        .alert(item: $itemPendingRemoval) { item in
            Alert(
                title: Text("Remove \u{201C}\(item.displayName)\u{201D}?"),
                message: Text(item.isCustomIconOn
                    ? "The folder\u{2019}s custom icon is taken off too, so it goes back to the normal one."
                    : "It is only removed from this list. The \(config.kind == .app ? "app" : "folder") itself is not touched."),
                primaryButton: .destructive(Text("Remove")) { removeItem(item) },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Text(config.title)
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            Button(action: addItem) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .help(config.addHelp)
        }
        .padding(.horizontal)
        .frame(height: StudioMetrics.headerHeight)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    IconListRow(
                        item: item,
                        refreshToken: store.refreshToken,
                        exportHelp: config.exportHelp,
                        revealHelp: config.revealHelp,
                        onExport: { IconExporter.export(item) },
                        onReveal: { NSWorkspace.shared.activateFileViewerSelecting([item.url]) },
                        canEdit: true,
                        onEdit: {
                            if config.kind == .app {
                                StudioNavigator.shared.appEditorItemID = item.id
                            } else {
                                StudioNavigator.shared.folderEditorItemID = item.id
                            }
                        },
                        onDelete: { itemPendingRemoval = item },
                        showsToggle: config.kind == .folder,
                        onToggle: { isOn in
                            Task {
                                await FolderIconApplier.setEnabled(isOn, for: item, store: store)
                            }
                        }
                    )
                    Divider()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: config.emptySymbol)
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(config.emptyTitle)
                .font(.headline)
            Text(config.emptyMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button(config.kind == .app ? "Add App" : "Add Folder", action: addItem)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(AppVersion.display)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Button(action: { store.refresh() }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Check again which items still exist")
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Actions

    private func removeItem(_ item: StudioIconItem) {
        Task {
            if item.kind == .folder, item.isCustomIconOn {
                await FolderIconApplier.restoreOnRemoval(item)
            }
            await MainActor.run {
                store.remove(item)
            }
        }
    }

    /// Collects the dropped files from the background threads that deliver them.
    private final class DroppedURLs {
        private let lock = NSLock()
        private var urls: [URL] = []
        func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    private func handleFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        guard config.kind == .folder else { return false }
        let found = DroppedURLs()
        let group = DispatchGroup()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { dropped, _ in
                if let data = dropped as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    found.add(url)
                } else if let url = dropped as? URL {
                    found.add(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { addDropped(found.all) }
        return true
    }

    /// Adds the dropped folders. Files, and app bundles (which are folders to the system but
    /// belong in the Apps tab), are refused with a message.
    private func addDropped(_ urls: [URL]) {
        var refused: [String] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true, values?.isPackage != true {
                store.add(kind: .folder, url: url)
            } else {
                refused.append(url.lastPathComponent)
            }
        }
        guard !refused.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = refused.count == 1
            ? "\u{201C}\(refused[0])\u{201D} is not a folder"
            : "\(refused.count) of the dropped items are not folders"
        let names = refused.prefix(5).joined(separator: ", ")
        alert.informativeText = "Only folders can be added here. Apps go in the Apps tab.\n\nNot added: \(names)\(refused.count > 5 ? ", ..." : "")"
        alert.runModal()
    }

    private func addItem() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        switch config.kind {
        case .app:
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.message = "Choose the apps whose icons you want to manage"
        case .folder:
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.message = "Choose the folders whose icons you want to manage"
        }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            store.add(kind: config.kind, url: url)
        }
    }
}

/// One row, built like the Sidebar's `FavoriteRow`: icon, name and path on the
/// left; on the right a status dot that is swapped for the action buttons while
/// the mouse is over the row.
struct IconListRow: View {
    let item: StudioIconItem
    let refreshToken: Int
    let exportHelp: String
    let revealHelp: String
    let onExport: () -> Void
    let onReveal: () -> Void
    let canEdit: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let showsToggle: Bool
    let onToggle: (Bool) -> Void

    @State private var isHovering = false
    /// The icon as macOS really draws it, tinted folders included.
    @State private var renderedIcon: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            // Icon: the real one, as macOS currently draws it.
            iconView
                .frame(width: 40, height: 40)
                .task(id: "\(item.path)#\(item.folderColorHex ?? "")#\(refreshToken)") {
                    guard item.isLinked else {
                        renderedIcon = nil
                        return
                    }
                    // A folder with a design always shows the design. Switched off, Finder's own
                    // icon would hide it, and the design is still what this row is about.
                    if item.kind == .folder, item.hasCustomIcon {
                        if let image = await FolderIconApplier.composite(
                            tintHex: item.folderColorHex, artworks: item.artwork ?? [], pixels: 256
                        ) {
                            renderedIcon = image
                        }
                        return
                    }
                    if let image = await IconExporter.icon(for: item.url, pixels: 128) {
                        renderedIcon = image
                    }
                }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.headline)
                    .lineLimit(1)

                Text(item.displayPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // The status and the hover actions share one slot, swapped by
            // opacity, so nothing to their left shifts when the pointer enters.
            ZStack(alignment: .trailing) {
                statusIndicator
                    .opacity(isHovering ? 0 : 1)

                HStack(spacing: 8) {
                    Button(action: onExport) {
                        Image(systemName: "square.and.arrow.down")
                            .offset(y: -2)   // downloadIconNudge: this glyph sits a point low; change the -1 to adjust
                    }
                    .buttonStyle(.borderless)
                    .disabled(!item.isLinked)
                    .help(exportHelp)

                    Button(action: onReveal) {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!item.isLinked)
                    .help(revealHelp)

                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canEdit)
                    .help(canEdit ? "Edit icon" : "Editing this kind of icon comes later")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                    .help("Remove from this list")
                }
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .accessibilityHidden(!isHovering)
            }

            // On: the designed icon is on the folder. Off: Finder's own icon, a
            // tag colour included. The designed icon is kept either way.
            if showsToggle {
                Toggle("", isOn: Binding(
                    get: { item.isCustomIconOn },
                    set: { onToggle($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!item.hasCustomIcon || !item.isLinked)
                .help(item.hasCustomIcon
                      ? "Custom icon on or off. Off shows Finder\u{2019}s own icon; your design is kept."
                      : "Design an icon first (the pencil), then switch it on here")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(isHovering ? Color(NSColor.selectedContentBackgroundColor).opacity(0.3) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private var statusIndicator: some View {
        Circle()
            .fill(item.isLinked ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
            .help(item.isLinked ? "Linked" : "Not found - nothing at this path any more")
    }

    @ViewBuilder
    private var iconView: some View {
        // `NSWorkspace` answers instantly but draws a tinted folder plain blue, so it
        // only stands in until the QuickLook rendering above arrives.
        if item.isLinked, let image = renderedIcon ?? item.currentIcon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: item.kind == .app ? "questionmark.app.dashed" : "questionmark.folder")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
        }
    }
}
