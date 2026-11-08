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
        FolderSwatch(id: "white", name: "White", tint: .init(hue: 0.0, saturation: 0.0, value: 0.953)),
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

/// The folder colour at one step of the undo history.
private struct ColorSnap: Equatable {
    var choice: FolderColorChoice?
    var customHex: String
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
        // Open next to the editor window instead of in macOS's remembered corner.
        // Once it is open it stays wherever it is moved.
        if !panel.isVisible, let window = NSApp.keyWindow ?? NSApp.mainWindow, window !== panel {
            let frame = window.frame
            var origin = NSPoint(x: frame.maxX + 12, y: frame.maxY - panel.frame.height)
            if let area = window.screen?.visibleFrame {
                if origin.x + panel.frame.width > area.maxX { origin.x = frame.minX - panel.frame.width - 12 }
                origin.x = max(origin.x, area.minX + 12)
                origin.y = min(max(origin.y, area.minY), area.maxY - panel.frame.height)
            }
            panel.setFrameOrigin(origin)
        }
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
    @State private var colorHistory: [ColorSnap] = [ColorSnap(choice: nil, customHex: "")]
    @State private var lastColorCommit = Date.distantPast
    @State private var deleteKeyMonitor: Any?
    @State private var canvasSide: CGFloat = 300
    /// The text box is showing in place of the palette.
    @State private var editingText = false
    @FocusState private var textFieldFocused: Bool

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

    /// The selected artwork, when it is a symbol: the palette then colours it instead of the folder.
    private var selectedSymbolIndex: Int? {
        guard let id = selectedID else { return nil }
        return artworks.firstIndex { $0.id == id && ($0.kind == .symbol || $0.kind == .text || $0.kind == .image) }
    }
    private var targetsSymbol: Bool { selectedSymbolIndex != nil }
    private var symbolColorHex: String? { selectedSymbolIndex.flatMap { artworks[$0].colorHex } }

