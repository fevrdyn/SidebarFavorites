import SwiftUI
import UniformTypeIdentifiers

struct AddEditFavoriteSheet: View {
    let existingFavorite: Favorite?
    let onSave: (Favorite) -> Void

    /// Persist, rebuild and restart Finder without dismissing - see `apply()`.
    /// Returns a message when something went wrong, because the window's own error
    /// alert sits behind this sheet and would never be seen. Optional so a caller
    /// that has nothing to apply against (the SwiftUI preview) can omit it.
    let onApply: ((Favorite) async -> String?)?

    /// Called by Cancel and Save. The editor lives inside the main window now, so
    /// closing it means "stop showing it", not "dismiss a sheet" - `dismiss()` here
    /// would close the whole window.
    var closeAction: () -> Void = {}

    /// Drawn in the middle of the footer; the studio shell puts the workspace
    /// switcher here.
    var footerCenter: AnyView = AnyView(EmptyView())

    func closing(_ action: @escaping () -> Void) -> AddEditFavoriteSheet {
        var copy = self
        copy.closeAction = action
        return copy
    }

    func withFooterCenter<V: View>(_ view: V) -> AddEditFavoriteSheet {
        var copy = self
        copy.footerCenter = AnyView(view)
        return copy
    }

    @State private var name: String = ""
    @State private var folderPath: String = ""
    @State private var locationsOnly: Bool = false

    /// How the sidebar glyph is delivered - see `Favorite.Mode`. Advanced adds
    /// a per-favorite Finder Sync helper so the folder may keep its own icon.
    @State private var mode: Favorite.Mode = .regular

    @State private var showingSymbolBrowser = false

    /// The target's own icon is removed when the sheet is saved, not when the
    /// button is pressed - deleting a user's artwork on a click they might
    /// still cancel out of is not a thing to do.
    @State private var iconRemovalRequested = false

