#!/bin/sh
# Builds MetaScrub.app into build/. Uses Xcode's toolchain when Xcode is installed (the Command Line
# Tools here don't include the macOS 26 SDK that SwiftUI's Liquid Glass needs).
set -eu
cd "$(dirname "$0")"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun swift build -c release --product MetaScrub
bin="$(xcrun swift build -c release --show-bin-path)/MetaScrub"
app="build/MetaScrub.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/MetaScrub"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"; fi
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MetaScrub</string>
  <key>CFBundleDisplayName</key><string>MetaScrub</string>
  <key>CFBundleIdentifier</key><string>local.metascrub.app</string>
  <key>CFBundleExecutable</key><string>MetaScrub</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Any File</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.data</string><string>public.content</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
# Ad-hoc signature: enough for a local app; not for distribution.
codesign --force --sign - "$app"
echo "Built $(pwd)/$app"
