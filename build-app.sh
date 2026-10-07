#!/bin/zsh
# Builds VitalsClone.app (menu-bar only). Uses Command Line Tools + macOS 26.5 SDK because the
# Xcode license is not yet accepted and the CLT macOS 27 SDK lacks SwiftUI's macro plugin.
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift build -c release
APP=build/VitalsClone.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VitalsClone "$APP/Contents/MacOS/VitalsClone"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>VitalsClone</string>
  <key>CFBundleIdentifier</key><string>com.samin.VitalsClone</string>
  <key>CFBundleExecutable</key><string>VitalsClone</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>Checks for a .git folder or project file to group developer processes by project.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Checks for a .git folder or project file to group developer processes by project.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Checks for a .git folder or project file to group developer processes by project.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