    /// Locations only makes sense for a mounted volume, so the toggle is offered
    /// only when the chosen path is one.
    private var targetIsVolume: Bool {
        let expanded = (folderPath as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return false }
        return (try? URL(fileURLWithPath: expanded).resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }

    /// The custom icon this target carries itself, when it has one. Present means
    /// the sidebar icon will keep vanishing until it is dealt with.
    @State private var iconAuthority: IconAuthority.Detection?

    /// Where its icon was backed up to, once removed - shown so the user knows a
    /// copy exists and where.
    @State private var iconAuthorityBackup: URL?
    @State private var iconAuthorityError: String?
    @State private var iconType: Favorite.IconType = .sfSymbol
    @State private var iconValue: String = "folder.fill"
    @State private var customSVGPath: String?

    /// Optical size correction for a custom icon, as a fraction. Drives the
    /// preview directly and nothing else until the user commits: see `apply()`
    /// for why this deliberately does not persist as it moves.
    @State private var iconScale: Double = Favorite.defaultIconScale

    /// Identity of the favorite this sheet edits, decided once.
    ///
    /// Needed as its own piece of state because Apply can persist a *new* favorite
    /// while the sheet is still open: every later Apply, and the final Save, have
    /// to land on that same favorite rather than inserting another one.
    @State private var favoriteID = UUID()

    /// The form as it was last written to disk, or nil for a favorite that has
    /// never been written. What Apply compares against to know whether there is
    /// anything to do.
    @State private var appliedSnapshot: FormSnapshot?

    /// True while an Apply is in flight. Latched around the whole await so a
    /// second click cannot queue a second `actool` run behind the first.
    @State private var isApplying = false

    @State private var showingSVGPicker = false
    @State private var validationErrors: [SymbolValidator.ValidationError] = []
    @State private var showingValidationError = false
    @State private var operationError: String?

    /// What the imported SVG produced: the previews built from its artwork, and
    /// anything the user should know about what was dropped or flattened.
    /// Rebuilt whenever the icon selection changes.
    @State private var artworkWarnings: [String] = []
    @State private var sidebarPreview: NSImage?
    @State private var enlargedPreview: NSImage?

    /// The parsed artwork behind the previews, held so the size slider can
    /// re-render without going back to the file. Reading and parsing an SVG on
    /// every tick of a continuous slider is exactly the kind of work this control
    /// must not do.
    @State private var artwork: SymbolValidator.Artwork?

    /// The size Finder actually draws a sidebar icon at.
    private let sidebarIconSize: CGFloat = 16
    private let enlargedIconSize: CGFloat = 35

    private var isEditing: Bool { existingFavorite != nil }

    /// Whether the favorite exists in the config - which it does from the first
    /// successful Apply onwards, even in the Add sheet. Only decides wording.
    private var isPersisted: Bool { isEditing || appliedSnapshot != nil }

    init(favorite: Favorite?,
         onApply: ((Favorite) async -> String?)? = nil,
         onSave: @escaping (Favorite) -> Void) {
        self.existingFavorite = favorite
        self.onApply = onApply
        self.onSave = onSave
    }

    /// Everything on this form that ends up in the favorite.
    ///
    /// Compared against the last state actually written so Apply can tell "there
    /// is a change waiting" from "nothing to do" - and, because it is taken from
    /// the favorite that was written rather than from the live form, so a slider
    /// nudged during a rebuild is not mistaken for having been applied.
    private struct FormSnapshot: Equatable {
        let name: String
        let folderPath: String
        let iconType: Favorite.IconType
        let iconValue: String
        let customSVGPath: String?
        let iconScale: Double
        // Both were once missing here, which left Apply disabled for a change
        // that only touched them - every field `buildFavorite` writes belongs
        // in this comparison.
        let locationsOnly: Bool
        let mode: Favorite.Mode

        init(_ favorite: Favorite) {
            self.init(
                name: favorite.name,
                folderPath: favorite.folderPath,
                iconType: favorite.iconType,
                iconValue: favorite.iconValue,
                customSVGPath: favorite.customSVGPath,
                iconScale: favorite.iconScale,
                locationsOnly: favorite.locationsOnly,
                mode: favorite.mode
            )
        }

        init(name: String,
             folderPath: String,
             iconType: Favorite.IconType,
             iconValue: String,
             customSVGPath: String?,
             iconScale: Double,
             locationsOnly: Bool,
             mode: Favorite.Mode) {
            self.name = name
            self.folderPath = folderPath
            self.iconType = iconType
            self.iconValue = iconValue
            self.customSVGPath = customSVGPath
            self.iconScale = iconScale
            self.locationsOnly = locationsOnly
            self.mode = mode
        }
    }

    private var snapshot: FormSnapshot {
        FormSnapshot(
            name: name,
            folderPath: folderPath,
            iconType: iconType,
            iconValue: iconValue,
            customSVGPath: customSVGPath,
            // Through the model's clamp, so this compares equal to the snapshot
            // taken from a saved favorite rather than differing by a rounding.
            iconScale: Favorite.clampedIconScale(iconScale),
            locationsOnly: locationsOnly,
            mode: mode
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Plain content when it fits - nothing to scroll or bounce. Only if
            // extra warnings make it taller than the window does it fall back
            // to a scroll view.
            ViewThatFits(in: .vertical) {
                editorContent
                ScrollView { editorContent }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()

            footerBar
        }
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
        .onChange(of: folderPath) { newPath in
            name = Favorite.canonicalName(forFolderPath: newPath)
            refreshIconAuthority(for: newPath)
        }
        .onAppear {
            if let favorite = existingFavorite {
                favoriteID = favorite.id
                // Derived, not read back: a config written by a build that let
                // the name be edited may still carry a custom one.
                name = Favorite.canonicalName(forFolderPath: favorite.folderPath)
                folderPath = favorite.folderPath
                // Editing an existing favorite: the target may have acquired its
                // own icon since it was added, which is worth saying here too.
                locationsOnly = favorite.locationsOnly
                mode = favorite.mode
                refreshIconAuthority(for: favorite.folderPath)
                iconType = favorite.iconType
                iconValue = favorite.iconValue
                customSVGPath = favorite.customSVGPath
                iconScale = favorite.iconScale
                // Opened on something already on disk, so there is nothing to
                // apply until the user changes something.
                appliedSnapshot = FormSnapshot(favorite)
            }
            #if DEBUG
            if existingFavorite == nil && ScreenshotMode.newFavoriteCustom { iconType = .custom }
            #endif
            refreshArtwork()
        }
        .onChange(of: customSVGPath) { _ in refreshArtwork() }
        .onChange(of: iconType) { _ in refreshArtwork() }
        // Redraw only. Nothing on this path reads the file, builds a template or
        // goes anywhere near `actool` - see `renderPreviews`.
        .onChange(of: iconScale) { _ in renderPreviews() }
        .fileImporter(
            isPresented: $showingSVGPicker,
            allowedContentTypes: [UTType(filenameExtension: "svg") ?? .svg],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    importCustomSVG(from: url)
                }
            case .failure(let error):
                operationError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingSymbolBrowser) {
            SymbolBrowserSheet(currentSymbol: iconValue) { picked in
                iconType = .sfSymbol
                iconValue = picked
                refreshArtwork()
            }
        }
        .alert("Can't Use This SVG", isPresented: $showingValidationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(validationErrorMessage)
        }
        .alert("Couldn't Complete", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
    }

    // MARK: - Apply

    /// Commit without closing, then relaunch Finder so the sidebar redraws.
    ///
    /// Tuning optical size is iterative and cannot be finished from the preview
    /// alone - the judgement is "does this sit right next to the other rows", and
    /// only Finder can answer that. Without this the loop is save, close, notice
    /// the banner, restart, reopen; with it, it is one button.
    private var applyButton: some View {
        Button(action: { Task { await apply() } }) {
            if isApplying {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Applying…")
                }
            } else {
                Text("Apply")
            }
        }
        .disabled(!canApply)
        .help("Saves this favorite and restarts Finder so the sidebar redraws, leaving this window open")
    }

    /// There has to be something to write, it has to be valid, and the last one
    /// has to have finished.
    private var canApply: Bool {
        isValid && appliedSnapshot != snapshot && !isApplying
    }

    private func apply() async {
        guard canApply, let onApply else { return }

        isApplying = true
        // Apply commits, so a pending removal is part of what it commits.
        performRequestedIconRemoval()
        // Built once, before the await: this exact value is what gets written and
        // what is recorded as applied, so moving the slider during the rebuild
        // cannot leave the form looking clean when it is not.
        let favorite = buildFavorite()
        let failure = await onApply(favorite)
        isApplying = false

        if let failure {
            operationError = failure
            return
        }
        appliedSnapshot = FormSnapshot(favorite)
    }

    // MARK: - Icon controls

    /// The symbol-name field edits SF Symbol names, so typing in it always means
    /// "use a system symbol" - even while a custom SVG is selected.
    private var symbolNameBinding: Binding<String> {
        Binding(
            get: { iconValue },
            set: { newValue in
                if iconType != .sfSymbol { iconType = .sfSymbol }
                iconValue = newValue
            }
        )
    }

    private var hasCustomSVG: Bool { iconType == .custom && customSVGPath != nil }

    /// Opens the file picker straight away. Once an SVG is in use it turns into a
    /// filled "Replace..." button in the accent colour.
    private var svgButton: some View {
        Button(action: { showingSVGPicker = true }) {
            Text(hasCustomSVG ? "Replace..." : "Custom SVG")
                .foregroundColor(hasCustomSVG ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hasCustomSVG ? Color.accentColor : Color.primary.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
        .help(hasCustomSVG
              ? "Using \((customSVGPath ?? "") as NSString).lastPathComponent). Click to choose a different SVG."
              : "Choose an SVG file to use as the icon")
    }

    private var quickPickGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
            ForEach(commonSymbols, id: \.self) { symbol in
                Button(action: {
                    iconType = .sfSymbol
                    iconValue = symbol
                }) {
                    Image(systemName: symbol)
                        .font(.system(size: 18))
                        .frame(width: 30, height: 30)
                        .background(iconType == .sfSymbol && iconValue == symbol
                                    ? Color.accentColor.opacity(0.2) : Color.clear)
                        .cornerRadius(6)
                }
                .buttonStyle(.borderless)
                .help(symbol)
            }
        }
    }

    /// Manual optical-size correction.
    ///
    /// Offered for imported artwork only. A system SF Symbol is drawn by macOS
    /// from Apple's own outlines, each one hand-tuned to sit right beside the
    /// others - there is nothing of ours to rescale, and a control that silently
    /// did nothing would be worse than no control.
    private var iconScaleControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Size")
                HelpTip("100% matches a system symbol\u{2019}s size. Lower it if the icon looks heavier than its neighbours.")
                Spacer(minLength: 0)
                Text(iconScalePercentText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    // Fixed width, so the slider does not shift sideways as the
                    // number goes from two digits to three while being dragged.
                    .frame(width: 40, alignment: .trailing)
                Button("Reset") {
                    iconScale = Favorite.defaultIconScale
                }
                .buttonStyle(.borderless)
                .disabled(isAtDefaultIconScale)
                .help("Back to 100%")
            }

            Slider(value: iconScaleSnapped, in: Favorite.iconScaleRange) {
                Text("Icon size")
            } minimumValueLabel: {
                Text("50%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } maximumValueLabel: {
                Text("150%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .labelsHidden()
        }
    }

    /// Snaps to whole percents without `Slider(step:)`, which makes macOS draw a
    /// tick mark for every step - a hundred of them - as a dotted line.
    private var iconScaleSnapped: Binding<Double> {
        Binding(
            get: { iconScale },
            set: { iconScale = ($0 * 100).rounded() / 100 }
        )
    }

    private var iconScalePercentText: String {
        "\(Int((Favorite.clampedIconScale(iconScale) * 100).rounded()))%"
    }

    private var isAtDefaultIconScale: Bool {
        abs(Favorite.clampedIconScale(iconScale) - Favorite.defaultIconScale) < 0.0005
    }

    private func warningRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(text)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    // MARK: - Footer

    /// Cancel on the left, Apply and Save on the right. Sized by an invisible copy
    /// of the main window's footer content, so the two bars are exactly the same
    /// height; the real buttons sit in an overlay, which cannot make it taller.
    private var footerBar: some View {
        HStack {
            Spacer()
            Button(action: {}) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .hidden()
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .overlay {
            HStack {
                // Deliberately not disabled while an Apply runs: the work is the
                // coordinator's and completes either way, and taking away the
                // escape hatch mid-operation is exactly when it is wanted most.
                Button("Cancel") {
                    closeAction()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if onApply != nil {
                    applyButton
                }

                Button(isPersisted ? "Save" : "Add") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isApplying)
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Layout blocks

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewBlock
            iconBlock
            modeBlock
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
    }

    private func sectionTitle(_ title: String, help: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.headline)
            if let help {
                HelpTip(help)
            }
        }
    }

    private var previewHelp: String {
        var text = "Left: your icon enlarged. Right: the sidebar row at real size, named after the folder."
        if iconType == .custom {
            text += " macOS draws sidebar icons in a single colour, so colour isn't possible."
        }
        return text
    }

    private var previewBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Preview", help: previewHelp)

            card {
                HStack(alignment: .top, spacing: 12) {
                    // Enlarged silhouette, so the user can see what survived.
                    previewIcon(customImage: enlargedPreview)
                        .frame(
                            width: previewWidth(for: enlargedPreview, height: enlargedIconSize),
                            height: enlargedIconSize
                        )
                        .foregroundColor(.primary)
                        .padding(14.5)
                        .frame(minWidth: 57, minHeight: 57)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(NSColor.textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.secondary.opacity(0.25))
                        )

                    VStack(spacing: 8) {
                        // The row as Finder will draw it: real size, real name.
                        // A real (read-only) text field, so it is exactly the
                        // same colour as the path field below it. The leading
                        // spaces leave room for the icon drawn on top.
                        TextField("", text: .constant(
                            String(repeating: " ", count: 6) + (name.isEmpty ? "Choose a folder" : name)
                        ))
                        .textFieldStyle(.roundedBorder)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Favorite name")
                        .overlay(alignment: .leading) {
                            previewIcon(customImage: sidebarPreview)
                                .frame(
                                    width: previewWidth(for: sidebarPreview, height: sidebarIconSize),
                                    height: sidebarIconSize
                                )
                                .foregroundColor(.accentColor)
                                .padding(.leading, 7)
                                .allowsHitTesting(false)
                        }

                        HStack(spacing: 8) {
                            TextField("Folder Path", text: $folderPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                openFolderPicker()
                            }
                        }
                    }
                }

                if targetIsVolume {
                    HStack(spacing: 6) {
                        Toggle("Show in Locations only", isOn: $locationsOnly)
                        HelpTip("Icon Finder\u{2019}s own Locations row instead of adding a second one under Favorites.")
                    }
                }

                if let conflict = conflictingFavorite {
                    Label("\u{201C}\(conflict.name)\u{201D} already uses this folder.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.callout)
                    Text("A folder can only have one favorite - two would fight over the same sidebar row. Edit \u{201C}\(conflict.name)\u{201D} instead, or choose a different folder.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let detection = iconAuthority {
                    ownIconWarning(detection)
                }

                // What the artwork lost on the way in. Below the preview: the user
                // sees the silhouette first, then reads why it looks the way it does.
                if iconType == .custom {
                    ForEach(artworkWarnings, id: \.self) { warning in
                        warningRow(warning)
                    }
                }
            }
        }
    }

    private var iconBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Icon", help: "Type an SF Symbol name, pick one below, browse the full list, or choose any SVG file.")

            card {
                HStack(spacing: 8) {
                    TextField("Symbol Name", text: symbolNameBinding)
                        .textFieldStyle(.roundedBorder)
                    if SymbolCatalog.isAvailable {
                        Button("Browse All...") { showingSymbolBrowser = true }
                            .help("Search every SF Symbol this Mac can draw")
                    }
                    svgButton
                }

                quickPickGrid

                if hasCustomSVG {
                    Divider()
                    iconScaleControl
                }
            }
        }
    }

