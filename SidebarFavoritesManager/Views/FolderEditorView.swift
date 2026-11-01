import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One colour on the palette. Its colour is what the folder's front panel will
/// look like in the mid-tones.
struct FolderSwatch: Identifiable {
    let id: String
    let name: String
    let tint: FolderRecolor.Tint

    var color: Color {
        Color(hue: tint.hue, saturation: tint.saturation, brightness: tint.value)
    }

    /// In the order they appear on the palette: five on the top row, then four
    /// on the bottom row, followed by the custom-colour button.
    static let all: [FolderSwatch] = [
        FolderSwatch(id: "white", name: "White", tint: .init(hue: 0.60, saturation: 0.02, value: 0.97)),
        FolderSwatch(id: "blue", name: "Blue", tint: .init(hue: 0.626, saturation: 0.646, value: 0.883)),
        FolderSwatch(id: "green", name: "Green", tint: .init(hue: 0.38, saturation: 0.72, value: 0.78)),
        FolderSwatch(id: "indigo", name: "Indigo", tint: .init(hue: 0.67, saturation: 0.58, value: 0.85)),
        FolderSwatch(id: "purple", name: "Purple", tint: .init(hue: 0.78, saturation: 0.65, value: 0.87)),
        FolderSwatch(id: "red", name: "Red", tint: .init(hue: 0.997, saturation: 0.78, value: 0.95)),
        FolderSwatch(id: "orange", name: "Orange", tint: .init(hue: 0.09, saturation: 0.80, value: 0.98)),
        FolderSwatch(id: "yellow", name: "Yellow", tint: .init(hue: 0.13, saturation: 0.75, value: 0.99)),
        FolderSwatch(id: "brown", name: "Brown", tint: .init(hue: 0.08, saturation: 0.45, value: 0.64))
    ]
}

/// Every round control on the palette - the swatches, the text button and the
/// symbols button - is this big. Change it here and they all follow.
private let folderPaletteDiameter: CGFloat = 25

/// The "Aa" and symbols buttons beside the palette. Set separately so they can
/// be a little bigger than the colour circles.
private let folderSideButtonDiameter: CGFloat = 29

/// How big the folder is drawn on the canvas. 1.0 fills the space it is given;
/// 1.15 is 15% bigger, 0.85 is 15% smaller. Above about 1.2 it starts to run
/// into the fields at the top.
private let folderCanvasScale: CGFloat = 0.9

private enum FolderColorChoice: Equatable {
    case swatch(String)
    case custom
}

/// Opens the system colour panel and reports every change.
final class ColorPanelBridge: NSObject, ObservableObject {
    var onChange: ((NSColor) -> Void)?

    func show(initial: NSColor) {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.isContinuous = true
        panel.showsAlpha = false
        panel.color = initial
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}

/// The folder icon editor. For now it recolours the system folder; the artwork,
/// drawing tools and applying the icon to the folder come next.
struct FolderEditorView: View {
    let itemID: UUID
    var onClose: () -> Void = {}

    @ObservedObject private var store = StudioIconStore.shared
    @StateObject private var colorPanel = ColorPanelBridge()

    @State private var path = ""
    @State private var choice: FolderColorChoice?
    @State private var customTint = FolderRecolor.Tint(hue: 0.5, saturation: 0.6, value: 0.8)
    @State private var preview: NSImage?
    @State private var showingArtPicker = false
    @State private var didLoad = false

    // The artwork on the folder, and what it looked like at each step, for undo.
    @State private var artworks: [FolderArtwork] = []
    @State private var selectedID: UUID?
    @State private var history: [[FolderArtwork]] = [[]]
    @State private var historyIndex = 0

    // MARK: - Derived values

    private var expandedPath: String {
        (path as NSString).expandingTildeInPath
    }

    private var folderName: String {
        URL(fileURLWithPath: expandedPath).lastPathComponent
    }

