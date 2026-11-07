import SwiftUI
import UniformTypeIdentifiers

/// The shape of a macOS app icon on its 1024 px canvas: the body is 824 px
/// across, centred, with a continuous ("squircle") corner.
enum AppIconGrid {
    static let bodyRatio: CGFloat = 824.0 / 1024.0
    /// How far each corner reaches along an edge, as a share of the body width, and how
    /// square it is (2 would be a circle). Fitted to the outline of a real macOS icon: the
    /// fit is within about 2 px at 824 px, which Apple's own rounded rectangle is not.
    static let cornerExtent: CGFloat = 0.33
    static let cornerExponent: Double = 2.7
}

/// The macOS app icon outline: a square whose corners are flattened superellipse curves.
struct AppIconShape: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let r = min(box.width, box.height) * AppIconGrid.cornerExtent
        let n = AppIconGrid.cornerExponent
        let steps = 48

        // Clockwise from the top-left: centre of each corner, which way it points, and whether
        // its curve is walked from the edge to the next one (false) or the other way (true).
        let corners: [(cx: CGFloat, cy: CGFloat, sx: CGFloat, sy: CGFloat, reversed: Bool)] = [
            (box.minX + r, box.minY + r, -1, -1, false),
            (box.maxX - r, box.minY + r, 1, -1, true),
            (box.maxX - r, box.maxY - r, 1, 1, false),
            (box.minX + r, box.maxY - r, -1, 1, true)
        ]
        var points: [CGPoint] = []
        for corner in corners {
            for step in 0...steps {
                let fraction = Double(step) / Double(steps)
                let theta = (corner.reversed ? 1 - fraction : fraction) * Double.pi / 2
                let x = corner.cx + corner.sx * r * CGFloat(pow(cos(theta), 2 / n))
                let y = corner.cy + corner.sy * r * CGFloat(pow(sin(theta), 2 / n))
                points.append(CGPoint(x: x, y: y))
            }
        }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// The colours of the icon body: a gradient from top to bottom, as "#RRGGBB".
struct AppIconLook: Codable, Equatable {
    /// How the two colours blend. Optional so older saved lists still load; nil is linear.
    enum Style: String, Codable, CaseIterable {
        case linear, diagonal, radial, angular

        var title: String {
            switch self {
            case .linear: return "Linear"
            case .diagonal: return "Diagonal"
            case .radial: return "Radial"
            case .angular: return "Angular"
            }
        }

        var next: Style {
            let all = Style.allCases
            let index = all.firstIndex(of: self) ?? 0
            return all[(index + 1) % all.count]
        }
    }

    var topHex: String
    var bottomHex: String
    var style: Style?

    /// Like the system's Dark icon style: near black, slightly lighter at the top.
    static let dark = AppIconLook(topHex: "#232323", bottomHex: "#0F0F0F")
    /// Like the system's Clear icon style: a flat dark grey.
    static let middle = AppIconLook(topHex: "#303030", bottomHex: "#272727")
    static let light = AppIconLook(topHex: "#E2E2E2", bottomHex: "#C0C0C0")

    /// Light bodies get a bright rim along the bottom edge as well as the top.
    var isLight: Bool {
        FolderRecolor.Tint(hex: topHex).map { $0.value > 0.75 && $0.saturation < 0.3 } ?? false
    }

