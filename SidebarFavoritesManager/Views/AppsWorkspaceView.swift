import SwiftUI

/// The Apps list. The icon editor is built on top of this later.
struct AppsWorkspaceView: View {
    var body: some View {
        IconListWorkspaceView(
            config: IconListConfig(
                kind: .app,
                title: "Application Icons",
                emptySymbol: "app.dashed",
                emptyTitle: "No Apps",
                emptyMessage: "Add apps to export their icons or give them a new one",
                addHelp: "Add App",
                exportHelp: "Export icon as .icns",
                revealHelp: "Show in Finder"
            )
        )
    }
}
