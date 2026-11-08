import SwiftUI
import AppKit

/// The text fonts, after the ones Instagram Stories offers (Classic, Modern, Neon,
/// Typewriter, Strong, and a serif), each matched with a font every Mac has. They
/// are looks, not copies. If a Mac lacks one, the rounded system font stands in.
enum FolderTextFont: String, CaseIterable {
    case classic, modern, neon, typewriter, strong, serif

    static func style(_ name: String?) -> FolderTextFont {
        name.flatMap { FolderTextFont(rawValue: $0) } ?? .classic
    }

    var label: String { rawValue.capitalized }
    /// Neon text glows in its own colour.
    var glows: Bool { self == .neon }
    /// Strong text is set in capitals.
    var capitals: Bool { self == .strong }

    private var postScriptName: String? {
        switch self {
        case .classic: return "HelveticaNeue-Bold"
        case .modern: return "Futura-Medium"
        case .neon: return nil
        case .typewriter: return "CourierNewPS-BoldMT"
        case .strong: return "Futura-CondensedExtraBold"
        case .serif: return "Didot-Bold"
        }
    }

    /// For measuring.
    func nsFont(size: CGFloat) -> NSFont {
        if let name = postScriptName, let font = NSFont(name: name, size: size) { return font }
        let base = NSFont.systemFont(ofSize: size, weight: .heavy)
        if let descriptor = base.fontDescriptor.withDesign(.rounded), let rounded = NSFont(descriptor: descriptor, size: size) {
            return rounded
        }
        return base
    }

    /// For drawing: the same font as `nsFont`.
    func font(size: CGFloat) -> Font {
        if let name = postScriptName, NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: .heavy, design: .rounded)
    }
}

extension FolderArtwork {
    /// What is drawn for a text: capitals for Strong.
    var drawnText: String {
        FolderTextFont.style(fontStyle).capitals ? value.uppercased() : value
    }

    /// The box that fits a text, for a text whose square box has side `box`.
    func textBoxSize(box: CGFloat) -> CGSize {
        let em = box * 0.5
        let font = FolderTextFont.style(fontStyle).nsFont(size: em)
        // An empty text is measured as a short word, so its box can still be seen and grabbed.
        let measured = ((drawnText.isEmpty ? "Text" : drawnText) as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(measured.width) + em * 0.5, height: ceil(measured.height) + em * 0.3)
    }
}

/// What one piece of artwork looks like, drawn to fit a square of side `box`.
struct FolderArtworkContent: View {
    let artwork: FolderArtwork
    let box: CGFloat
    /// The folder canvas turns the whole selection box itself, so it asks for none here.
    var rotates = true

    var body: some View {
        content
            .frame(width: frameSize.width, height: frameSize.height)
            .shadow(color: artwork.kind != .text && artwork.hasShadow ? Color.black.opacity(0.25) : Color.clear,
                    radius: box * 0.02, y: box * 0.01)
            .rotationEffect(.degrees(rotates ? artwork.angle : 0))
    }

    private var symbolColor: Color {
        if let hex = artwork.colorHex, let tint = FolderRecolor.Tint(hex: hex) {
            return Color(nsColor: tint.nsColor)
        }
        return Color.white.opacity(0.92)
    }

    /// Everything is a square, except text: its box fits the text.
    static func frameSize(for artwork: FolderArtwork, box: CGFloat) -> CGSize {
        artwork.kind == .text ? artwork.textBoxSize(box: box) : CGSize(width: box, height: box)
    }

    private var frameSize: CGSize { Self.frameSize(for: artwork, box: box) }

    @ViewBuilder
    private var content: some View {
        switch artwork.kind {
        case .symbol:
            Image(systemName: artwork.value)
                .resizable()
                .scaledToFit()
                .foregroundColor(symbolColor)
                .padding(box * 0.08)
        case .text:
            // One line. The box fits the text; make the box bigger for bigger text.
            let style = FolderTextFont.style(artwork.fontStyle)
            let em = box * 0.5
            Text(artwork.drawnText)
                .font(style.font(size: em))
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(symbolColor)
                .shadow(color: style.glows ? symbolColor.opacity(0.85) : (artwork.hasShadow ? Color.black.opacity(0.25) : Color.clear),
                        radius: style.glows ? em * 0.2 : em * 0.04,
                        y: style.glows ? 0 : em * 0.02)
                .shadow(color: style.glows ? symbolColor.opacity(0.6) : Color.clear, radius: em * 0.06)
        case .emoji:
            Text(artwork.value)
                .font(.system(size: box * 0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.1)
        case .image:
            if let image = FolderArtworkStore.image(named: artwork.value) {
                if artwork.colorHex != nil {
                    // Recoloured: the picture's opaque parts take one flat colour.
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(symbolColor)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
            } else {
                Image(systemName: "photo")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.secondary)
                    .padding(box * 0.2)
            }
        }
    }
}

/// The folder's front panel as a shape: what artwork is cut off at, so it never
/// goes over the back of the folder or the white page. Fill a square frame the
/// size of the folder picture with it.
struct FolderPanelShape: Shape {
    func path(in rect: CGRect) -> Path {
        let panel = FolderPanel.rect(in: rect.width).offsetBy(dx: rect.minX, dy: rect.minY)
        let radius = FolderPanel.cornerRadius * rect.width / FolderPanel.picture
        return Path(roundedRect: panel, cornerRadius: radius, style: .continuous)
    }
}

/// The folder with its artwork drawn on, no handles. This is also what is turned
/// into the icon that goes on the folder, so what you see is what you get.
struct FolderCompositeView: View {
    let base: NSImage
    let artworks: [FolderArtwork]
    let side: CGFloat

