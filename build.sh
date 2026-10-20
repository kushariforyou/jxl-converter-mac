#!/bin/zsh
# Builds "JXL Converter.app" into ./build
set -euo pipefail
cd "$(dirname "$0")"
APP="build/JXL Converter.app"
rm -rf "$APP" build/icon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# SwiftUI's @State macro plugin ships with Xcode, not the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  for x in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    [[ -d "$x" ]] && { export DEVELOPER_DIR="$x/Contents/Developer"; break; }
  done
fi

xcrun swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
  Sources/*.swift -o "$APP/Contents/MacOS/JXLConverter"

swift scripts/make_icon.swift build/icon.iconset
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>JXL Converter</string>
  <key>CFBundleDisplayName</key><string>JXL Converter</string>
  <key>CFBundleIdentifier</key><string>local.jxlconverter</string>
  <key>CFBundleExecutable</key><string>JXLConverter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Image or Folder</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.image</string><string>public.folder</string></array>
  </dict></array>
</dict></plist>
PLIST

codesign --force --deep -s - "$APP"
echo "Built $APP"
