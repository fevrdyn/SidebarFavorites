import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing

/// Writes an icon out as a PNG (folders) or an .icns file (apps).
///
/// The icon is asked for through QuickLook's thumbnail service, which waits until
/// macOS has the real artwork ready. Asking `NSWorkspace` and drawing straight
/// away returns macOS's grey dashed placeholder for the big sizes while the real
/// icon is still loading - that is what an export used to contain.
enum IconExporter {
    struct ExportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Asks where to save, then exports. Shows an alert if anything goes wrong.
    static func export(_ item: StudioIconItem) {
        guard item.isLinked else {
            alert("This \(item.kind == .app ? "app" : "folder") can't be found, so there is no icon to export.")
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        switch item.kind {
        case .app:
            panel.allowedContentTypes = [UTType(filenameExtension: "icns") ?? .data]
            panel.nameFieldStringValue = "\(item.displayName).icns"
            panel.message = item.hasAppDesign ? "Export your designed icon as an .icns file" : "Export the app's current icon as an .icns file"
        case .folder:
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "\(item.displayName).png"
            panel.message = "Export the folder's current icon as a 1024 px PNG"
        }

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let url = item.url
        let kind = item.kind
        let appItem = item
        Task { @MainActor in
            do {
                switch kind {
                case .app:
                    if appItem.hasAppDesign {
                        try await writeICNS(designOf: appItem, to: destination)
                    } else {
                        try await writeICNS(for: url, to: destination)
                    }
                case .folder: try await writePNG(for: url, pixels: 1024, to: destination)
                }
            } catch {
                alert(error.localizedDescription)
            }
        }
    }

    // MARK: - Getting the icon

    /// The icon macOS currently shows for `url`, at `pixels` x `pixels`.
    static func icon(for url: URL, pixels: Int) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pixels, height: pixels),
            scale: 1,
            representationTypes: .icon
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return NSImage(cgImage: representation.cgImage, size: NSSize(width: pixels, height: pixels))
    }

    /// Last resort if QuickLook cannot produce the icon.
    private static func fallbackIcon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Writing

    static func writePNG(for url: URL, pixels: Int, to destination: URL) async throws {
        let image = await icon(for: url, pixels: pixels) ?? fallbackIcon(for: url)
        try writePNG(image, pixels: pixels, to: destination)
    }

    /// Builds the standard 10-image iconset and lets Apple's `iconutil` pack it.
    /// Each size is requested separately, so the small ones keep the sharper
    /// artwork macOS draws for them instead of being shrunk from the big one.
    static func writeICNS(for url: URL, to destination: URL) async throws {
        var images: [Int: NSImage] = [:]
        for pixels in [16, 32, 64, 128, 256, 512, 1024] {
            images[pixels] = await icon(for: url, pixels: pixels) ?? fallbackIcon(for: url)
        }

        try packICNS(images, to: destination)
    }

    /// The icon designed in the Apps editor, drawn fresh at each size.
    static func writeICNS(designOf item: StudioIconItem, to destination: URL) async throws {
        var images: [Int: NSImage] = [:]
        for pixels in [16, 32, 64, 128, 256, 512, 1024] {
            guard let image = await AppIconRenderer.render(item, pixels: pixels) else {
                throw ExportError(message: "The icon could not be drawn.")
            }
            images[pixels] = image
        }
        try packICNS(images, to: destination)
    }

    private static func packICNS(_ images: [Int: NSImage], to destination: URL) throws {
        let fm = FileManager.default
        let iconset = fm.temporaryDirectory
            .appendingPathComponent("studio-\(UUID().uuidString).iconset", isDirectory: true)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iconset) }

        let files: [(name: String, pixels: Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
        ]
        for file in files {
            guard let image = images[file.pixels] else { continue }
            try writePNG(image, pixels: file.pixels, to: iconset.appendingPathComponent(file.name))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", "-o", destination.path, iconset.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ExportError(message: "iconutil failed. \(text)")
        }
    }

    private static func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
        guard let data = pngData(image, pixels: pixels) else {
            throw ExportError(message: "The icon could not be rendered.")
        }
        try data.write(to: url, options: .atomic)
    }

    private static func pngData(_ image: NSImage, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        // One point per pixel, so the image is drawn at exactly `pixels` wide.
        rep.size = NSSize(width: pixels, height: pixels)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                   from: .zero, operation: .sourceOver, fraction: 1)
        return rep.representation(using: .png, properties: [:])
    }

    private static func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Export failed"
        alert.informativeText = message
        alert.runModal()
    }
}