    var body: some View {
        let panel = FolderPanel.rect(in: side)
        ZStack(alignment: .topLeading) {
            Image(nsImage: base)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)

            // Artwork is cut off at the edge of the front panel.
            ZStack(alignment: .topLeading) {
                ForEach(artworks) { artwork in
                    FolderArtworkContent(artwork: artwork, box: CGFloat(artwork.size) * panel.height)
                        .position(
                            x: panel.midX + CGFloat(artwork.x) * panel.width,
                            y: panel.midY + CGFloat(artwork.y) * panel.height
                        )
                }
            }
            .frame(width: side, height: side)
            .clipShape(FolderPanelShape())
        }
        .frame(width: side, height: side)
    }
}

/// The editor's canvas: the folder with artwork you can select, move and resize.
/// Dragging snaps to the middle of the panel, with a guide line while it holds.
struct FolderArtworkCanvas: View {
    let base: NSImage
    let side: CGFloat
    @Binding var artworks: [FolderArtwork]
    @Binding var selectedID: UUID?
    /// Called when a change is finished, so the editor can remember it for undo.
    var onCommit: () -> Void = {}
    var onDuplicate: (UUID) -> Void = { _ in }
    var onRecenter: (UUID) -> Void = { _ in }
    var onDelete: (UUID) -> Void = { _ in }
    var onMoveUp: (UUID) -> Void = { _ in }
    var onMoveDown: (UUID) -> Void = { _ in }
    var onRemoveColor: (UUID) -> Void = { _ in }
    var onDoubleTap: (UUID) -> Void = { _ in }

    @State private var moveStart: (id: UUID, x: Double, y: Double)?
    @State private var snappedX = false
    @State private var snappedY = false