    /// The gradient, for a shape about `size` across.
    func fill(size: CGFloat) -> AnyShapeStyle {
        let top = appColor(topHex)
        let bottom = appColor(bottomHex)
        switch style ?? .linear {
        case .linear:
            return AnyShapeStyle(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
        case .diagonal:
            return AnyShapeStyle(LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .radial:
            return AnyShapeStyle(RadialGradient(colors: [top, bottom], center: UnitPoint(x: 0.5, y: 0.35),
                                                startRadius: 0, endRadius: size * 0.75))
        case .angular:
            return AnyShapeStyle(AngularGradient(colors: [top, bottom, top], center: .center))
        }
    }

    static let presets: [(name: String, look: AppIconLook)] = [
        ("Dark grey", .dark), ("Middle grey", .middle), ("Light grey", .light)
    ]
}

private func appColor(_ hex: String) -> Color {
    FolderRecolor.Tint(hex: hex).map { Color(nsColor: $0.nsColor) } ?? Color.gray
}

private func hexString(of color: Color) -> String {
    FolderRecolor.Tint(color: NSColor(color)).hex
}

/// The icon body, drawn in code: a gradient, a thin bright rim along the top
/// edge, an inner glow and a soft shadow.
struct AppSquircleView: View {
    let side: CGFloat
    var look: AppIconLook = .dark

    private var rimStops: [Gradient.Stop] {
        if look.isLight {
            return [
                Gradient.Stop(color: Color.white.opacity(0.95), location: 0),
                Gradient.Stop(color: Color.white.opacity(0), location: 0.18),
                Gradient.Stop(color: Color.white.opacity(0), location: 0.82),
                Gradient.Stop(color: Color.white.opacity(0.9), location: 1)
            ]
        }
        // Like Apple's dark icon: a bright rim along the top edge, a medium one along the
        // bottom edge, none on the sides. Lighter bodies get it a little stronger.
        let value = FolderRecolor.Tint(hex: look.topHex)?.value ?? 0.2
        let lift = min(1, max(0, (value - 0.2) / 0.4))
        return [
            Gradient.Stop(color: Color.white.opacity(0.6 + 0.2 * lift), location: 0),
            Gradient.Stop(color: Color.white.opacity(0), location: 0.10),
            Gradient.Stop(color: Color.white.opacity(0), location: 0.90),
            Gradient.Stop(color: Color.white.opacity(0.3 + 0.1 * lift), location: 1)
        ]
    }

    var body: some View {
        let size = side * AppIconGrid.bodyRatio
        let shape = AppIconShape()
        ZStack {
            shape.fill(look.fill(size: size))
            // Inner glow: light bodies only. Apple's dark icons have none.
            if look.isLight {
                shape
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: size * 0.03)
                    .blur(radius: size * 0.02)
                    .clipShape(shape)
            }
            shape.strokeBorder(
                LinearGradient(stops: rimStops, startPoint: .top, endPoint: .bottom),
                lineWidth: max(1, size * (look.isLight ? 0.004 : 0.006))
            )
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.35), radius: size * 0.03, x: 0, y: size * 0.015)
        .frame(width: side, height: side)
    }
}

/// The finished icon: the body with the artwork on it, clipped to the icon shape.
/// The canvas shows this, and the export renders it, so what you see is what you get.
struct AppIconCompositeView: View {
    let side: CGFloat
    var look: AppIconLook = .dark
    let artworks: [FolderArtwork]

    var body: some View {
        let size = side * AppIconGrid.bodyRatio
        ZStack(alignment: .topLeading) {
            AppSquircleView(side: side, look: look)

            ZStack {
                ForEach(artworks) { artwork in
                    FolderArtworkContent(artwork: artwork, box: CGFloat(artwork.size) * size)
                        .position(
                            x: side / 2 + CGFloat(artwork.x) * size,
                            y: side / 2 + CGFloat(artwork.y) * size
                        )
                }
            }
            .frame(width: side, height: side)
            .mask {
                AppIconShape()
                    .frame(width: size, height: size)
                    .frame(width: side, height: side)
            }
        }
        .frame(width: side, height: side)
    }
}

/// The icon with artwork you can select, move and resize. Same behaviour as the
/// folder canvas: dragging snaps to the middle, with a guide line while it holds.
/// Positions are measured from the middle of the icon body, in body widths.
struct AppIconCanvas: View {
    let side: CGFloat
    var look: AppIconLook = .dark
    @Binding var artworks: [FolderArtwork]
    @Binding var selectedID: UUID?
    var onCommit: () -> Void = {}
    var onDuplicate: (UUID) -> Void = { _ in }
    var onRecenter: (UUID) -> Void = { _ in }
    var onDelete: (UUID) -> Void = { _ in }