    private var isValid: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private var currentTint: FolderRecolor.Tint? {
        switch choice {
        case .none:
            return nil
        case .some(.swatch(let id)):
            return FolderSwatch.all.first { $0.id == id }?.tint
        case .some(.custom):
            return customTint
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                // Named after the folder, like a Finder row. Read-only.
                TextField("", text: .constant(folderName))
                    .textFieldStyle(.roundedBorder)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Folder name")

                HStack(spacing: 8) {
                    TextField("Folder Path", text: $path)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") { browse() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)

            canvas

            controls

            Divider()

            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { load() }
        .onDisappear {
            let panel = NSColorPanel.shared
            panel.setTarget(nil)
            panel.setAction(nil)
            panel.orderOut(nil)
        }
        .task(id: currentTint?.hex ?? "system") {
            let image = await FolderRecolor.render(pixels: 512, tint: currentTint)
            if !Task.isCancelled, let image {
                preview = image
            }
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            let side = max(1, min(geometry.size.width, geometry.size.height))
            ZStack {
                if let preview {
                    FolderArtworkCanvas(
                        base: preview,
                        side: side,
                        artworks: $artworks,
                        selectedID: $selectedID,
                        onCommit: { commitHistory() },
                        onDuplicate: duplicateArtwork,
                        onRecenter: recenterArtwork,
                        onDelete: deleteArtwork
                    )
                    .frame(width: side, height: side)
                    .scaleEffect(folderCanvasScale)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .bottom) { selectionBar }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 4)
    }

    /// Shown under the folder while a piece of artwork is selected.
    @ViewBuilder
    private var selectionBar: some View {
        if let id = selectedID {
            HStack(spacing: 10) {
                barButton("scope", help: "Recenter") { recenterArtwork(id) }
                barButton("plus.square.on.square", help: "Duplicate") { duplicateArtwork(id) }
                barButton("trash", help: "Delete") { deleteArtwork(id) }
                barButton("checkmark", help: "Confirm position") { selectedID = nil }
            }
            .padding(.bottom, 2)
        }
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Tools, palette and the art button

    private var controls: some View {
        HStack(alignment: .center, spacing: 16) {
            toolPlaceholders
            palette
            sideButtons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    /// Pen, marker and eraser. Not built yet; they hold their place.
    private var toolPlaceholders: some View {
        VStack(spacing: 6) {
            toolPlaceholder("pencil.tip", name: "Pen")
            toolPlaceholder("highlighter", name: "Marker")
            toolPlaceholder("eraser", name: "Eraser")
        }
    }

    private func toolPlaceholder(_ symbol: String, name: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14))
            .foregroundColor(.secondary)
            .frame(width: 44, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
            .opacity(0.5)
            .help("\(name) - coming later")
    }

    private var palette: some View {
        let top = Array(FolderSwatch.all.prefix(5))
        let bottom = Array(FolderSwatch.all.dropFirst(5))
        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                ForEach(top) { swatch in
                    swatchButton(swatch)
                }
            }
            HStack(spacing: 14) {
                ForEach(bottom) { swatch in
                    swatchButton(swatch)
                }
                customButton
            }
        }
    }

    private func swatchButton(_ swatch: FolderSwatch) -> some View {
        let isSelected = choice == FolderColorChoice.swatch(swatch.id)
        return Button {
            choice = FolderColorChoice.swatch(swatch.id)
        } label: {
            paletteCircle(fill: AnyShapeStyle(swatch.color), ringColor: swatch.color, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .help(swatch.name)
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The rainbow button: opens the system colour panel.
    private var customButton: some View {
        let isSelected = choice == FolderColorChoice.custom
        let custom = Color(nsColor: customTint.nsColor)
        return Button {
            openColorPanel()
        } label: {
            paletteCircle(
                fill: AnyShapeStyle(
                    AngularGradient(
                        gradient: Gradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red]),
                        center: .center
                    )
                ),
                ringColor: custom,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .help("Custom colour...")
        .accessibilityLabel("Custom colour")
    }

    /// A filled circle. When selected it becomes a thin ring of the same overall
    /// size with a smaller filled circle inside it.
    private func paletteCircle(fill: AnyShapeStyle, ringColor: Color, isSelected: Bool) -> some View {
        ZStack {
            if isSelected {
                Circle().strokeBorder(ringColor, lineWidth: 2)
                Circle().fill(ringColor).padding(6)
            } else {
                Circle().fill(fill)
            }
        }
        .frame(width: folderPaletteDiameter, height: folderPaletteDiameter)
    }

    private var sideButtons: some View {
        VStack(spacing: 12.5) {
            // Text on the folder. Not built yet.
            Text("Aa")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: folderSideButtonDiameter, height: folderSideButtonDiameter)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .opacity(0.5)
                .help("Text - coming later")

            Button {
                showingArtPicker.toggle()
            } label: {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: folderSideButtonDiameter, height: folderSideButtonDiameter)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Symbols, emoji and images")
            .popover(isPresented: $showingArtPicker, arrowEdge: .top) {
                FolderArtPicker(onPick: addArtwork)
            }
        }
    }

    // MARK: - Footer

    /// Sized by an invisible copy of the main window's footer content, so the two
    /// bars are exactly the same height. The real buttons sit in an overlay,
    /// which cannot make it taller.
    private var footerBar: some View {
        HStack {
            Spacer()
            Button(action: {}) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .hidden()
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .overlay {
            HStack(spacing: 8) {
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                // Undo and redo cover the artwork: placing, moving, resizing, deleting.
                Button { undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(historyIndex == 0)
                .help("Undo")

                Button { redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(historyIndex >= history.count - 1)
                .help("Redo")

                Spacer()

                Button("Clear") { clearDesign() }
                    .disabled(choice == nil && artworks.isEmpty)
                    .help("Back to the plain system folder: colour and artwork removed")

                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Actions

    private func load() {
        guard !didLoad, let item = store.items.first(where: { $0.id == itemID }) else { return }
        didLoad = true
        path = item.displayPath
        artworks = item.artwork ?? []
        history = [artworks]
        historyIndex = 0

        if let hex = item.folderColorHex, let tint = FolderRecolor.Tint(hex: hex) {
            if let match = FolderSwatch.all.first(where: { $0.tint.hex == hex }) {
                choice = FolderColorChoice.swatch(match.id)
            } else {
                customTint = tint
                choice = FolderColorChoice.custom
            }
        }

        colorPanel.onChange = { color in
            customTint = FolderRecolor.Tint(color: color)
            choice = FolderColorChoice.custom
        }
    }

    // MARK: - Artwork

    private func addArtwork(_ kind: FolderArtwork.Kind, _ value: String) {
        let artwork = FolderArtwork(kind: kind, value: value)
        artworks.append(artwork)
        selectedID = artwork.id
        showingArtPicker = false
        commitHistory()
    }

    private func duplicateArtwork(_ id: UUID) {
        guard let original = artworks.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.id = UUID()
        copy.x = min(original.x + 0.06, 0.5)
        copy.y = min(original.y + 0.06, 0.5)
        artworks.append(copy)
        selectedID = copy.id
        commitHistory()
    }

    private func recenterArtwork(_ id: UUID) {
        guard let index = artworks.firstIndex(where: { $0.id == id }) else { return }
        artworks[index].x = 0
        artworks[index].y = 0
        commitHistory()
    }

    private func deleteArtwork(_ id: UUID) {
        artworks.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        commitHistory()
    }

    private func clearDesign() {
        choice = nil
        selectedID = nil
        if !artworks.isEmpty {
            artworks = []
            commitHistory()
        }
    }

    /// Remembers the artwork as it is now, unless nothing changed.
    private func commitHistory() {
        guard artworks != history[historyIndex] else { return }
        history = Array(history.prefix(historyIndex + 1)) + [artworks]
        historyIndex = history.count - 1
    }

    private func undo() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        artworks = history[historyIndex]
        selectedID = nil
    }

    private func redo() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        artworks = history[historyIndex]
        selectedID = nil
    }

    private func openColorPanel() {
        choice = FolderColorChoice.custom
        colorPanel.show(initial: customTint.nsColor)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder"
        if panel.runModal() == .OK, let url = panel.url {
            path = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// Stores the choices with the item, then puts the icon on the folder - or, if
    /// the colour was cleared, takes the custom icon off. That happens after the
    /// editor has closed, so Save never waits on it.
    private func save() {
        guard var item = store.items.first(where: { $0.id == itemID }) else {
            onClose()
            return
        }
        let previousPath = item.path
        let wasOn = item.isCustomIconOn
        item.path = URL(fileURLWithPath: expandedPath).standardizedFileURL.path
        item.folderColorHex = currentTint?.hex
        item.artwork = artworks.isEmpty ? nil : artworks
        store.update(item)
        // Pictures that no folder uses any more are deleted.
        FolderArtworkStore.removeUnused(
            keeping: Set(store.items.flatMap { $0.artwork ?? [] }.filter { $0.kind == .image }.map { $0.value })
        )
        onClose()

        let saved = item
        let store = self.store
        Task {
            await FolderIconApplier.saved(saved, previousPath: previousPath, wasOn: wasOn, store: store)
        }
    }
}

// MARK: - Symbols, emoji and images

/// Every single-character emoji this Mac knows, named so they can be searched.
/// Built from Unicode's own data, so there is no list to keep up to date.
/// Skin-tone variants, flags and other multi-character emoji are not included.
enum FolderEmojiCatalog {
    struct Entry: Identifiable {
        let character: String
        /// Unicode's name for it, lowercased: "grinning face".
        let name: String
        var id: String { character }
    }

    static let all: [Entry] = build()

    private static func build() -> [Entry] {
        var entries: [Entry] = []
        for value in UInt32(0x203C)...UInt32(0x1FAFF) {
            // Skips the few values that are not characters at all.
            guard let scalar = Unicode.Scalar(value) else { continue }
            let properties = scalar.properties
            guard properties.isEmoji, !properties.isEmojiModifier else { continue }
            // Half of a flag, which means nothing on its own.
            if (0x1F1E6...0x1F1FF).contains(value) { continue }

            var text = String(Character(scalar))
            // Some emoji are drawn as plain text unless asked to be a picture.
            if !properties.isEmojiPresentation { text += "\u{FE0F}" }
            entries.append(Entry(character: text, name: (properties.name ?? "").lowercased()))
        }
        return entries
    }
}

/// The pop-up behind the grid button. The layout only for now: nothing picked
/// here reaches the folder yet. Symbols are every SF Symbol this Mac can draw,
/// from the same catalogue as the Sidebar editor's symbol browser.
struct FolderArtPicker: View {
    /// Called with what was clicked; the editor puts it on the folder.
    let onPick: (FolderArtwork.Kind, String) -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case symbols = "Symbols"
        case emoji = "Emoji"
        case image = "Image"
        var id: String { rawValue }
    }

    /// Used only if macOS's symbol catalogue cannot be read.
    private static let fallbackSymbols = [
        "star.fill", "heart.fill", "bookmark.fill", "flag.fill", "tag.fill", "tray.fill",
        "briefcase.fill", "doc.fill", "book.fill", "photo.fill", "camera.fill", "video.fill",
        "music.note", "gamecontroller.fill", "terminal.fill", "hammer.fill", "house.fill",
        "person.fill", "cloud.fill", "gearshape.fill", "lock.fill", "key.fill", "bell.fill",
        "calendar", "clock.fill", "cart.fill", "creditcard.fill", "globe", "map.fill",
        "paintbrush.fill", "pencil", "scissors", "archivebox.fill", "paperplane.fill",
        "link", "bolt.fill", "leaf.fill", "flame.fill", "drop.fill", "moon.fill", "car.fill"
    ]

    @State private var tab: Tab = .symbols

    @State private var symbolSearch = ""
    @State private var symbols: [SymbolCatalog.Symbol] = []
    @State private var isLoadingSymbols = true
    @State private var pickedSymbol: String?

    @State private var emojiSearch = ""
    @State private var emojis: [FolderEmojiCatalog.Entry] = []
    @State private var isLoadingEmoji = true
    @State private var pickedEmoji: String?

    private let columns = [GridItem(.adaptive(minimum: 36), spacing: 4)]

    var body: some View {
        VStack(spacing: 10) {
            Picker("Kind", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case .symbols: symbolsTab
                case .emoji: emojiTab
                case .image: imageTab
                }
            }
            .frame(height: 260)

            Text("Click one to place it on the folder.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(width: 340)
        // Each list is built the first time its tab is opened, off the main
        // thread, and then kept.
        .task(id: tab) {
            switch tab {
            case .symbols: await loadSymbols()
            case .emoji: await loadEmoji()
            case .image: break
            }
        }
    }

    private func loadSymbols() async {
        guard isLoadingSymbols else { return }
        let loaded = await Task.detached(priority: .userInitiated) {
            SymbolCatalog.all
        }.value
        symbols = loaded.isEmpty
            ? Self.fallbackSymbols.map { SymbolCatalog.Symbol(name: $0, categories: [], keywords: []) }
            : loaded
        isLoadingSymbols = false
    }

    private func loadEmoji() async {
        guard isLoadingEmoji else { return }
        emojis = await Task.detached(priority: .userInitiated) {
            FolderEmojiCatalog.all
        }.value
        isLoadingEmoji = false
    }

    // MARK: Symbols

    private var symbolResults: [SymbolCatalog.Symbol] {
        SymbolCatalog.search(symbolSearch, in: symbols)
    }

    private var symbolsTab: some View {
        VStack(spacing: 8) {
            TextField(isLoadingSymbols ? "Search symbols" : "Search \(symbols.count) symbols", text: $symbolSearch)
                .textFieldStyle(.roundedBorder)

            if isLoadingSymbols {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if symbolResults.isEmpty {
                Text("No symbols match \u{201C}\(symbolSearch)\u{201D}")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(symbolResults) { symbol in
                            symbolCell(symbol)
                        }
                    }
                }
            }
        }
    }

    private func symbolCell(_ symbol: SymbolCatalog.Symbol) -> some View {
        Button {
            onPick(.symbol, symbol.name)
        } label: {
            Image(systemName: symbol.name)
                .font(.system(size: 16))
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(pickedSymbol == symbol.name ? Color.accentColor.opacity(0.25) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(symbol.name)
    }

    // MARK: Emoji

    /// Every word typed has to appear in the emoji's name: "red heart" finds "red heart".
    private var emojiResults: [FolderEmojiCatalog.Entry] {
        let words = emojiSearch.lowercased().split(separator: " ").map(String.init)
        if words.isEmpty { return emojis }
        return emojis.filter { entry in
            words.allSatisfy { entry.name.contains($0) }
        }
    }

    private var emojiTab: some View {
        VStack(spacing: 8) {
            TextField(isLoadingEmoji ? "Search emoji" : "Search \(emojis.count) emoji", text: $emojiSearch)
                .textFieldStyle(.roundedBorder)

            if isLoadingEmoji {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if emojiResults.isEmpty {
                Text("No emoji match \u{201C}\(emojiSearch)\u{201D}")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(emojiResults) { entry in
                            emojiCell(entry)
                        }
                    }
                }
            }
        }
    }

    private func emojiCell(_ entry: FolderEmojiCatalog.Entry) -> some View {
        Button {
            onPick(.emoji, entry.character)
        } label: {
            Text(entry.character)
                .font(.system(size: 20))
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(pickedEmoji == entry.character ? Color.accentColor.opacity(0.25) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(entry.name.capitalized)
    }

    // MARK: Image

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a picture to place on the folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let name = FolderArtworkStore.importImage(from: url) {
            onPick(.image, name)
        } else {
            let alert = NSAlert()
            alert.messageText = "That picture couldn\u{2019}t be read"
            alert.informativeText = "Try a PNG, JPEG or SVG file."
            alert.runModal()
        }
    }

    private var imageTab: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundColor(.secondary.opacity(0.6))
                .overlay(
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 26))
                            .foregroundColor(.secondary)
                        Text("Choose a PNG, SVG or other picture")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                )

            Button("Choose File...") { chooseImage() }
        }
    }
}
