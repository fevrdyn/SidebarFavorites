import SwiftUI
import AppKit

/// What one piece of artwork looks like, drawn to fit a square of side `box`.
struct FolderArtworkContent: View {
    let artwork: FolderArtwork
    let box: CGFloat

    var body: some View {
        content
            .frame(width: box, height: box)
    }

    private var symbolColor: Color {
        if let hex = artwork.colorHex, let tint = FolderRecolor.Tint(hex: hex) {
            return Color(nsColor: tint.nsColor)
        }
        return Color.white.opacity(0.92)
    }

    @ViewBuilder
    private var content: some View {
        switch artwork.kind {
        case .symbol:
            Image(systemName: artwork.value)
                .resizable()
                .scaledToFit()
                .foregroundColor(symbolColor)
                .padding(box * 0.08)
                .shadow(color: Color.black.opacity(0.25), radius: box * 0.02, y: box * 0.01)
        case .emoji:
            Text(artwork.value)
                .font(.system(size: box * 0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.1)
        case .image:
            if let image = FolderArtworkStore.image(named: artwork.value) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
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

            ForEach(artworks) { artwork in
                FolderArtworkContent(artwork: artwork, box: CGFloat(artwork.size) * panel.height)
                    .position(
                        x: panel.midX + CGFloat(artwork.x) * panel.width,
                        y: panel.midY + CGFloat(artwork.y) * panel.height
                    )
            }
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

            ForEach(artworks) { artwork in
                artworkView(artwork)
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

    private func artworkView(_ artwork: FolderArtwork) -> some View {
        let box = CGFloat(artwork.size) * panel.height
        let center = CGPoint(
            x: panel.midX + CGFloat(artwork.x) * panel.width,
            y: panel.midY + CGFloat(artwork.y) * panel.height
        )
        let isSelected = selectedID == artwork.id

        return ZStack {
            FolderArtworkContent(artwork: artwork, box: box)
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
        // A little room around the artwork, so the corner handles can be grabbed.
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
                        let newSize = Double(reach * 2 / panel.height)
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