    @State private var moveStart: (id: UUID, x: Double, y: Double)?
    @State private var snappedX = false
    @State private var snappedY = false

    private let snapDistance: CGFloat = 6
    private let spaceName = "appIconCanvas"
    private let corners = [CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1), CGPoint(x: -1, y: 1), CGPoint(x: 1, y: 1)]

    private var bodyRect: CGRect {
        let size = side * AppIconGrid.bodyRatio
        return CGRect(x: (side - size) / 2, y: (side - size) / 2, width: size, height: size)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The same drawing the exported icon is made from. The selection box and handles go on top, unclipped.
            AppIconCompositeView(side: side, look: look, artworks: artworks)
                .contentShape(Rectangle())
                .onTapGesture { selectedID = nil }

            ForEach(artworks) { artwork in
                artworkView(artwork)
            }

            if snappedX {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: 1, height: bodyRect.height)
                    .position(x: bodyRect.midX, y: bodyRect.midY)
                    .allowsHitTesting(false)
            }
            if snappedY {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: bodyRect.width, height: 1)
                    .position(x: bodyRect.midX, y: bodyRect.midY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: side, height: side)
        .coordinateSpace(name: spaceName)
    }

    private func centerPoint(of artwork: FolderArtwork) -> CGPoint {
        CGPoint(
            x: bodyRect.midX + CGFloat(artwork.x) * bodyRect.width,
            y: bodyRect.midY + CGFloat(artwork.y) * bodyRect.height
        )
    }

    private func artworkView(_ artwork: FolderArtwork) -> some View {
        let box = CGFloat(artwork.size) * bodyRect.height
        let center = centerPoint(of: artwork)
        let isSelected = selectedID == artwork.id

        return ZStack {
            // An invisible box over the artwork, so all of it can be grabbed, also the part outside the icon.
            Color.clear
                .frame(width: box, height: box)
                .contentShape(Rectangle())
                .gesture(moveGesture(for: artwork))
                .onTapGesture { selectedID = artwork.id }
                .contextMenu {
                    Button("Duplicate") { onDuplicate(artwork.id) }
                    Button("Recenter") { onRecenter(artwork.id) }
                    Button("Delete", role: .destructive) { onDelete(artwork.id) }
                    Divider()
                    Button("Confirm position") { selectedID = nil }
                }

            if isSelected {
                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1)
                    .frame(width: box, height: box)
                    .allowsHitTesting(false)

                ForEach(corners, id: \.self) { corner in
                    handle(for: artwork, corner: corner, box: box, center: center)
                }
            }
        }
        .frame(width: box + 24, height: box + 24)
        .position(center)
    }

    private func handle(for artwork: FolderArtwork, corner: CGPoint, box: CGFloat, center: CGPoint) -> some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
            .frame(width: 11, height: 11)
            .offset(x: corner.x * box / 2, y: corner.y * box / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(spaceName))
                    .onChanged { value in
                        let reach = max(abs(value.location.x - center.x), abs(value.location.y - center.y))
                        let newSize = Double(reach * 2 / bodyRect.height)
                        update(artwork.id) { $0.size = min(max(newSize, 0.06), 1.3) }
                    }
                    .onEnded { _ in onCommit() }
            )
    }

    private func moveGesture(for artwork: FolderArtwork) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(spaceName))
            .onChanged { value in
                if moveStart?.id != artwork.id {
                    moveStart = (artwork.id, artwork.x, artwork.y)
                    selectedID = artwork.id
                }
                guard let start = moveStart else { return }

                var x = start.x + Double(value.translation.width / bodyRect.width)
                var y = start.y + Double(value.translation.height / bodyRect.height)

                snappedX = abs(x) * Double(bodyRect.width) < Double(snapDistance)
                snappedY = abs(y) * Double(bodyRect.height) < Double(snapDistance)
                if snappedX { x = 0 }
                if snappedY { y = 0 }

                update(artwork.id) {
                    $0.x = x
                    $0.y = y
                }
            }
            .onEnded { _ in
                moveStart = nil
                snappedX = false
                snappedY = false
                onCommit()
            }
    }

    private func update(_ id: UUID, _ change: (inout FolderArtwork) -> Void) {
        guard let index = artworks.firstIndex(where: { $0.id == id }) else { return }
        change(&artworks[index])
    }
}

