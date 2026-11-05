import AppKit

/// One piece of artwork on a folder: a symbol, an emoji or a picture.
struct FolderArtwork: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case symbol
        case emoji
        case image
    }

    var id = UUID()
    var kind: Kind
    /// The symbol's name, the emoji itself, or - for a picture - the name of the
    /// copy kept in the artwork folder.
    var value: String
    /// Where its centre is, measured from the centre of the front panel, in panel
    /// widths and heights. 0, 0 is dead centre.
    var x: Double = 0
    var y: Double = 0
    /// The side of the square it sits in, as a fraction of the panel's height.
    var size: Double = 0.45
    /// A symbol's colour as "#RRGGBB". Nil means the default soft white.
    var colorHex: String?
}

/// Where the folder's front panel sits on the 1024 px picture of the folder.
/// These numbers are approximate. If artwork looks off-centre on the panel, or
/// can be dragged past its edge, this is the place to adjust them.
enum FolderPanel {
    static let left: CGFloat = 42
    static let top: CGFloat = 268
    static let right: CGFloat = 982
    static let bottom: CGFloat = 890
    static let picture: CGFloat = 1024

    /// The panel inside a picture whose side is `side`. Origin at the top left.
    static func rect(in side: CGFloat) -> CGRect {
        let scale = side / picture
        return CGRect(
            x: left * scale,
            y: top * scale,
            width: (right - left) * scale,
            height: (bottom - top) * scale
        )
    }
}

/// Pictures the user brought in, kept as PNG copies so the original can move or
/// be deleted without breaking the folder's design.
enum FolderArtworkStore {
    private static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ThemingStudio/Artwork", isDirectory: true)
    }

    private static let cache = NSCache<NSString, NSImage>()

    static func image(named name: String) -> NSImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let image = NSImage(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    /// Copies a picture in as a PNG of at most 1024 px on its long side.
    /// Returns the stored name, or nil if the file could not be read as a picture.
    static func importImage(from url: URL) -> String? {
        guard let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else { return nil }

        // A bitmap keeps its own size; a vector picture (SVG, PDF) is drawn at 1024.
        let bitmapSide = source.representations.compactMap { rep -> CGFloat? in
            rep is NSBitmapImageRep ? CGFloat(max(rep.pixelsWide, rep.pixelsHigh)) : nil
        }.max()
        let longSide = min(1024, bitmapSide ?? 1024)
        let aspect = source.size.width / source.size.height
        let pixelsWide = max(1, Int((aspect >= 1 ? longSide : longSide * aspect).rounded()))
        let pixelsHigh = max(1, Int((aspect >= 1 ? longSide / aspect : longSide).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: pixelsWide, height: pixelsHigh)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh),
                    from: .zero, operation: .sourceOver, fraction: 1)

        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = UUID().uuidString + ".png"
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? data.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
        return name
    }

    /// Deletes every stored picture that no folder uses any more.
    static func removeUnused(keeping used: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where !used.contains(file.lastPathComponent) {
            try? fm.removeItem(at: file)
        }
    }
}
