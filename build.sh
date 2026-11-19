#!/bin/bash
# Builds MacMark.app next to this script: the Swift window and machine
# reader, with the web canvas (web/) in its Resources. Needs the Xcode
# command line tools (xcode-select --install).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
app="$here/MacMark.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O -o "$app/Contents/MacOS/MacMark" "$here"/Sources/*.swift \
  -framework AppKit -framework WebKit -framework IOKit -framework SystemConfiguration -framework CoreServices
cp -R "$here/web" "$app/Contents/Resources/web"
[[ -f $here/Icon/MacMark.icns ]] && cp "$here/Icon/MacMark.icns" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacMark</string>
  <key>CFBundleDisplayName</key><string>MacMark</string>
  <key>CFBundleIdentifier</key><string>io.github.macmark</string>
  <key>CFBundleExecutable</key><string>MacMark</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>MacMark</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1 || true
# The app is made anew each build: tell Finder and the Dock, or they keep
# showing the old (or a blank) icon from their cache.
touch "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" >/dev/null 2>&1 || true
echo "Built $app"