/// Which end of the icon's gradient a colour belongs to.
private enum LookEnd { case top, bottom }

/// What the editor remembers at each step, for undo.
private struct AppSnapshot: Equatable {
    var artworks: [FolderArtwork]
    var look: AppIconLook
}

/// Every round control on the palette, and the buttons beside it, are this big.
private let appPaletteDiameter: CGFloat = 25
private let appSideButtonDiameter: CGFloat = 29

/// The in-window editor for one app's icon. For now it designs and saves; putting
/// the icon on the app comes later.
struct AppIconEditorView: View {
    let itemID: UUID
    let onClose: () -> Void

    @ObservedObject private var store = StudioIconStore.shared
    @StateObject private var colorPanel = ColorPanelBridge()

    @State private var artworks: [FolderArtwork] = []
    @State private var look: AppIconLook = .dark
    @State private var selectedID: UUID?
    @State private var history: [AppSnapshot] = []
    @State private var historyIndex = 0
    @State private var didLoad = false
    @State private var keyMonitor: Any?
    @State private var originalSaved = false
    @State private var canvasSide: CGFloat = 300
    @State private var lastCoalesce = Date.distantPast
    @State private var showingArtPicker = false

    private var item: StudioIconItem? {
        store.items.first { $0.id == itemID }
    }

    private var snapshot: AppSnapshot {
        AppSnapshot(artworks: artworks, look: look)
    }

