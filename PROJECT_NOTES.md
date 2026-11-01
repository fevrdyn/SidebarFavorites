# Theming Studio - notes for whoever works on this next

A macOS icon-theming app built on the open-source SidebarFavorites (ivg-design). SwiftUI, macOS 13+,
Xcode 27, no paid certificate (ad-hoc signed, App Sandbox off). The user is not a coder: give complete
files or anchored patch scripts, never loose fragments to splice in by hand.

## The three workspaces (switcher pinned to the top of the window: Apps | Sidebar | Folders)
- **Sidebar** - the original app's list and editor (SidebarWorkspaceView, AddEditFavoriteSheet,
  FavoriteEditorWindow). Its logic must not be changed; it edits Finder's sidebar and shares config
  with any installed copy of the original app.
- **Folders** - IconListWorkspaceView + FolderEditorView. Done: list, colour palette, artwork
  (symbols, emoji, pictures) with move/resize/snap/undo, apply to the folder, on/off switch.
- **Apps** - list and export only. The editor (squircle in code, drop a PNG/SVG, render to .icns,
  apply) is NOT built yet.

## Files that matter (SidebarFavoritesManager/)
- StudioShellView.swift - window shell, workspace switcher, StudioNavigator (which editor is open).
- Models/StudioIconItem.swift - one app/folder in the Apps/Folders lists, saved to
  ~/Library/Application Support/ThemingStudio/icon-items.json (all new fields are OPTIONAL so older
  saves still load). Models/FolderArtwork.swift - artwork model, FolderPanel geometry (approximate!),
  copies of dropped pictures.
- Services/FolderRecolor.swift - gets the system folder from macOS (QuickLook, from a temp folder holding
  one file so the paper sheet shows) and recolours it: replace hue, scale saturation/brightness.
  Verified against macOS's own red folder.
- Services/FolderIconApplier.swift - puts the designed icon on a folder with NSWorkspace.setIcon and
  takes it off again (nil). Keeps a PNG cache. Writes an audit log to ThemingStudio/apply.log.
- Services/IconExporter.swift - exports a current icon as PNG / .icns (via QuickLook, then iconutil).
- Views/FolderArtworkViews.swift - artwork drawing + interactive canvas; the same view is rendered
  with ImageRenderer to make the real icon, so canvas and result match.

## Decisions already made
- No folder PNGs from the user: the folder comes from macOS. Native Tahoe folder colour/emoji skipped.
- Custom icons are plain bitmaps; the system Dark/Clear/Tinted styles do NOT apply to them.
- Switch off = setIcon(nil) = Finder's own icon; the design is kept (cache + settings) and the list
  row still shows it. App icons will not survive an app update -> needs a "reapply".
- Hand 512 pt images (1024 px at 2x) to setIcon, never 1024 pt (console: "Invalid image size").

## How to build and run (IMPORTANT - stale copies waste hours)
- The project is generated: edit files, then if files were ADDED/REMOVED run `xcodegen generate`
  (project.yml) with Xcode closed.
- Run `~/Desktop/run-studio-dev.sh`: builds as "Theming Studio Dev" with its own bundle ID so it can
  never be confused with the installed original. Do not rely on Cmd-R alone.
- There is no swiftc in the assistant's sandbox: code is reviewed by reading, brackets checked
  mechanically; the user's first build is the real test. Keep changes small and anchored.

## Known, accepted
- Finder only redraws a folder icon after the folder is selected (a modification-date nudge helps).
- Unexplained once: other custom folder icons were removed (cause never found; apply.log shows the app
  only touches folders in its list). Never call setIcon on a path that is not an item in the list.
