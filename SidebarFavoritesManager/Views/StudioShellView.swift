import SwiftUI

/// Shared sizes, so the workspaces line up.
enum StudioMetrics {
    static let headerHeight: CGFloat = 54

    /// The strip along the top of the window, level with the traffic-light buttons.
    /// Content starts below it. If everything below the strip jumps up or down
    /// compared with before, this is the number to adjust.
    static let titleStripHeight: CGFloat = 28

    /// The workspace switcher: its height, and its distance from the window's top edge.
    static let switcherHeight: CGFloat = 24
    static let switcherTop: CGFloat = 43

    /// Cancel and Save in the editor: distance from the window's top and right
    /// edges, and the gap between the two buttons.
    static let editorButtonsTop: CGFloat = 12
    static let editorButtonsRight: CGFloat = 17
    static let editorButtonsGap: CGFloat = 16
}

/// The three workspaces of the studio, in the order the switcher shows them.
enum StudioWorkspace: String, CaseIterable, Identifiable {
    case apps = "Apps"
    case sidebar = "Sidebar"
    case folders = "Folders"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .sidebar: return "sidebar.left"
        case .folders: return "folder"
        }
    }
}

/// Icon-only switcher, drawn in SwiftUI. It is styled like the "Sidebar Icon
/// Mode" buttons: a rounded track with the selected segment filled in the accent colour.
struct WorkspaceSwitcher: View {
    @Binding var selection: StudioWorkspace

    var body: some View {
        let all = StudioWorkspace.allCases
        HStack(spacing: 0) {
            ForEach(Array(all.enumerated()), id: \.element) { index, workspace in
                let isSelected = selection == workspace
                Button {
                    selection = workspace
                } label: {
                    Image(systemName: workspace.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isSelected ? .white : .secondary)
                        .frame(width: 30, height: StudioMetrics.switcherHeight - 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? Color.accentColor : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(workspace.rawValue)
                .accessibilityLabel(workspace.rawValue)
                .accessibilityAddTraits(isSelected ? .isSelected : [])

                // A thin line between two segments, hidden next to the selected one.
                if index < all.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.2))
                        .frame(width: 1, height: 12)
                        .opacity(isSelected || selection == all[index + 1] ? 0 : 1)
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.1))
        )
    }
}

/// Shared state between the window shell and the editor.
final class StudioNavigator: ObservableObject {
    static let shared = StudioNavigator()

    /// Which favorite the in-window editor shows. `nil` means the list.
    @Published var editorToken: String?
    /// The folder item the folder editor shows. `nil` means the list.
    @Published var folderEditorItemID: UUID?

    // The editor reports here so the shell can show its Cancel and Save.
    @Published var editorCanSave = false
    @Published var editorSaveTitle = "Save"
    var editorSave: () -> Void = {}
    var editorCancel: () -> Void = {}
}

/// Top-level window content: an empty strip along the top, then one workspace
/// at a time, or the editor over them. The switcher and the editor's buttons
/// are drawn over the strip, pinned to the window's top edge.
struct StudioShellView: View {
    @Binding var showingAddSheet: Bool
    @State private var selection: StudioWorkspace = .sidebar
    @ObservedObject private var navigator = StudioNavigator.shared

    private var sidebarVisible: Bool {
        selection == .sidebar && navigator.editorToken == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: StudioMetrics.titleStripHeight)

            ZStack {
                // The Sidebar workspace stays alive while hidden, so its update
                // check, alerts and banners are not reset by every tab switch.
                SidebarWorkspaceView(showingAddSheet: $showingAddSheet)
                    .opacity(sidebarVisible ? 1 : 0)
                    .allowsHitTesting(sidebarVisible)
                    .accessibilityHidden(!sidebarVisible)

                switch selection {
                case .sidebar:
                    EmptyView()
                case .folders:
                    FoldersWorkspaceView()
                        .opacity(navigator.folderEditorItemID == nil ? 1 : 0)
                        .allowsHitTesting(navigator.folderEditorItemID == nil)
                case .apps:
                    AppsWorkspaceView()
                }

                if let token = navigator.editorToken {
                    FavoriteEditorWindow(
                        token: token,
                        onClose: { navigator.editorToken = nil }
                    )
                    .id(token)
                }

                if let folderID = navigator.folderEditorItemID {
                    FolderEditorView(
                        itemID: folderID,
                        onClose: { navigator.folderEditorItemID = nil }
                    )
                    .id(folderID)
                }
            }
        }
        // The workspace switcher, centred along the top of the window.
        .overlay(alignment: .top) {
            if navigator.editorToken == nil && navigator.folderEditorItemID == nil {
                WorkspaceSwitcher(selection: $selection)
                    .padding(.top, StudioMetrics.switcherTop)
                    .offset(x: 44)
            }
        }
        // The strip sits in the title bar, so the content runs up to the window's top edge.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 400, maxWidth: .infinity,
               minHeight: 380 + StudioMetrics.titleStripHeight, maxHeight: .infinity)
        // Cmd-N from another tab should land on the editor, not behind it.
        .onChange(of: navigator.editorToken) { token in
            if token != nil { selection = .sidebar }
        }
    }
}
