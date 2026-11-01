import AppKit
import QuickLookThumbnailing

/// Draws the system's own folder in any colour.
///
/// The folder itself comes from macOS, so the shape, the paper sheet, the
/// gradient and the shadow are Apple's. Recolouring keeps all of that shading:
/// it swaps the hue and scales saturation and brightness. Checked against
/// macOS's own red folder, this matches it to within a rounding error.
enum FolderRecolor {
    /// The colour the folder's front panel should have in its mid-tones.
    struct Tint: Equatable {
        var hue: Double          // 0...1
        var saturation: Double   // 0...1
        var value: Double        // 0...1
    }

    /// What the stock blue folder's front panel measures, so that a tint can be
    /// turned into "how much more or less saturated and bright than that".
    private static let referenceSaturation = 0.646
    private static let referenceValue = 0.883
    /// Pixels less saturated than this - the white paper, the shadow - keep their colour.
    private static let minimumSaturation = 0.12

    // MARK: - The system folder

    /// The system folder at `pixels` x `pixels`, as macOS draws it. It is asked
    /// for through QuickLook, which waits for the real artwork instead of
    /// answering with a placeholder.
    static func baseImage(pixels: Int) async -> CGImage? {
        if let cached = cache.image(for: pixels) { return cached }

        let fm = FileManager.default
        let folder = fm.temporaryDirectory
            .appendingPathComponent("studio-folder-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? fm.removeItem(at: folder) }
        // macOS draws the white paper sheet only on a folder that has something in
        // it, and an empty one is drawn without. The icon is a fixed picture, so it
        // always gets the sheet: the folder holds one small file while it is drawn.
        fm.createFile(atPath: folder.appendingPathComponent("studio.txt").path, contents: Data("x".utf8))

        let request = QLThumbnailGenerator.Request(
            fileAt: folder,
            size: CGSize(width: pixels, height: pixels),
            scale: 1,
            representationTypes: .icon
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = representation.cgImage
        cache.store(image, for: pixels)
        return image
    }

    /// The folder in `tint`, or the plain system folder when `tint` is nil.
    static func render(pixels: Int, tint: Tint?) async -> NSImage? {
        guard let base = await baseImage(pixels: pixels) else { return nil }
        var result = base
        if let tint {
            guard let colored = recolored(base, tint: tint) else { return nil }
            result = colored
        }
        return NSImage(cgImage: result, size: NSSize(width: pixels, height: pixels))
    }

    // MARK: - Recolouring

    static func recolored(_ base: CGImage, tint: Tint) -> CGImage? {
        let width = base.width
        let height = base.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        let saturationScale = tint.saturation / referenceSaturation
        let valueScale = tint.value / referenceValue

        for index in 0..<(width * height) {
            let p = pixels + index * 4
            let alpha = Double(p[3]) / 255
            if alpha == 0 { continue }

            // The bytes are premultiplied by alpha; work on the true colour.
            let r = min(1, Double(p[0]) / 255 / alpha)
            let g = min(1, Double(p[1]) / 255 / alpha)
            let b = min(1, Double(p[2]) / 255 / alpha)

            let top = max(r, g, b)
            if top == 0 { continue }
            let saturation = (top - min(r, g, b)) / top
            if saturation < minimumSaturation { continue }

            let (nr, ng, nb) = rgb(
                hue: tint.hue,
                saturation: min(1, saturation * saturationScale),
                value: min(1, top * valueScale)
            )
            p[0] = UInt8(min(255, nr * alpha * 255 + 0.5))
            p[1] = UInt8(min(255, ng * alpha * 255 + 0.5))
            p[2] = UInt8(min(255, nb * alpha * 255 + 0.5))
        }
        return context.makeImage()
    }

    private static func rgb(hue: Double, saturation s: Double, value v: Double) -> (Double, Double, Double) {
        let scaled = (hue - floor(hue)) * 6
        let sector = Int(scaled) % 6
        let f = scaled - floor(scaled)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch sector {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    // MARK: - Cache

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [Int: CGImage] = [:]

        func image(for pixels: Int) -> CGImage? {
            lock.lock()
            defer { lock.unlock() }
            return images[pixels]
        }

        func store(_ image: CGImage, for pixels: Int) {
            lock.lock()
            defer { lock.unlock() }
            images[pixels] = image
        }
    }

    private static let cache = Cache()
}

// MARK: - Tint conversions

extension FolderRecolor.Tint {
    init(color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        self.init(hue: Double(h), saturation: Double(s), value: Double(b))
    }

    /// From "#RRGGBB".
    init?(hex: String) {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let number = Int(text, radix: 16) else { return nil }
        let color = NSColor(
            srgbRed: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
        self.init(color: color)
    }

    var nsColor: NSColor {
        NSColor(hue: CGFloat(hue), saturation: CGFloat(saturation), brightness: CGFloat(value), alpha: 1)
    }

    /// "#RRGGBB"
    var hex: String {
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        return String(
            format: "#%02X%02X%02X",
            Int((c.redComponent * 255).rounded()),
            Int((c.greenComponent * 255).rounded()),
            Int((c.blueComponent * 255).rounded())
        )
    }
}
