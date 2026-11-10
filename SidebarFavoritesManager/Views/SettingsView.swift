import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var configManager: ConfigManager
    @State private var launchAtLogin: Bool = false
    @State private var launchAtLoginCaption: String?
    // Last-known system value for launchAtLogin, recorded whenever we read it from
    // SMAppService. A programmatic sync always leaves launchAtLogin == this value, so
    // onChange can tell a real user edit (which differs) from its own assignment (which
    // doesn't) without depending on when SwiftUI happens to deliver onChange.
    @State private var systemLaunchAtLogin = false
    @State private var showInMenuBar: Bool = true

    @State private var settingsErrorMessage: String?
    @State private var removeAllSidebarIconsMessage: String?
    // Gates removeAllSidebarIcons() behind an explicit confirm. The existing
    // "Remove All Sidebar Icons" alert (removeAllSidebarIconsMessage) is a report
    // shown *after* the work is done - this is the confirmation shown *before*.
    @State private var showingRemoveAllSidebarIconsConfirmation = false
    // Re-entrancy guard, matching AddEditFavoriteSheet.isApplying and
    // ContentView.deletingFavoriteIDs: without it, a repeat tap (or a second
    // confirm) while a prior removeAllSidebarIcons() Task is still awaiting the
    // coordinator starts an overlapping run. Both would write the single
    // @State removeAllSidebarIconsMessage, so whichever finishes last silently
    // overwrites the other's result text.
    @State private var isRemovingAllSidebarIcons = false
    @State private var diagnosticsCopied = false
    // studio-storage: state
    @State private var storageSize: Int64 = 0
    @State private var confirmRemoveAllFolders = false
    @State private var confirmRemoveAllApps = false
    @State private var isRemovingStudioIcons = false
    @State private var studioRemovalMessage: String?
    @ObservedObject private var studioStore = StudioIconStore.shared

    /// Live PlugInKit state per advanced favorite - the "permissions" panel.
    @State private var helperStatuses: [UUID: FinderSyncAppGenerator.HelperStatus] = [:]

    var body: some View {
        ScrollView {
            // studio-settings: body
            VStack(alignment: .leading, spacing: 18) { // studio-settings2: card spacing
                generalBlock
                aboutBlock
                if !advancedFavorites.isEmpty {
                    helpersBlock
                }
                storageBlock
                actionsBlock
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .scrollDisabled(true)
        // Fixed size. Nothing scrolls, so settingsHeight must be tall enough for the content.
        .frame(width: 440, height: settingsHeight) // studio-settings3: fixed size
        // Esc closes it, like every other sheet in the app.
        .background(DismissOnEscape())
        .onExitCommand { NSApp.keyWindow?.close() }
        // studio-storage: dialogs
        .confirmationDialog(
            "Remove All Folder Icons?",
            isPresented: $confirmRemoveAllFolders,
            titleVisibility: .visible
        ) {
            Button("Remove All Folder Icons", role: .destructive) {
                removeStudioIcons(.folder)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(studioRemovalConfirmationMessage(.folder))
        }
        .confirmationDialog(
            "Remove All App Icons?",
            isPresented: $confirmRemoveAllApps,
            titleVisibility: .visible
        ) {
            Button("Remove All App Icons", role: .destructive) {
                removeStudioIcons(.app)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(studioRemovalConfirmationMessage(.app))
        }
        .alert(
            "Icons Removed",
            isPresented: Binding(
                get: { studioRemovalMessage != nil },
                set: { if !$0 { studioRemovalMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { studioRemovalMessage = nil }
        } message: {
            Text(studioRemovalMessage ?? "")
        }
        .onAppear {
            showInMenuBar = configManager.config.settings.showInMenuBar
            syncLaunchAtLoginFromSystem()
            refreshHelperStatuses()
            refreshStorageSize() // studio-storage: onAppear
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncLaunchAtLoginFromSystem()
        }
        .alert(
            "Couldn't Save Settings",
            isPresented: Binding(
                get: { settingsErrorMessage != nil },
                set: { if !$0 { settingsErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { settingsErrorMessage = nil }
        } message: {
            Text(settingsErrorMessage ?? "")
        }
        .alert(
            "Remove All Sidebar Icons",
            isPresented: Binding(
                get: { removeAllSidebarIconsMessage != nil },
                set: { if !$0 { removeAllSidebarIconsMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { removeAllSidebarIconsMessage = nil }
        } message: {
            Text(removeAllSidebarIconsMessage ?? "")
        }
        // The confirmation shown BEFORE removeAllSidebarIcons() runs. States exactly
        // what will happen, since the action is irreversible (rows the app added are
        // deleted outright, not trashed) and sits right below "Restart Finder" with
        // only red text distinguishing it.
        .confirmationDialog(
            "Remove All Sidebar Icons?",
            isPresented: $showingRemoveAllSidebarIconsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove All Sidebar Icons", role: .destructive) {
                removeAllSidebarIcons()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeAllSidebarIconsConfirmationMessage)
        }
    }

    /// Describes the concrete effect of removeAllSidebarIcons() using the current
    /// favorites, so the confirmation names counts instead of speaking abstractly.
    private var removeAllSidebarIconsConfirmationMessage: String {
        let favorites = configManager.config.favorites
        let managedCount = favorites.filter { $0.sidebarProvenance == .managed }.count
        let adoptedCount = favorites.filter { $0.sidebarProvenance == .adopted }.count

        var lines: [String] = []
        if managedCount > 0 {
            lines.append(managedCount == 1
                ? "Removes 1 row this app added to Finder's sidebar."
                : "Removes \(managedCount) rows this app added to Finder's sidebar.")
        }
        if adoptedCount > 0 {
            lines.append(adoptedCount == 1
                ? "Clears the custom icon on 1 row you added yourself; the row stays in Finder."
                : "Clears the custom icon on \(adoptedCount) rows you added yourself; the rows stay in Finder.")
        }
        lines.append("Deletes the icon helper bundle.")
        lines.append("This cannot be undone.")
        return lines.joined(separator: "\n")
    }

    // studio-settings: layout blocks

    /// The window's fixed height; the content scrolls if it is taller.
    private var settingsHeight: CGFloat {
        let base: CGFloat = 520
        guard !advancedFavorites.isEmpty else { return base }
        return min(base + 130 + CGFloat(advancedFavorites.count) * 40, 900)
    }

    /// Same look as the favorite editor's cards: 12 pt between blocks, 10 pt padding.
    private func settingsBlock<Content: View>(
        _ title: String? = nil,
        trailing: String? = nil,
        info: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                HStack {
                    Text(title)
                        .font(.headline)
                    if let info {
                        // studio-settings4: info icon
                        Image(systemName: "questionmark.circle")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .help(info)
                    }
                    Spacer()
                    if let trailing {
                        // studio-settings2: trailing (lines up with the button's right edge)
                        Text(trailing)
                            .font(.headline)
                            .padding(.trailing, 8)
                    }
                }
                .padding(.horizontal, 2)
            }
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
        }
    }

    private var generalBlock: some View {
        settingsBlock {
            HStack {
                Text("Launch at Login")
                Spacer()
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small) // studio-settings3: switch 1
                    .onChange(of: launchAtLogin) { newValue in
                        // Only react when the toggle differs from the last value we read
                        // from the system - that's what distinguishes a user edit from a
                        // programmatic sync, regardless of when onChange is delivered.
                        guard newValue != systemLaunchAtLogin else { return }
                        setLaunchAtLogin(newValue)
                    }
            }

            if let caption = launchAtLoginCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack {
                Text("Show in Menu Bar")
                Spacer()
                Toggle("Show in Menu Bar", isOn: $showInMenuBar)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small) // studio-settings3: switch 2
                    .onChange(of: showInMenuBar) { _ in
                        updateSettings()
                    }
            }
        }
    }

    private var aboutBlock: some View {
        settingsBlock("About") {
            aboutHeader

            Divider()

            HStack {
                Text("Version")
                Spacer()
                Text(versionString)
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack(spacing: 12) {
                Text("Helper App")
                    .fixedSize()
                Spacer(minLength: 0)
                Button(action: openHelperAppLocation) {
                    Text({
                        #if DEBUG
                        return ScreenshotMode.displayPath(configManager.helperAppURL.path)
                        #else
                        return configManager.helperAppURL.path
                        #endif
                    }())
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .buttonStyle(.link)
            }

            if let diagnostic = configManager.loadDiagnostic {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Configuration Issue", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(diagnostic)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if configManager.corruptBackupURL != nil {
                        Button("Reveal Backup") {
                            revealCorruptBackup()
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private var helpersBlock: some View {
        settingsBlock("Finder Sync Helpers") {
            ForEach(Array(advancedFavorites.enumerated()), id: \.element.id) { index, favorite in
                if index > 0 {
                    Divider()
                }
                helperRow(favorite)
            }

            Divider()

            Text("Each Both-icons favorite runs one helper (~6 MB). Helpers appear in System Settings as \u{201C}SBF-\u{2026}\u{201D} with this app's icon.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Open Extensions Settings") {
                    FinderSyncAppGenerator.openExtensionsSettings()
                }
                Spacer()
                Button("Refresh Status") {
                    refreshHelperStatuses()
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var storageBlock: some View {
        settingsBlock(
            "Storage",
            trailing: "Used: \(StudioStorage.formatted(storageSize))",
            info: "Rendered icons, artwork, original and sidebar icon files. Unused removed automatically."
        ) {
            HStack(spacing: 10) {
                Text(StudioStorage.displayPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                Button("Open Folder") {
                    NSWorkspace.shared.open(StudioStorage.folder)
                }
                .help("Opens the Studio's data folder in Finder.")
            }
        }
    }

    private var actionsBlock: some View {
        settingsBlock("Actions") {
            HStack {
                Button("Restart Finder") {
                    FavoriteSyncCoordinator.shared.restartFinder()
                }
                .buttonStyle(.bordered)
                .tint(.orange)

                // studio-settings2: copy left
                Button(diagnosticsCopied ? "Diagnostics Copied" : "Copy Diagnostics") {
                    copyDiagnostics()
                }
                .help("Copies a plain-text report of your favorites and Finder's sidebar rows, for a GitHub issue. It includes your folder paths.")

                Spacer() // studio-settings2: spacer
            }

            Divider()

            HStack(spacing: 8) {
                Text("Remove all icons:")
                    .foregroundColor(.secondary)

                Button("Sidebar") {
                    showingRemoveAllSidebarIconsConfirmation = true
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isRemovingAllSidebarIcons)
                .help("Removes every sidebar icon this app added to Finder's sidebar. Asks first.")

                Button("Folder") {
                    confirmRemoveAllFolders = true
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isRemovingStudioIcons || studioIconsOn(.folder).isEmpty)
                .help("Switches off every custom folder icon and puts the original folder icons back. Your designs stay in the list. Asks first.")

                Button("Applications") {
                    confirmRemoveAllApps = true
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isRemovingStudioIcons || studioIconsOn(.app).isEmpty)
                .help("Switches off every custom icon on your applications and puts the original icons back. Your designs stay in the list. Asks first.")
            }
        }
    }

    // MARK: - Finder Sync helper status

    private var advancedFavorites: [Favorite] {
        configManager.config.favorites.filter { $0.mode == .advanced }
    }

    @ViewBuilder
    private func helperRow(_ favorite: Favorite) -> some View {
        let status = helperStatuses[favorite.id]
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(FinderSyncAppGenerator.displayName(for: favorite))
                    .font(.callout)
                Text(statusText(status))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if status == .disabled || status == .notRegistered {
                Button("Fix…") {
                    FinderSyncAppGenerator.openExtensionsSettings()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    private func statusColor(_ status: FinderSyncAppGenerator.HelperStatus?) -> Color {
        switch status {
        case .enabled: return .green
        case .disabled: return .orange
        case .notRegistered: return .red
        case nil: return .secondary.opacity(0.4)
        }
    }

    private func statusText(_ status: FinderSyncAppGenerator.HelperStatus?) -> String {
        switch status {
        case .enabled: return "Enabled — the helper draws this row's sidebar icon"
        case .disabled: return "Disabled in System Settings — the regular sidebar icon is shown"
        case .notRegistered: return "Not registered — the regular sidebar icon is shown"
        case nil: return "Checking…"
        }
    }

    private func refreshHelperStatuses() {
        let favorites = configManager.config.favorites
        Task {
            helperStatuses = await FinderSyncAppGenerator.shared.helperStatuses(for: favorites)
        }
    }

    /// App icon, name and attribution at the top of the About section.
    private var aboutHeader: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text("SidebarFavorites")
                    .font(.headline)
                Text("by IVG-Design")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button("MIT License") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/ivg-design/SidebarFavorites/blob/main/LICENSE")!
                    )
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// "1.0.0 (10)" - the marketing version with the build number, so a bug
    /// report can name the exact build rather than just the release.
    private var versionString: String { AppVersion.display }

    /// Reads the authoritative launch-at-login state from `SMAppService` and reconciles
    /// both the toggle and the persisted config with it, rather than trusting whatever was
    /// last written to config.json (which can drift if changed in System Settings).
    private func syncLaunchAtLoginFromSystem() {
        let status = SMAppService.mainApp.status
        let systemEnabled: Bool
        switch status {
        case .enabled:
            systemEnabled = true
            launchAtLoginCaption = nil
        case .requiresApproval:
            systemEnabled = true
            launchAtLoginCaption = "Waiting for approval in System Settings → Login Items"
        case .notRegistered, .notFound:
            systemEnabled = false
            launchAtLoginCaption = nil
        @unknown default:
            systemEnabled = false
            launchAtLoginCaption = nil
        }

        systemLaunchAtLogin = systemEnabled
        launchAtLogin = systemEnabled

        if configManager.config.settings.launchAtLogin != systemEnabled {
            var settings = configManager.config.settings
            settings.launchAtLogin = systemEnabled
            do {
                try configManager.updateSettings(settings)
            } catch {
                settingsErrorMessage = "Couldn't save Launch at Login setting: \(error.localizedDescription)"
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            var settings = configManager.config.settings
            settings.launchAtLogin = enabled
            try configManager.updateSettings(settings)
        } catch {
            settingsErrorMessage = "Couldn't change Launch at Login: \(error.localizedDescription)"
        }
        // Re-read the authoritative system state regardless of success or failure so the
        // toggle always reflects reality instead of whatever the user just picked.
        syncLaunchAtLoginFromSystem()
    }

    /// Read-only: builds the report off the main thread (it reads Finder's list
    /// and the helper's declarations) and puts it on the pasteboard.
    private func copyDiagnostics() {
        let favorites = configManager.config.favorites
        Task {
            let report = await Task.detached { DiagnosticsReport.make(favorites: favorites) }.value
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            diagnosticsCopied = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            diagnosticsCopied = false
        }
    }

    private func updateSettings() {
        do {
            var settings = configManager.config.settings
            settings.showInMenuBar = showInMenuBar
                try configManager.updateSettings(settings)
        } catch {
            settingsErrorMessage = "Couldn't save settings: \(error.localizedDescription)"
        }
    }

    private func openHelperAppLocation() {
        NSWorkspace.shared.selectFile(configManager.helperAppURL.path, inFileViewerRootedAtPath: configManager.appSupportURL.path)
    }

    private func revealCorruptBackup() {
        NSWorkspace.shared.selectFile(
            configManager.corruptBackupURL?.path,
            inFileViewerRootedAtPath: configManager.appSupportURL.path
        )
    }

    // studio-storage: helpers
    private func refreshStorageSize() {
        Task {
            let size = await Task.detached(priority: .utility) { StudioStorage.folderSize() }.value
            storageSize = size
        }
    }

    /// Folders or apps whose designed icon is on right now.
    private func studioIconsOn(_ kind: StudioIconItem.Kind) -> [StudioIconItem] {
        studioStore.items(of: kind).filter { $0.isCustomIconOn }
    }

    private func studioRemovalConfirmationMessage(_ kind: StudioIconItem.Kind) -> String {
        let count = studioIconsOn(kind).count
        let what = kind == .folder ? "folder" : "app"
        let noun = count == 1 ? what : what + "s"
        return "\(count) \(noun) in your list \(count == 1 ? "has" : "have") a custom icon switched on. "
            + "This switches \(count == 1 ? "it" : "them") off and puts the original icon back. "
            + "Your designs stay in the list, so you can switch them on again."
    }

    private func removeStudioIcons(_ kind: StudioIconItem.Kind) {
        guard !isRemovingStudioIcons else { return }
        let targets = studioIconsOn(kind)
        guard !targets.isEmpty else { return }
        isRemovingStudioIcons = true
        Task {
            for item in targets {
                if kind == .folder {
                    await FolderIconApplier.setEnabled(false, for: item, store: StudioIconStore.shared)
                } else {
                    await AppIconApplier.setEnabled(false, for: item, store: StudioIconStore.shared)
                }
            }
            let remaining = studioIconsOn(kind).count
            let noun = kind == .folder ? "folder" : "app"
            studioRemovalMessage = remaining == 0
                ? "Switched off the custom icon on \(targets.count) \(noun)\(targets.count == 1 ? "" : "s")."
                : "\(remaining) of \(targets.count) could not be switched off. See apply.log in the Studio folder."
            isRemovingStudioIcons = false
            refreshStorageSize()
        }
    }

    private func removeAllSidebarIcons() {
        // Ignore a repeat tap (or a second confirm reached some other way) while a
        // prior run is still in flight, rather than starting an overlapping
        // FavoriteSyncCoordinator.removeAllSidebarIcons() call that would race the
        // first one to `removeAllSidebarIconsMessage`.
        guard !isRemovingAllSidebarIcons else { return }
        isRemovingAllSidebarIcons = true
        Task {
            // removeAllSidebarIcons() runs its blocking work (sidebar patches, helper
            // teardown, Finder restart) off the main actor internally and only
            // suspends here - it does not block the UI.
            let warnings = await FavoriteSyncCoordinator.shared.removeAllSidebarIcons()
            removeAllSidebarIconsMessage = warnings.isEmpty
                ? "All sidebar icons were removed."
                : "Some sidebar icons could not be fully removed:\n\n" + warnings.joined(separator: "\n")
            isRemovingAllSidebarIcons = false
        }
    }
}

/// Makes Esc close the Settings window.
///
/// SwiftUI's Settings scene has no Cancel button for `.cancelAction` to bind to,
/// and `onExitCommand` alone does not fire for a window whose focus sits in a
/// Form control - so this installs a local key monitor for the window it lands in.
private struct DismissOnEscape: NSViewRepresentable {
    final class Coordinator {
        var monitor: Any?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 53 is Esc. Only claim the event when it belongs to this window.
            guard event.keyCode == 53, let window = view.window, window.isKeyWindow else {
                return event
            }
            window.close()
            return nil
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

#Preview {
    SettingsView()
        .environmentObject(ConfigManager.shared)
}