    private var modeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Sidebar Icon Mode")

            card {
                HStack {
                    Text("Mode")
                    Spacer()
                    Picker("Mode", selection: $mode) {
                        Text("Sidebar icon only").tag(Favorite.Mode.regular)
                        Text("Both icons").tag(Favorite.Mode.advanced)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    // Hover over either option to see what it does.
                    .background(SegmentTooltips(
                        labels: ["Sidebar icon only", "Both icons"],
                        tips: [
                            "Sets the sidebar glyph only. Nothing runs in the background.",
                            "The folder keeps its own icon everywhere else (Desktop, windows, Dock). Adds a ~6 MB helper in System Settings."
                        ]
                    ))
                }
            }
        }
    }


    /// The width to give a preview slot `height` points tall.
    ///
    /// Taken from the rendered image, which already carries the compiled symbol's
    /// proportions and is already capped at the slot's allowance - so the slot
    /// hugs the artwork instead of letter-boxing it, and a square icon still gets
    /// a square box.
    private func previewWidth(for image: NSImage?, height: CGFloat) -> CGFloat {
        guard let image, image.size.height > 0, image.size.width > 0 else { return height }
        return height * (image.size.width / image.size.height)
    }

    /// - Parameter customImage: the synthesized template preview rendered at the
    ///   size this slot draws at. Ignored for SF Symbol icons.
    @ViewBuilder
    private func previewIcon(customImage: NSImage?) -> some View {
        if iconType == .custom {
            if let image = customImage {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "square.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(.secondary)
            }
        } else if isKnownSystemSymbol(iconValue) {
            Image(systemName: iconValue)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "questionmark.square.dashed")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.secondary)
        }
    }

    private func isKnownSystemSymbol(_ name: String) -> Bool {
        !name.isEmpty && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    // MARK: - Artwork loading

    /// Re-parse the selected SVG and rebuild both previews.
    ///
    /// Runs on the main thread: parsing an icon-sized SVG and rasterizing a 16 pt
    /// silhouette is sub-millisecond work, and doing it inline keeps the preview
    /// in step with the picker rather than flickering a frame behind it.
    private func refreshArtwork() {
        guard iconType == .custom, let relativePath = customSVGPath else {
            artwork = nil
            artworkWarnings = []
            renderPreviews()
            return
        }

        let url = ConfigManager.shared.customIconURL(relativePath: relativePath)
        let result = SymbolValidator.validate(at: url)

        // A stored icon can go bad between sessions (edited, truncated, replaced),
        // so a failure here is shown in place of the warnings rather than as an alert.
        artworkWarnings = result.isValid ? result.warnings : result.errors.map(describe)
        artwork = result.artwork
        renderPreviews()
    }

    /// Re-rasterize both previews from the artwork already in hand.
    ///
    /// Split out of `refreshArtwork` because this is what runs on every tick of
    /// the size slider, and what it must NOT do is as important as what it does:
    /// no file read, no XML parse, no template synthesis and above all no
    /// `actool`. Filling one cached `CGPath` into two small bitmaps is
    /// microseconds; compiling an asset catalog is not, and doing that per tick
    /// would run the compiler continuously for the length of a drag.
    private func renderPreviews() {
        guard iconType == .custom, let artwork else {
            sidebarPreview = nil
            enlargedPreview = nil
            return
        }
        sidebarPreview = templatePreview(artwork, size: sidebarIconSize)
        enlargedPreview = templatePreview(artwork, size: enlargedIconSize)
    }

    /// The **only** place in this file that names `SymbolTemplateSynthesizer`. If
    /// that type ships with a different call shape, this one function is what changes.
    private func templatePreview(_ artwork: SymbolValidator.Artwork, size: CGFloat) -> NSImage {
        let image = SymbolTemplateSynthesizer.previewImage(
            for: artwork.path,
            fillRule: artwork.fillRule,
            size: size,
            // The same number `buildFavorite` stores and the helper compiles with,
            // so what the user judges here is what Finder ends up drawing.
            iconScale: CGFloat(Favorite.clampedIconScale(iconScale)),
            // This sheet is where size is judged, so its previews get the room to
            // overhang that Finder gives a wide symbol. In a square slot a mark
            // wider than about 1.16:1 is width-bound and looks identical at every
            // setting of the slider - which would make the control appear broken
            // for precisely the artwork it exists to fix.
            slot: .overhanging
        )
        // Sidebar icons are templates; make sure the preview tints like one.
        image.isTemplate = true
        return image
    }

    // MARK: - Data

    private var commonSymbols: [String] {
        [
            "folder.fill",
            "folder.fill.badge.gearshape",
            "star.fill",
            "heart.fill",
            "bookmark.fill",
            "flag.fill",
            "tag.fill",
            "archivebox.fill",
            "tray.full.fill",
            "briefcase.fill",
            "doc.fill",
            "doc.text.fill",
            "book.fill",
            "books.vertical.fill",
            "magazine.fill",
            "newspaper.fill",
            "photo.fill",
            "camera.fill",
            "video.fill",
            "music.note",
            "waveform",
            "gamecontroller.fill",
            "terminal.fill",
            "hammer.fill"
        ]
    }

    /// "What went wrong" plus "what to do about it", as one sentence pair.
    private func describe(_ error: SymbolValidator.ValidationError) -> String {
        [error.errorDescription, error.recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private var validationErrorMessage: String {
        let lines = validationErrors.map(describe)
        return lines.isEmpty ? "This SVG can't be used as an icon." : lines.joined(separator: "\n\n")
    }

    /// The favorite already pointing at this folder, if there is one.
    ///
    /// Two favorites on one folder means two rows fighting over the same
    /// sidebar entry: the reconcile binds whichever it reaches first, the other
    /// reports itself unbound, and deleting either takes the shared row away.
    /// Comparing standardized paths, so `~/x`, `/Users/me/x` and `/Users/me/x/`
    /// are recognised as the same place.
    private var conflictingFavorite: Favorite? {
        let expanded = (folderPath as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        let target = URL(fileURLWithPath: expanded).standardizedFileURL.path
        return ConfigManager.shared.config.favorites.first { other in
            other.id != favoriteID
                && URL(fileURLWithPath: other.expandedFolderPath).standardizedFileURL.path == target
        }
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              !folderPath.trimmingCharacters(in: .whitespaces).isEmpty,
              conflictingFavorite == nil else {
            return false
        }
        switch iconType {
        case .sfSymbol:
            return !iconValue.isEmpty
        case .custom:
            return customSVGPath != nil
        }
    }

    // MARK: - Actions

    /// Warns that the target carries its own icon, and offers to remove it.
    ///
    /// Deliberately inline and non-blocking rather than an alert on save: it is a
    /// real choice, not an error, and the favorite works either way - the icon
    /// just needs re-applying whenever the target changes.
    @ViewBuilder
    private func ownIconWarning(_ detection: IconAuthority.Detection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if mode == .advanced {
                // The detection stops being a problem the moment the helper owns
                // the row - say so instead of warning about it.
                Label("This \(detection.isVolume ? "disk" : "folder") has its own icon — kept. The helper draws the sidebar glyph.", systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .font(.callout)
            } else {
                Label(detection.summary, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.callout)

                Text(detection.explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let backup = iconAuthorityBackup {
                    Text("Removed. A copy is in \(backup.deletingLastPathComponent().path).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if let error = iconAuthorityError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    // A selection, not three one-way actions. Nothing here takes
                    // effect until Save, so every option stays reachable:
                    // choosing "Remove its icon" and changing your mind was
                    // impossible when the click removed the icon on the spot.
                    // The selection is derived from the state it sets rather
                    // than stored beside it, so it can never disagree with the
                    // Mode control below.
                    Picker("", selection: iconChoiceBinding) {
                        Text("Keep both icons").tag(IconChoice.keepBoth)
                        Text("Remove its icon").tag(IconChoice.removeIcon)
                        Text("Leave as is").tag(IconChoice.leaveAsIs)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    Text(iconChoiceDetail(subject: detection.isVolume ? "disk" : "folder"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func refreshIconAuthority(for path: String) {
        iconAuthorityBackup = nil
        iconAuthorityError = nil
        // A request to remove belongs to the target it was made about.
        iconRemovalRequested = false
        let expanded = (path as NSString).expandingTildeInPath
        iconAuthority = expanded.isEmpty ? nil : IconAuthority.detect(atPath: expanded)
    }

    /// What to do about a target that carries its own icon.
    private enum IconChoice: Hashable {
        case keepBoth
        case removeIcon
        case leaveAsIs
    }

    /// Derived from the state each option sets, never stored alongside it - two
    /// copies of the same answer is how the picker and the Mode control came to
    /// disagree in the first place.
    private var iconChoiceBinding: Binding<IconChoice> {
        Binding(
            get: {
                if mode == .advanced { return .keepBoth }
                return iconRemovalRequested ? .removeIcon : .leaveAsIs
            },
            set: { choice in
                switch choice {
                case .keepBoth:
                    mode = .advanced
                    iconRemovalRequested = false
                case .removeIcon:
                    mode = .regular
                    iconRemovalRequested = true
                case .leaveAsIs:
                    mode = .regular
                    iconRemovalRequested = false
                }
            }
        )
    }

    private func iconChoiceDetail(subject: String) -> String {
        switch iconChoiceBinding.wrappedValue {
        case .keepBoth:
            return "Keeps this \(subject)'s icon and the sidebar glyph. Mode below switches to Both icons, which adds a helper (~6 MB) listed in System Settings."
        case .removeIcon:
            return "The sidebar glyph stays put. This \(subject) goes back to a plain icon everywhere. Removed when you save; a copy is kept, so you can put it back."
        case .leaveAsIs:
            return "Changes nothing. The sidebar glyph will keep disappearing whenever this \(subject) changes, until you press Refresh."
        }
    }

    /// Carries out a removal the user asked for earlier, at save time.
    ///
    /// Re-detects rather than trusting the detection captured when the sheet was
    /// drawn: the target may have changed since, and removing based on a stale
    /// reading would delete the wrong thing.
    private func performRequestedIconRemoval() {
        guard iconRemovalRequested else { return }
        iconRemovalRequested = false
        let expanded = (folderPath as NSString).expandingTildeInPath
        guard let detection = IconAuthority.detect(atPath: expanded) else { return }
        do {
            iconAuthorityBackup = try IconAuthority.remove(
                detection,
                backupDirectory: ConfigManager.shared.appSupportURL.appendingPathComponent("IconBackups")
            )
            iconAuthorityError = nil
            iconAuthority = nil
        } catch {
            iconAuthorityError = "Couldn't remove it: \(error.localizedDescription)"
            operationError = "Couldn't remove the folder's own icon: \(error.localizedDescription)"
        }
    }

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false  // Preserve symlink paths, don't resolve to target
        panel.message = "Select a folder to add to Finder sidebar"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            // The name follows via the form's onChange(of: folderPath).
            folderPath = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }

    private func importCustomSVG(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let result = SymbolValidator.validate(at: url)
        guard result.isValid else {
            validationErrors = result.errors
            showingValidationError = true
            return
        }

        do {
            let relativePath = try SymbolValidator.importSymbol(
                from: url,
                named: url.deletingPathExtension().lastPathComponent
            )
            // The stored file decides the symbol name - it may have been
            // de-duplicated against an icon another favorite already uses.
            customSVGPath = relativePath
            iconType = .custom
            iconValue = (relativePath as NSString).deletingPathExtension
            refreshArtwork()
        } catch {
            operationError = error.localizedDescription
        }
    }

    /// The favorite this form describes, laid over whatever is currently stored
    /// for it.
    ///
    /// Reading the stored copy back rather than editing `existingFavorite` is what
    /// makes Apply safe to press twice. The reconcile Apply triggers writes
    /// `osType`, the sidebar binding and `updatedAt` while this sheet is still
    /// open; a second Apply built from the favorite as it looked when the sheet
    /// opened would hand all of that back as it was, unbinding a row that is now
    /// live. The form owns exactly the fields it shows - everything else comes
    /// from the config, whatever the reconcile has made of it since.
    private func buildFavorite() -> Favorite {
        var favorite = ConfigManager.shared.getFavorite(id: favoriteID)
            ?? existingFavorite
            ?? Favorite(id: favoriteID, name: name, folderPath: folderPath)
        favorite.name = name
        favorite.folderPath = folderPath
        favorite.iconType = iconType
        favorite.iconValue = iconValue
        favorite.customSVGPath = customSVGPath
        favorite.iconScale = iconScale
        // A folder can never live in Locations, so the flag is not allowed to
        // survive re-pointing a favorite at one.
        favorite.locationsOnly = locationsOnly && targetIsVolume
        favorite.mode = mode
        favorite.markUpdated()
        return favorite
    }

    private func save() {
        // Before the favorite is written, so the reconcile that follows sees the
        // target as it will be rather than as it was.
        performRequestedIconRemoval()
        onSave(buildFavorite())
        closeAction()
    }
}
/// A small question mark in a circle. Hovering over it shows the explanation
/// in a popover, after a brief pause so it does not flash as the mouse passes.
struct HelpTip: View {
    let text: String
    @State private var isShown = false
    @State private var pendingShow: DispatchWorkItem?

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .contentShape(Rectangle())
            .onHover { hovering in
                pendingShow?.cancel()
                if hovering {
                    let item = DispatchWorkItem { isShown = true }
                    pendingShow = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
                } else {
                    isShown = false
                }
            }
            .popover(isPresented: $isShown, arrowEdge: .bottom) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 320, alignment: .leading)
                    .padding(12)
            }
            .accessibilityLabel("Help")
            .accessibilityHint(text)
    }
}

/// Gives each segment of a native segmented control its own hover tooltip.
/// SwiftUI has no way to do this, so the underlying NSSegmentedControl is
/// found by its segment labels and given the tooltips directly.
private struct SegmentTooltips: NSViewRepresentable {
    let labels: [String]
    let tips: [String]

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        // The control may not exist yet when this first runs, so try again shortly.
        for delay in [0.0, 0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                guard let root = view?.window?.contentView else { return }
                apply(in: root)
            }
        }
    }

    private func apply(in view: NSView) {
        if let control = view as? NSSegmentedControl,
           control.segmentCount == labels.count,
           (0..<labels.count).allSatisfy({ control.label(forSegment: $0) == labels[$0] }) {
            for (index, tip) in tips.enumerated() {
                control.setToolTip(tip, forSegment: index)
            }
            return
        }
        for subview in view.subviews {
            apply(in: subview)
        }
    }
}

#Preview {
    // The real window is 400 x 560 and the top 28 pt of it is the hidden title bar.
    AddEditFavoriteSheet(favorite: nil) { _ in }
        .frame(width: 400, height: 532)
}
