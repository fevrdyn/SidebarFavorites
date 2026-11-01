import SwiftUI

/// Hosts the favorite editor inside the main window.
///
/// The token is a string rather than an optional UUID, and `newFavoriteToken`
/// means "add". Cancel and Save live in the window's title strip; the editor
/// reports to the strip through `StudioNavigator`.
struct FavoriteEditorWindow: View {
    static let newFavoriteToken = "new"

    let token: String
    /// Called when the editor should go away (Cancel or Save).
    var onClose: () -> Void = {}

    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var coordinator: FavoriteSyncCoordinator

    /// The favorite being edited, read live from the config.
    private var favorite: Favorite? {
        guard token != Self.newFavoriteToken, let id = UUID(uuidString: token) else { return nil }
        return configManager.getFavorite(id: id)
    }

    var body: some View {
        AddEditFavoriteSheet(
            favorite: favorite,
            onApply: { updated in await persist(updated, restartFinder: true) }
        ) { updated in
            Task { _ = await persist(updated, restartFinder: false) }
        }
        .closing(onClose)
    }

    /// Writes the favorite and lets the coordinator reconcile it. The previous
    /// copy is read before the write so the coordinator can compare old with new.
    /// Failures are published on the coordinator, which the main window alerts on.
    @discardableResult
    private func persist(_ favorite: Favorite, restartFinder: Bool) async -> String? {
        let previous = configManager.getFavorite(id: favorite.id)
        do {
            if previous != nil {
                try configManager.updateFavorite(favorite)
            } else {
                try configManager.addFavorite(favorite)
            }
        } catch {
            coordinator.report(error: error.localizedDescription)
            return error.localizedDescription
        }

        if let previous {
            await coordinator.favoriteUpdated(favorite, previous: previous)
        } else {
            await coordinator.favoriteAdded(favorite)
        }

        if restartFinder {
            await coordinator.restartFinderAndWait()
            return coordinator.lastError
        }
        return nil
    }
}
