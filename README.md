# Mihako

Better Finder: a macOS file manager prototype that keeps the broad feel of Finder while bringing in Explorer-style file management.

- Direct path entry in an address bar
- Clickable breadcrumbs for folder hierarchy
- Back, forward, and parent-folder navigation
- Dense details view for business file handling
- Icon view for quick visual browsing
- Sidebar locations for Google Drive, OneDrive, SharePoint-style CloudStorage folders, mounted drives, and NAS/network volumes
- Practical context menus
- Copy, cut, paste, rename, duplicate, trash, new folder, new file, copy-path, and reveal actions
- Open folders in Terminal or iTerm from sidebar, file, and folder context menus
- Connect to SMB/NAS paths through the system server connection flow

## Run

```sh
swift run Mihako
```

## Build an app bundle

```sh
scripts/package-app.sh
open .build/release/Mihako.app
```