    /// The selected artwork, when it is a symbol: the palette then colours it instead of the icon.
    private var selectedSymbolIndex: Int? {
        guard let id = selectedID else { return nil }
        return artworks.firstIndex { $0.id == id && $0.kind == .symbol }
    }
    private var targetsSymbol: Bool { selectedSymbolIndex != nil }
    private var symbolColorHex: String? { selectedSymbolIndex.flatMap { artworks[$0].colorHex } }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                readOnlyField(item?.displayName ?? "")
                readOnlyField(item?.displayPath ?? "")
                if originalSaved {
                    Text("The app's original icon is saved, so it can always be put back.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
        .onAppear {
            load()
            installKeys()
        }
        .onDisappear {
            if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
            keyMonitor = nil
            let panel = NSColorPanel.shared
            panel.setTarget(nil)
            panel.setAction(nil)
            panel.orderOut(nil)
        }
        .task { await keepOriginal() }
    }

    private func readOnlyField(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let side = max(1, min(geometry.size.width, geometry.size.height) * 0.86)
            AppIconCanvas(
                side: side,
                look: look,
                artworks: $artworks,
                selectedID: $selectedID,
                onCommit: { commitHistory() },
                onDuplicate: duplicateArtwork,
                onRecenter: recenterArtwork,
                onDelete: deleteArtwork
            )
            .frame(width: side, height: side)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .bottom) { selectionBar }
            .onAppear { canvasSide = side }
            .onChange(of: side) { canvasSide = $0 }
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                dropPictures(providers)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 4)
    }

    // MARK: - Selection bar: only while something is selected

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

    // MARK: - Palette and the buttons beside it

    private var controls: some View {
        HStack(alignment: .center, spacing: 16) {
            palette
            sideButtons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    /// Colours the icon body. While a symbol is selected it colours that symbol instead.
    private var palette: some View {
        VStack(spacing: 14) {
            if targetsSymbol {
                HStack(spacing: 14) {
                    ForEach(Array(FolderSwatch.all.prefix(5))) { swatch in
                        symbolSwatch(swatch)
                    }
                }
                HStack(spacing: 14) {
                    ForEach(Array(FolderSwatch.all.dropFirst(5))) { swatch in
                        symbolSwatch(swatch)
                    }
                    symbolCustomButton
                }
            } else {
                HStack(spacing: 14) {
                    ForEach(AppIconLook.presets.indices, id: \.self) { index in
                        presetButton(AppIconLook.presets[index])
                    }
                }
                HStack(spacing: 14) {
                    gradientPill
                    gradientTypeButton
                }
            }
        }
    }

    private func presetButton(_ preset: (name: String, look: AppIconLook)) -> some View {
        let isSelected = look == preset.look
        let gradient = LinearGradient(
            colors: [appColor(preset.look.topHex), appColor(preset.look.bottomHex)],
            startPoint: .top,
            endPoint: .bottom
        )
        return Button {
            look = preset.look
            commitHistory()
        } label: {
            paletteCircle(fill: AnyShapeStyle(gradient), ringColor: appColor(preset.look.topHex), isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .help(preset.name)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func symbolHex(for swatch: FolderSwatch) -> String {
        swatch.id == "white" ? "#FFFFFF" : swatch.tint.hex
    }

    private func symbolSwatch(_ swatch: FolderSwatch) -> some View {
        let isSelected = symbolColorHex == symbolHex(for: swatch)
        return Button {
            if let index = selectedSymbolIndex {
                artworks[index].colorHex = symbolHex(for: swatch)
                commitHistory()
            }
        } label: {
            paletteCircle(fill: AnyShapeStyle(swatch.color), ringColor: swatch.color, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .help("\(swatch.name) symbol")
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A filled circle. When selected it becomes a thin ring of the same overall
    /// size with a smaller filled circle inside it.
    private func paletteCircle(fill: AnyShapeStyle, ringColor: Color, innerFill: AnyShapeStyle? = nil,
                               isSelected: Bool) -> some View {
        ZStack {
            if isSelected {
                Circle().strokeBorder(ringColor, lineWidth: 2)
                Circle().fill(innerFill ?? fill).padding(6)
            } else {
                Circle().fill(fill)
            }
        }
        .frame(width: appPaletteDiameter, height: appPaletteDiameter)
    }

    /// One pill for the icon's two colours: a circle at each end, the blend between them in the middle.
    /// It is as wide as two circles and a gap, so with the type button it fills the same width as the row above.
    private var gradientPill: some View {
        let top = appColor(look.topHex)
        let bottom = appColor(look.bottomHex)
        return HStack(spacing: 0) {
            pillEnd(top, end: .top)
            Spacer(minLength: 0)
            pillEnd(bottom, end: .bottom)
        }
        .padding(3)
        .frame(width: appPaletteDiameter * 2 + 14, height: appPaletteDiameter)
        .background(Capsule().fill(LinearGradient(colors: [top, bottom], startPoint: .leading, endPoint: .trailing)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
    }

    private func pillEnd(_ color: Color, end: LookEnd) -> some View {
        Button {
            openLookColorPanel(end)
        } label: {
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
                .frame(width: appPaletteDiameter - 6, height: appPaletteDiameter - 6)
        }
        .buttonStyle(.plain)
        .help(end == .top ? "Icon colour: top" : "Icon colour: bottom")
        .accessibilityLabel(end == .top ? "Icon colour: top" : "Icon colour: bottom")
    }

    private func openLookColorPanel(_ end: LookEnd) {
        colorPanel.onChange = { color in
            let hex = FolderRecolor.Tint(color: color).hex
            if end == .top { look.topHex = hex } else { look.bottomHex = hex }
            commitHistory(coalesce: true)
        }
        let hex = end == .top ? look.topHex : look.bottomHex
        colorPanel.show(initial: FolderRecolor.Tint(hex: hex)?.nsColor ?? NSColor.gray)
    }

    /// Cycles the gradient type. Its picture changes with the type: it always shows the
    /// current one, in plain light-to-dark so it reads the same whatever colours are picked.
    private var gradientTypeButton: some View {
        let current = look.style ?? .linear
        return Button {
            let next = current.next
            look.style = next == .linear ? nil : next
            commitHistory()
        } label: {
            gradientTypeIcon(current)
                .frame(width: appPaletteDiameter, height: appPaletteDiameter)
        }
        .buttonStyle(.plain)
        .help("Gradient: \(current.title). Click for the next type.")
        .accessibilityLabel("Gradient type: \(current.title)")
    }

    /// The whole button is the gradient, in strong white-to-dark so each type is easy to tell apart.
    private func gradientTypeIcon(_ style: AppIconLook.Style) -> some View {
        let light = Color.white
        let dark = Color(white: 0.1)
        return Group {
            switch style {
            case .linear:
                Circle().fill(LinearGradient(colors: [light, dark], startPoint: .top, endPoint: .bottom))
            case .diagonal:
                Circle().fill(LinearGradient(colors: [light, dark], startPoint: .topLeading, endPoint: .bottomTrailing))
            case .radial:
                Circle().fill(RadialGradient(colors: [light, dark], center: .center,
                                             startRadius: 0, endRadius: appPaletteDiameter / 2))
            case .angular:
                Circle().fill(AngularGradient(colors: [light, dark, light], center: .center))
            }
        }
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
    }

    /// The rainbow button: opens the system colour panel for the selected symbol.
    private var symbolCustomButton: some View {
        let symbolTint = symbolColorHex.flatMap { FolderRecolor.Tint(hex: $0) }
        let isSwatchColor = FolderSwatch.all.contains { symbolHex(for: $0) == symbolColorHex }
        let isSelected = symbolTint != nil && !isSwatchColor
        let shown: Color = symbolTint.map { Color(nsColor: $0.nsColor) } ?? Color.white
        let rainbow = AngularGradient(
            gradient: Gradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red]),
            center: .center
        )
        return Button {
            openSymbolColorPanel()
        } label: {
            paletteCircle(fill: AnyShapeStyle(rainbow), ringColor: shown, innerFill: AnyShapeStyle(shown), isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .help("Custom symbol colour...")
        .accessibilityLabel("Custom symbol colour")
    }

    private func openSymbolColorPanel() {
        colorPanel.onChange = { color in
            guard let index = selectedSymbolIndex else { return }
            artworks[index].colorHex = FolderRecolor.Tint(color: color).hex
            commitHistory(coalesce: true)
        }
        let current = symbolColorHex.flatMap { FolderRecolor.Tint(hex: $0) }
        colorPanel.show(initial: current?.nsColor ?? NSColor.white)
    }

    private var sideButtons: some View {
        VStack(spacing: 12.5) {
            // The app's own artwork, taken out of the app.
            Button {
                useAppIcon()
            } label: {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: appSideButtonDiameter, height: appSideButtonDiameter)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Use the app's own icon as artwork")

            Button {
                showingArtPicker.toggle()
            } label: {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: appSideButtonDiameter, height: appSideButtonDiameter)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Symbols, emoji and images")
            .popover(isPresented: $showingArtPicker, arrowEdge: .top) {
                FolderArtPicker(onPick: addArtwork)
            }
        }
    }

    // Same height as the main footer: it sizes itself from an invisible copy of it.
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
                    .disabled(artworks.isEmpty && look == .dark)
                    .help("Back to the plain dark icon: colour and artwork removed")

                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Actions

    private func load() {
        guard !didLoad, let item else { return }
        didLoad = true
        artworks = item.artwork ?? []
        look = item.appLook ?? .dark
        history = [snapshot]
        historyIndex = 0
    }

    private func keepOriginal() async {
        guard let item else { return }
        let saved = await AppIconCache.ensureOriginal(for: item)
        originalSaved = saved != nil
    }

    private func save() {
        guard var current = item else {
            onClose()
            return
        }
        current.artwork = artworks.isEmpty ? nil : artworks
        current.appLook = look == .dark ? nil : look
        store.update(current)
        // Pictures that nothing uses any more are deleted.
        FolderArtworkStore.removeUnused(
            keeping: Set(store.items.flatMap { $0.artwork ?? [] }.filter { $0.kind == .image }.map { $0.value })
        )
        onClose()
    }

    private func clearDesign() {
        selectedID = nil
        artworks = []
        look = .dark
        commitHistory()
    }

    /// What the symbols, emoji and images picker hands back.
    private func addArtwork(_ kind: FolderArtwork.Kind, _ value: String) {
        showingArtPicker = false
        placeStored(kind, value, size: kind == .image ? 0.5 : 0.4)
    }

    private func placeStored(_ kind: FolderArtwork.Kind, _ value: String, size: Double) {
        var artwork = FolderArtwork(kind: kind, value: value)
        artwork.size = size
        artworks.append(artwork)
        selectedID = artwork.id
        commitHistory()
    }

    private func place(_ url: URL) {
        guard let name = FolderArtworkStore.importImage(from: url) else {
            let alert = NSAlert()
            alert.messageText = "That picture couldn\u{2019}t be read"
            alert.informativeText = "Try a PNG, JPEG or SVG file."
            alert.runModal()
            return
        }
        placeStored(.image, name, size: 0.5)
    }

    /// Takes the app's own artwork out of the app and places it on the icon, so it can be moved and resized.
    private func useAppIcon() {
        guard let item, let found = AppArtworkExtractor.extract(from: item.url) else {
            let alert = NSAlert()
            alert.messageText = "Couldn\u{2019}t find the app\u{2019}s own artwork"
            alert.informativeText = "This app keeps its icon in a form that can\u{2019}t be read here. You can still add a picture of your own."
            alert.runModal()
            return
        }
        placeStored(.image, found.name, size: found.size)
    }

    private func dropPictures(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { dropped, _ in
            var url: URL?
            if let data = dropped as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let direct = dropped as? URL { url = direct }
            guard let url else { return }
            DispatchQueue.main.async { place(url) }
        }
        return true
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

    // MARK: - Undo and keys

    /// Remembers the current state for undo. With `coalesce`, quick changes in a row
    /// (dragging in a colour picker, holding an arrow key) count as one step.
    private func commitHistory(coalesce: Bool = false) {
        let current = snapshot
        guard !history.isEmpty, current != history[historyIndex] else { return }
        if coalesce, historyIndex > 0, historyIndex == history.count - 1,
           Date().timeIntervalSince(lastCoalesce) < 0.8 {
            history[historyIndex] = current
        } else {
            history = Array(history.prefix(historyIndex + 1)) + [current]
            historyIndex = history.count - 1
        }
        if coalesce { lastCoalesce = Date() }
    }

    private func restore(_ state: AppSnapshot) {
        artworks = state.artworks
        look = state.look
        selectedID = nil
    }

    private func undo() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        restore(history[historyIndex])
    }

    private func redo() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        restore(history[historyIndex])
    }

    /// Delete removes the selected artwork; Cmd+Z and Cmd+Shift+Z undo and redo;
    /// the arrow keys nudge it by 1 pt (10 pt with Shift).
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Leave the colour panel, and any text being typed, alone.
            if event.window === NSColorPanel.shared || event.window?.firstResponder is NSText { return event }

            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 6, mods == .command || mods == [.command, .shift] {
                if mods == .command { undo() } else { redo() }
                return nil
            }
            if event.keyCode == 51 || event.keyCode == 117, let id = selectedID {
                deleteArtwork(id)
                return nil
            }
            let arrows: [UInt16: CGPoint] = [
                123: CGPoint(x: -1, y: 0), 124: CGPoint(x: 1, y: 0),
                125: CGPoint(x: 0, y: 1), 126: CGPoint(x: 0, y: -1)
            ]
            if let direction = arrows[event.keyCode], let id = selectedID,
               mods.intersection([.command, .option, .control]).isEmpty {
                nudge(id, by: direction, points: mods.contains(.shift) ? 10 : 1)
                return nil
            }
            return event
        }
    }

    private func nudge(_ id: UUID, by direction: CGPoint, points: CGFloat) {
        guard let index = artworks.firstIndex(where: { $0.id == id }) else { return }
        let body = max(1, canvasSide * AppIconGrid.bodyRatio)
        artworks[index].x += Double(direction.x * points / body)
        artworks[index].y += Double(direction.y * points / body)
        commitHistory(coalesce: true)
    }
}
