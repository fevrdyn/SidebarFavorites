import AppKit

/// Takes an app's own artwork out of the app, so it can be placed on a new icon.
///
/// macOS 26 puts icons that were not made for it inside a grey squircle when it
/// draws them. The artwork inside the app is the bare picture without that
/// squircle, and that is what this reads: first the app's .icns file, then, for
/// apps that keep their icon in an asset catalogue, the image by its icon name.
enum AppArtworkExtractor {
    /// Returns the stored picture's name and a starting size (as a fraction of
    /// the icon body), or nil if the app's artwork could not be read.
    static func extract(from app: URL) -> (name: String, size: Double)? {
        guard let source = sourceImage(of: app), let prepared = prepare(source) else { return nil }

        let rep = NSBitmapImageRep(cgImage: prepared.image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".png")
        guard (try? data.write(to: temp)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let name = FolderArtworkStore.importImage(from: temp) else { return nil }
        return (name, prepared.size)
    }

    private static func sourceImage(of app: URL) -> CGImage? {
        guard let bundle = Bundle(url: app) else { return nil }

        if let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String, !name.isEmpty {
            let file = name.hasSuffix(".icns") ? name : name + ".icns"
            let url = app.appendingPathComponent("Contents/Resources", isDirectory: true).appendingPathComponent(file)
            if let image = NSImage(contentsOf: url), let cg = largest(in: image) { return cg }
        }
        if let iconName = bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String, !iconName.isEmpty,
           let image = bundle.image(forResource: NSImage.Name(iconName)), let cg = largest(in: image) {
            return cg
        }
        return nil
    }

    private static func largest(in image: NSImage) -> CGImage? {
        guard let rep = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }) else { return nil }
        let width = rep.pixelsWide > 0 ? rep.pixelsWide : 1024
        let height = rep.pixelsHigh > 0 ? rep.pixelsHigh : 1024
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        return rep.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// A picture with opaque corners is full-bleed art: it fills the icon. One with
    /// transparent corners is trimmed to its content. If that content nearly fills
    /// its canvas it is an icon with its own shape and fills the icon too; if it is
    /// smaller it is a glyph that floats, and starts at about 60% of the icon.
    /// These are starting sizes: the picture can be resized afterwards.
    private static func prepare(_ source: CGImage) -> (image: CGImage, size: Double)? {
        let width = source.width, height = source.height
        guard width > 8, height > 8,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * width + x) * 4 + 3] }
        let corners = [alpha(0, 0), alpha(width - 1, 0), alpha(0, height - 1), alpha(width - 1, height - 1)]
        guard let flat = context.makeImage() else { return nil }
        if corners.allSatisfy({ $0 > 240 }) { return (flat, 1.0) }

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alpha(x, y) > 16 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let trimmed = flat.cropping(to: box) else { return nil }
        let share = max(box.width, box.height) / CGFloat(max(width, height))
        return (trimmed, share >= 0.8 ? 1.0 : 0.6)
    }
}
