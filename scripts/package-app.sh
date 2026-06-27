#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Shodana"
APP_DIR=".build/release/${APP_NAME}.app"
EXECUTABLE=".build/release/${APP_NAME}"
ICON="Sources/Shodana/Resources/AppIcon.icns"
RESOURCE_BUNDLE=".build/release/${APP_NAME}_${APP_NAME}.bundle"

swift build -c release

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "${EXECUTABLE}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

if [[ -f "${ICON}" ]]; then
    cp "${ICON}" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

if [[ -d "${RESOURCE_BUNDLE}" ]]; then
    cp -R "${RESOURCE_BUNDLE}" "${APP_DIR}/"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>dev.masakifujisawa.shodana</string>
    <key>CFBundleName</key>
    <string>Shodana</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>Shodana URL</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>shodana</string>
                <string>mihako</string>
            </array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Folder</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
                <string>public.directory</string>
            </array>
        </dict>
    </array>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Shodana needs permission to open the current folder in Terminal or iTerm.</string>
</dict>
</plist>
PLIST

echo "${APP_DIR}"
