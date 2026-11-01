import SwiftUI
import ServiceManagement

// Debug builds enter through DebugEntry (Debug/ScreenshotMode.swift), which hands over
// to this App unless the offscreen screenshot mode was asked for.
#if !DEBUG
@main
#endif
struct SidebarFavoritesManagerApp: App {
    @StateObject private var configManager = ConfigManager.shared
    @StateObject private var coordinator = FavoriteSyncCoordinator.shared
    @State private var showingAddSheet = false

    init() {
        // Warm the menu bar icon store so custom icons are ready before the menu first opens.
        _ = MenuBarIconStore.shared
    }

    var body: some Scene {
        Window("Sidebar Favorites", id: "main") {
            StudioShellView(showingAddSheet: $showingAddSheet)
                .environmentObject(configManager)
                .environmentObject(coordinator)
        }
        .windowStyle(.hiddenTitleBar)
        // `.contentSize` pinned the window to its content, so a list longer than
        // the window could only be scrolled, never given more room.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 400, height: 560)
        .commands {
            AppCommands(showingAddSheet: $showingAddSheet)
        }

        Settings {
            SettingsView()
                .environmentObject(configManager)
        }

        // Menu bar icon - always visible, controlled by isInserted
        MenuBarExtra("SidebarFavorites", systemImage: "sidebar.left", isInserted: .constant(configManager.config.settings.showInMenuBar)) {
            MenuBarView()
                .environmentObject(configManager)
                .environmentObject(coordinator)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Menu commands that need access to app-level state, kept separate from the App's
/// scene body so `Cmd-N` reaches the same `showingAddSheet` binding `ContentView` reads.
struct AppCommands: Commands {
    @Binding var showingAddSheet: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Favorite...") {
                // The editor lives inside the main window; bring that window forward.
                StudioNavigator.shared.editorToken = FavoriteEditorWindow.newFavoriteToken
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}
