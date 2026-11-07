import SwiftUI
import AppKit

/// Draws an app's designed icon as a picture: the body and artwork, transparent
/// around the shape, with the shadow, like an icon made for macOS.
enum AppIconRenderer {
    static func render(_ item: StudioIconItem, pixels: Int) async -> NSImage? {
        await render(look: item.appLook ?? .dark, artworks: item.artwork ?? [], pixels: pixels)
    }

    static func render(look: AppIconLook, artworks: [FolderArtwork], pixels: Int) async -> NSImage? {
        await MainActor.run {
            let renderer = ImageRenderer(
                content: AppIconCompositeView(side: CGFloat(pixels), look: look, artworks: artworks)
            )
            renderer.scale = 1
            return renderer.nsImage
        }
    }
}