    private static func symbolHex(for swatch: FolderSwatch) -> String {
        swatch.id == "white" ? "#FFFFFF" : swatch.tint.hex
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
                // (The folder's name is in the title strip: see the overlay below.)
                HStack(spacing: 8) {
                    TextField("Folder Path", text: $path)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") { browse() }
                        .help("Choose the folder to style")
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
        .overlay(alignment: .top) {
            // The folder's name sits in the window's title strip, level with the traffic lights.
            Text(folderName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 90)
                .offset(y: -(StudioMetrics.titleStripHeight - 9))
                .allowsHitTesting(false)
        }
        .onAppear { load(); installDeleteKey() }
        .onChange(of: selectedID) { id in
            // Selecting artwork takes the cursor out of the (read-only) name box, so Delete reaches the artwork.
            if id != nil, !editingText { NSApp.keyWindow?.makeFirstResponder(nil) }
            // The text box only belongs to text.
            if let id, !artworks.contains(where: { $0.id == id && $0.kind == .text }) { editingText = false }
            if id == nil { editingText = false }
            // A text left empty is not kept.
            let before = artworks.count
            artworks.removeAll { $0.kind == .text && $0.id != id && $0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            if artworks.count != before { commitHistory() }
        }
        .onDisappear {
            if let monitor = deleteKeyMonitor { NSEvent.removeMonitor(monitor) }
            deleteKeyMonitor = nil
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
                        onDelete: deleteArtwork,
                        onMoveUp: moveUp,
                        onMoveDown: moveDown,
                        onRemoveColor: removeColor,
                        onDoubleTap: openTextBox
                    )
                    .frame(width: side, height: side)
                    .scaleEffect(folderCanvasScale)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear { canvasSide = side }
            .onChange(of: side) { canvasSide = $0 }
            .overlay(alignment: .bottom) { selectionBar }
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                dropPictures(providers)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 4)
    }

    /// Shown under the folder while a piece of artwork is selected.
    @ViewBuilder
    private var selectionBar: some View {
        if let id = selectedID {
            let hasShadow = artworks.first { $0.id == id }?.hasShadow ?? false
            HStack(spacing: 10) {
                if selectedTextIndex != nil {
                    Button { editingText.toggle() } label: {
                        Text("Aa")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.primary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help(editingText ? "Hide the text box" : "Edit the text")
                }
                barButton("scope", help: "Recenter") { recenterArtwork(id) }
                barButton("square.filled.on.square", help: hasShadow ? "Drop shadow: on" : "Drop shadow: off", isOn: hasShadow) {
                    toggleShadow(id)
                }
                barButton("checkmark", help: "Confirm position") { selectedID = nil }
            }
            .padding(.bottom, 2)
        }
    }

    private func barButton(_ symbol: String, help: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(isOn ? 0.3 : 0.12)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Tools, palette and the art button

    private var controls: some View {
        HStack(alignment: .center, spacing: 16) {
            palette
                .opacity(showsTextEditor ? 0 : 1)
                .allowsHitTesting(!showsTextEditor)
            sideButtons
                .opacity(showsTextEditor ? 0 : 1)
                .allowsHitTesting(!showsTextEditor)
        }
        // The text box grows out of the Aa button, over the palette.
        .overlay(alignment: .topTrailing) { textEditorOverlay }
        .animation(.easeInOut(duration: 0.25), value: showsTextEditor)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
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
        let isSelected = targetsSymbol
            ? symbolColorHex == Self.symbolHex(for: swatch)
            : choice == FolderColorChoice.swatch(swatch.id)
        return Button {
            if let index = selectedSymbolIndex {
                artworks[index].colorHex = Self.symbolHex(for: swatch)
            } else {
                choice = FolderColorChoice.swatch(swatch.id)
            }
            commitHistory()
        } label: {
            paletteCircle(fill: AnyShapeStyle(swatch.color), ringColor: swatch.color, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        // No tooltip on the swatches: the colour speaks for itself.
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The rainbow button: opens the system colour panel.
    private var customButton: some View {
        let symbolTint = symbolColorHex.flatMap { FolderRecolor.Tint(hex: $0) }
        var isSelected = choice == FolderColorChoice.custom
        var shown = customTint
        if targetsSymbol {
            let isSwatchColor = FolderSwatch.all.contains { Self.symbolHex(for: $0) == symbolColorHex }
            isSelected = symbolTint != nil && !isSwatchColor
            if let symbolTint { shown = symbolTint }
        }
        let custom = Color(nsColor: shown.nsColor)
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
        // No tooltip on the custom colour either.
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
            Button {
                addText()
            } label: {
                Text("Aa")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: folderSideButtonDiameter, height: folderSideButtonDiameter)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Add text")

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
                    .help("Close without saving")

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
                    .help("Save this design")
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
            if let index = selectedSymbolIndex {
                artworks[index].colorHex = FolderRecolor.Tint(color: color).hex
            } else {
                customTint = FolderRecolor.Tint(color: color)
                choice = FolderColorChoice.custom
            }
            commitHistory(coalesce: true)
        }
        colorHistory = [currentColorSnap]
    }

    // MARK: - Text

    private var selectedTextIndex: Int? {
        guard let id = selectedID else { return nil }
        return artworks.firstIndex { $0.id == id && $0.kind == .text }
    }

    /// The text box under the folder: shown while text is being edited, in place of the palette.
    private var showsTextEditor: Bool { editingText && selectedTextIndex != nil }

    private var textBinding: Binding<String> {
        Binding(
            get: { selectedTextIndex.map { artworks[$0].value } ?? "" },
            set: { newValue in
                guard let index = selectedTextIndex else { return }
                artworks[index].value = String(newValue.prefix(36))
                commitHistory(coalesce: true)
            }
        )
    }

    /// As wide as the palette and the buttons beside it.
    private var textBoxWidth: CGFloat {
        5 * folderPaletteDiameter + 4 * 14 + 16 + folderSideButtonDiameter
    }

    /// The text box. A pill grows to the left out of the Aa button, then the font
    /// choices drop down from under it. Both are always in the view, so the
    /// animation can run both ways.
    private var textEditorOverlay: some View {
        let open = showsTextEditor
        let index = selectedTextIndex
        let value = index.map { artworks[$0].value } ?? ""
        let style = FolderTextFont.style(index.flatMap { artworks[$0].fontStyle })
        return VStack(alignment: .trailing, spacing: 10) {
            HStack(spacing: 0) {
                TextField("Type something", text: textBinding)
                    .textFieldStyle(.plain)
                    .focused($textFieldFocused)
                    .onSubmit { selectedID = nil }
                    .padding(.leading, 14)
                    .opacity(open ? 1 : 0)
                Text("\(value.count)/36")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .opacity(open ? 1 : 0)
                Button {
                    editingText = false
                } label: {
                    Text("Aa")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: folderSideButtonDiameter, height: folderSideButtonDiameter)
                        .background(Circle().fill(Color.primary.opacity(open ? 0.08 : 0)))
                        .opacity(open ? 1 : 0)
                }
                .buttonStyle(.plain)
                .help("Colours")
            }
            .frame(width: open ? textBoxWidth : folderSideButtonDiameter,
                   height: folderSideButtonDiameter,
                   alignment: .trailing)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(open ? 0.3 : 0), lineWidth: 1.5))
            .allowsHitTesting(open)

            if open {
                fontChips(selected: style)
                    .frame(width: textBoxWidth)
                    .transition(.asymmetric(
                        insertion: AnyTransition.move(edge: .top)
                            .combined(with: .opacity)
                            .animation(.easeOut(duration: 0.5).delay(0.4)),
                        removal: AnyTransition.opacity.animation(.easeIn(duration: 0.3))
                    ))
            }
        }
        .onChange(of: showsTextEditor) { isOpen in
            if isOpen {
                // After the pill has grown.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { textFieldFocused = true }
            } else {
                textFieldFocused = false
            }
        }
    }

    private func fontChips(selected style: FolderTextFont) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(FolderTextFont.allCases, id: \.self) { entry in
                    let isSelected = style == entry
                    Button {
                        if let current = selectedTextIndex {
                            artworks[current].fontStyle = entry == .classic ? nil : entry.rawValue
                            commitHistory()
                        }
                    } label: {
                        Text(entry.label)
                            .font(entry.font(size: 13))
                            .foregroundColor(isSelected ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Capsule().fill(Color.primary.opacity(isSelected ? 0.14 : 0)))
                    }
                    .buttonStyle(.plain)
                    .help("\(entry.label) font")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    /// Adds an empty text and opens the text box. It is not kept if it is left empty.
    private func addText() {
        var artwork = FolderArtwork(kind: .text, value: "")
        artwork.size = 0.35
        artworks.append(artwork)
        editingText = true
        selectedID = artwork.id
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

    /// One layer towards the front.
    private func moveUp(_ id: UUID) {
        guard let index = artworks.firstIndex(where: { $0.id == id }), index < artworks.count - 1 else { return }
        artworks.swapAt(index, index + 1)
        commitHistory()
    }

    /// One layer towards the back.
    private func moveDown(_ id: UUID) {
        guard let index = artworks.firstIndex(where: { $0.id == id }), index > 0 else { return }
        artworks.swapAt(index, index - 1)
        commitHistory()
    }

    /// Double-clicking a text opens its text box.
    private func openTextBox(_ id: UUID) {
        guard artworks.contains(where: { $0.id == id && $0.kind == .text }) else { return }
        editingText = true
        selectedID = id
    }

    /// A picture goes back to its own colours.
    private func removeColor(_ id: UUID) {
        guard let index = artworks.firstIndex(where: { $0.id == id }) else { return }
        artworks[index].colorHex = nil
        commitHistory()
    }

    private func toggleShadow(_ id: UUID) {
        guard let index = artworks.firstIndex(where: { $0.id == id }) else { return }
        artworks[index].shadow = !artworks[index].hasShadow
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

    /// One arrow-key step, in points on screen. The canvas is drawn at `folderCanvasScale`.
    private func nudgeArtwork(_ id: UUID, by direction: CGPoint, points: CGFloat) {
        guard let index = artworks.firstIndex(where: { $0.id == id }) else { return }
        let panel = FolderPanel.rect(in: max(1, canvasSide))
        artworks[index].x += Double(direction.x * points / max(1, panel.width * folderCanvasScale))
        artworks[index].y += Double(direction.y * points / max(1, panel.height * folderCanvasScale))
        commitHistory(coalesce: true)
    }

    /// Delete / Backspace removes the selected artwork, unless the person is typing.
    private func installDeleteKey() {
        guard deleteKeyMonitor == nil else { return }
        deleteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Cmd+Z undo, Cmd+Shift+Z redo (left to the path field while you are typing in it).
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 6, mods == .command || mods == [.command, .shift], !showingArtPicker {
                if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.string == path { return event }
                if mods == .command { undo() } else { redo() }
                return nil
            }
            // Arrow keys nudge the selected artwork by 1 pt (10 pt with Shift).
            let arrows: [UInt16: CGPoint] = [
                123: CGPoint(x: -1, y: 0), 124: CGPoint(x: 1, y: 0),
                125: CGPoint(x: 0, y: 1), 126: CGPoint(x: 0, y: -1)
            ]
            if let direction = arrows[event.keyCode], let id = selectedID, !showingArtPicker,
               mods.intersection([.command, .option, .control]).isEmpty,
               NSApp.keyWindow !== NSColorPanel.shared,
               !(NSApp.keyWindow?.firstResponder is NSText) {
                nudgeArtwork(id, by: direction, points: mods.contains(.shift) ? 10 : 1)
                return nil
            }
            // Cmd+D duplicates; Cmd+Up and Cmd+Down move it one layer up or down.
            if mods.subtracting([.numericPad, .function]) == .command, let id = selectedID, !showingArtPicker,
               NSApp.keyWindow !== NSColorPanel.shared,
               !(NSApp.keyWindow?.firstResponder is NSText) {
                switch event.keyCode {
                case 2: duplicateArtwork(id); return nil
                case 126: moveUp(id); return nil
                case 125: moveDown(id); return nil
                default: break
                }
            }
            // Return confirms a selected piece of artwork. With nothing selected it saves, as before.
            if event.keyCode == 36 || event.keyCode == 76, selectedID != nil, !showingArtPicker,
               mods.intersection([.command, .option, .control]).isEmpty,
               NSApp.keyWindow !== NSColorPanel.shared,
               !(NSApp.keyWindow?.firstResponder is NSText) {
                selectedID = nil
                return nil
            }
            // Escape works like Return: it lets go of a selected piece of artwork.
            // With nothing selected it cancels, as before.
            if event.keyCode == 53, selectedID != nil, !showingArtPicker,
               mods.intersection([.command, .option, .control]).isEmpty,
               NSApp.keyWindow !== NSColorPanel.shared {
                if NSApp.keyWindow?.firstResponder is NSText { NSApp.keyWindow?.makeFirstResponder(nil) }
                selectedID = nil
                return nil
            }
            guard event.keyCode == 51 || event.keyCode == 117,
                  let id = selectedID, !showingArtPicker else { return event }
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            deleteArtwork(id)
            return nil
        }
    }

    /// A picture dragged from Finder onto the folder becomes artwork.
    private func dropPictures(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let u = item as? URL { url = u }
            guard let url else { return }
            DispatchQueue.main.async {
                if let name = FolderArtworkStore.importImage(from: url) {
                    addArtwork(.image, name)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "That picture couldn\u{2019}t be read"
                    alert.informativeText = "Try a PNG, JPEG or SVG file."
                    alert.runModal()
                }
            }
        }
        return true
    }

    private func clearDesign() {
        choice = nil
        selectedID = nil
        if !artworks.isEmpty { artworks = [] }
        commitHistory()
    }

    /// Remembers the artwork as it is now, unless nothing changed.
    private var currentColorSnap: ColorSnap {
        ColorSnap(choice: choice, customHex: customTint.hex)
    }

    private func commitHistory(coalesce: Bool = false) {
        let snap = currentColorSnap
        guard artworks != history[historyIndex] || snap != colorHistory[historyIndex] else { return }
        // Dragging in the colour panel fires many changes: fold them into one undo step.
        if coalesce, historyIndex > 0, historyIndex == history.count - 1,
           Date().timeIntervalSince(lastColorCommit) < 1.0 {
            history[historyIndex] = artworks
            colorHistory[historyIndex] = snap
        } else {
            history = Array(history.prefix(historyIndex + 1)) + [artworks]
            colorHistory = Array(colorHistory.prefix(historyIndex + 1)) + [snap]
            historyIndex = history.count - 1
        }
        if coalesce { lastColorCommit = Date() }
    }

    private func restoreColor(_ snap: ColorSnap) {
        choice = snap.choice
        if let tint = FolderRecolor.Tint(hex: snap.customHex) { customTint = tint }
    }

    private func undo() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        artworks = history[historyIndex]
        restoreColor(colorHistory[historyIndex])
        selectedID = nil
    }

    private func redo() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        artworks = history[historyIndex]
        restoreColor(colorHistory[historyIndex])
        selectedID = nil
    }

    private func openColorPanel() {
        if let index = selectedSymbolIndex {
            let current = artworks[index].colorHex.flatMap { FolderRecolor.Tint(hex: $0) } ?? FolderRecolor.Tint(hex: "#FFFFFF")
            colorPanel.show(initial: (current ?? customTint).nsColor)
            return
        }
        choice = FolderColorChoice.custom
        commitHistory(coalesce: true)
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
    @State private var hideTechnical = true
    @State private var technicalNames: Set<String> = []
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
        technicalNames = Set(symbols.filter { Self.isTechnical($0) }.map { $0.name })
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

    private static let technicalCategories: Set<String> = [
        "shapes", "arrows", "indices", "math", "keyboard", "textformatting", "editing"
    ]
    private static let genericCategories: Set<String> = ["all", "whatsnew", "multicolor", "variablecolor"]
    private static let shapeWords: Set<String> = [
        "circle", "square", "rectangle", "capsule", "triangle", "diamond", "oval", "hexagon",
        "octagon", "pentagon", "seal", "fill", "filled", "inset", "lefthalf", "righthalf",
        "tophalf", "bottomhalf", "dashed", "dotted", "slash", "portrait", "landscape"
    ]
    private static let languageSuffixes: Set<String> = [
        "ar", "hi", "he", "th", "ja", "ko", "zh", "bn", "gu", "kn", "ml", "mr", "my", "or",
        "pa", "ta", "te", "ur", "km", "rtl"
    ]

    /// Plain building blocks nobody wants on a folder: numbers and letters
    /// ("8.calendar", "a.circle", "1.lane"), language variants, bare shapes
    /// ("circle.fill"), and symbols Apple files only under technical categories.
    private static func isTechnical(_ symbol: SymbolCatalog.Symbol) -> Bool {
        let parts = symbol.name.split(separator: ".").map(String.init)
        if let first = parts.first, first.allSatisfy({ $0.isNumber }) || first.count == 1 { return true }
        if parts.count > 1, let last = parts.last, languageSuffixes.contains(last) { return true }
        if !parts.isEmpty, parts.allSatisfy({ shapeWords.contains($0) }) { return true }
        if symbol.categories.contains("indices") { return true }
        let real = symbol.categories.filter { !genericCategories.contains($0) }
        return !real.isEmpty && real.allSatisfy { technicalCategories.contains($0) }
    }

    /// What the grid starts from when nothing is typed.
    private var browsePool: [SymbolCatalog.Symbol] {
        hideTechnical ? symbols.filter { !technicalNames.contains($0.name) } : symbols
    }

    /// Searching looks through everything, so "circle" or "arrow" still finds them.
    private var symbolResults: [SymbolCatalog.Symbol] {
        let typing = !symbolSearch.trimmingCharacters(in: .whitespaces).isEmpty
        return SymbolCatalog.search(symbolSearch, in: typing ? symbols : browsePool)
    }

    private var symbolsTab: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField(isLoadingSymbols ? "Search symbols" : "Search \(browsePool.count) symbols", text: $symbolSearch)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Toggle("Hide shapes, numbers and arrows", isOn: $hideTechnical)
                } label: {
                    Image(systemName: hideTechnical ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 17))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Filter symbols. Search always looks through all of them.")
            }

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
                        Text("Choose a picture, or drag one onto the folder")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                )

            Button("Choose File...") { chooseImage() }
                .help("Pick a PNG, JPEG or SVG picture from your Mac")
        }
    }
}
