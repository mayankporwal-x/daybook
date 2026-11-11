#!/bin/bash
# Builds Daybook.app (native SwiftUI planner) from Sources/*.swift.
# Needs only the Command Line Tools (swiftc, codesign); no Xcode project.
#
#   ./build.sh            → ./Daybook.app
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/Daybook.app"
MIN_MACOS="14.0"
BUNDLE_ID="local.daybook.app"
VERSION="3.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

shopt -s nullglob
SOURCES=("$DIR"/Sources/*.swift)
shopt -u nullglob
[ ${#SOURCES[@]} -gt 0 ] || { echo "error: no Swift files in $DIR/Sources" >&2; exit 1; }

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "Compiling ${#SOURCES[@]} Swift file(s)…"
swiftc -parse-as-library -swift-version 5 -O \
  -target "$(uname -m)-apple-macos$MIN_MACOS" \
  -framework SwiftUI -framework AppKit \
  -o "$APP/Contents/MacOS/Daybook" "${SOURCES[@]}"

cp "$DIR/tools/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Daybook</string>
  <key>CFBundleDisplayName</key><string>Daybook</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Daybook</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign - "$APP" || echo "warning: codesign failed" >&2
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
touch "$APP"
echo "Built $APP"
