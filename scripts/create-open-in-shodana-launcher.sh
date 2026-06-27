#!/usr/bin/env bash
set -euo pipefail

TARGET_PATH="${1:-${HOME}/Downloads}"
OUTPUT_APP="${2:-.build/Shodana Downloads.app}"

TARGET_URL=$(/usr/bin/python3 - "${TARGET_PATH}" <<'PYTHON'
import os
import sys
from urllib.parse import urlencode

path = os.path.abspath(os.path.expanduser(sys.argv[1]))
print("shodana://open?" + urlencode({"path": path}))
PYTHON
)

mkdir -p "$(dirname "${OUTPUT_APP}")"
rm -rf "${OUTPUT_APP}"

ESCAPED_TARGET_URL=${TARGET_URL//\\/\\\\}
ESCAPED_TARGET_URL=${ESCAPED_TARGET_URL//\"/\\\"}

APP_BASENAME=$(basename "${OUTPUT_APP}" .app)

mkdir -p "${OUTPUT_APP}/Contents/MacOS"

cat > "${OUTPUT_APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>launcher</string>
    <key>CFBundleIdentifier</key>
    <string>dev.masakifujisawa.shodana.launcher.$(echo "${APP_BASENAME}" | tr -cd '[:alnum:]')</string>
    <key>CFBundleName</key>
    <string>${APP_BASENAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST

cat > "${OUTPUT_APP}/Contents/MacOS/launcher" <<SH
#!/usr/bin/env bash
open "${ESCAPED_TARGET_URL}"
SH

chmod +x "${OUTPUT_APP}/Contents/MacOS/launcher"

echo "${OUTPUT_APP}"