    /// How close to the middle, in points, counts as "on" the middle.
    private let snapDistance: CGFloat = 6
    private let spaceName = "folderCanvas"
    private let corners = [CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1), CGPoint(x: -1, y: 1), CGPoint(x: 1, y: 1)]

    private var panel: CGRect {
        FolderPanel.rect(in: side)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: base)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                .onTapGesture { selectedID = nil }

            // Artwork is cut off at the edge of the front panel; its handles are not.
            ZStack(alignment: .topLeading) {
                ForEach(artworks) { artwork in
                    artworkView(artwork, handles: false)
                }
            }
            .frame(width: side, height: side)
            .clipShape(FolderPanelShape())

            ForEach(artworks) { artwork in
                artworkView(artwork, handles: true)
            }

            if snappedX {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: 1, height: panel.height)
                    .position(x: panel.midX, y: panel.midY)
                    .allowsHitTesting(false)
            }
            if snappedY {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: panel.width, height: 1)
                    .position(x: panel.midX, y: panel.midY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: side, height: side)
        .coordinateSpace(name: spaceName)
    }

    // MARK: - One piece of artwork

    /// One piece of artwork is drawn in two layers: the picture, which is cut off at
    /// the panel's edge, and its selection box and handles, which are not.
    private func artworkView(_ artwork: FolderArtwork, handles: Bool) -> some View {
        let box = CGFloat(artwork.size) * panel.height
        let boxSize = FolderArtworkContent.frameSize(for: artwork, box: box)
        let center = CGPoint(
            x: panel.midX + CGFloat(artwork.x) * panel.width,
            y: panel.midY + CGFloat(artwork.y) * panel.height
        )
        let isSelected = selectedID == artwork.id

        return ZStack {
            if !handles {
                FolderArtworkContent(artwork: artwork, box: box, rotates: false)
                    .contentShape(Rectangle())
                    .gesture(moveGesture(for: artwork))
                    .onTapGesture { selectedID = artwork.id }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap(artwork.id) })
                    .contextMenu {
                        Button("Duplicate") { onDuplicate(artwork.id) }
                            .keyboardShortcut("d", modifiers: .command)
                        Button("Recenter") { onRecenter(artwork.id) }
                        if artwork.kind == .image, artwork.colorHex != nil {
                            Button("Remove Colour") { onRemoveColor(artwork.id) }
                        }
                        Divider()
                        Button("Bring Forward") { onMoveUp(artwork.id) }
                            .keyboardShortcut(.upArrow, modifiers: .command)
                            .disabled(artwork.id == artworks.last?.id)
                        Button("Send Backward") { onMoveDown(artwork.id) }
                            .keyboardShortcut(.downArrow, modifiers: .command)
                            .disabled(artwork.id == artworks.first?.id)
                        Divider()
                        Button("Delete", role: .destructive) { onDelete(artwork.id) }
                            .keyboardShortcut(.delete, modifiers: [])
                        Divider()
                        Button("Confirm position") { selectedID = nil }
                            .keyboardShortcut(.return, modifiers: [])
                    }
            }

            if handles, isSelected {
                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1)
                    .frame(width: boxSize.width, height: boxSize.height)
                    .allowsHitTesting(false)

                ForEach(corners, id: \.self) { corner in
                    handle(for: artwork, corner: corner, size: boxSize, center: center)
                }
                rotateHandle(for: artwork, boxHeight: boxSize.height, center: center)
            }
        }
        .rotationEffect(.degrees(artwork.angle))
        // A little room around the artwork, so the corner handles can be grabbed.
        .frame(width: boxSize.width + 80, height: boxSize.height + 80)
        .position(center)
    }

    private func handle(for artwork: FolderArtwork, corner: CGPoint, size: CGSize, center: CGPoint) -> some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
            .frame(width: 11, height: 11)
            .offset(x: corner.x * size.width / 2, y: corner.y * size.height / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(spaceName))
                    .onChanged { value in
                        // The pointer is measured in the artwork's own, turned, frame.
                        let turn = -artwork.angle * Double.pi / 180
                        let dx = Double(value.location.x - center.x)
                        let dy = Double(value.location.y - center.y)
                        let localX = dx * cos(turn) - dy * sin(turn)
                        let localY = dx * sin(turn) + dy * cos(turn)
                        // How far the pointer is from the centre, compared with the corner now.
                        let scale = max(abs(localX) / Double(size.width / 2), abs(localY) / Double(size.height / 2))
                        let newSize = artwork.size * scale
                        update(artwork.id) { $0.size = min(max(newSize, 0.06), 1.3) }
                    }
                    .onEnded { _ in onCommit() }
            )
    }

    /// The round handle above the selected artwork. Drag it to turn the artwork;
    /// hold Shift to turn in 15-degree steps.
    private func rotateHandle(for artwork: FolderArtwork, boxHeight: CGFloat, center: CGPoint) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.accentColor.opacity(0.8))
                .frame(width: 1, height: 14)
                .offset(y: -(boxHeight / 2 + 7))
                .allowsHitTesting(false)

            Circle()
                .fill(Color.accentColor)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                .frame(width: 11, height: 11)
                .offset(y: -(boxHeight / 2 + 20))
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(spaceName))
                        .onChanged { value in
                            let dx = Double(value.location.x - center.x)
                            let dy = Double(value.location.y - center.y)
                            var degrees = atan2(dx, -dy) * 180 / Double.pi
                            if NSEvent.modifierFlags.contains(.shift) {
                                degrees = (degrees / 15).rounded() * 15
                            }
                            if degrees <= -180 { degrees += 360 }
                            update(artwork.id) { $0.rotation = abs(degrees) < 0.05 ? nil : degrees }
                        }
                        .onEnded { _ in onCommit() }
                )
        }
    }

    private func moveGesture(for artwork: FolderArtwork) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(spaceName))
            .onChanged { value in
                if moveStart?.id != artwork.id {
                    moveStart = (artwork.id, artwork.x, artwork.y)
                    selectedID = artwork.id
                    // Holding Option leaves a copy where it was, under the one being moved.
                    if NSEvent.modifierFlags.contains(.option),
                       let index = artworks.firstIndex(where: { $0.id == artwork.id }) {
                        var copy = artworks[index]
                        copy.id = UUID()
                        artworks.insert(copy, at: index)
                    }
                }
                guard let start = moveStart else { return }

                var x = start.x + Double(value.translation.width / panel.width)
                var y = start.y + Double(value.translation.height / panel.height)

                snappedX = abs(x) * Double(panel.width) < Double(snapDistance)
                snappedY = abs(y) * Double(panel.height) < Double(snapDistance)
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
