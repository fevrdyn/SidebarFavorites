import SwiftUI

/// The Folders list. The icon editor is built on top of this later.
struct FoldersWorkspaceView: View {
    var body: some View {
        IconListWorkspaceView(
            config: IconListConfig(
                kind: .folder,
                title: "Custom Folders",
                emptySymbol: "folder.badge.gearshape",
                emptyTitle: "No Folders",
                emptyMessage: "Add folders to export their icons or give them a new one",
                addHelp: "Add Folder",
                exportHelp: "Export icon as PNG",
                revealHelp: "Show in Finder"
            )
        )
    }
}
