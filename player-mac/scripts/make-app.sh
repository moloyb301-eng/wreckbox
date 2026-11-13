#!/bin/sh
# Builds "WreckBox Player.app" with its macOS widget (PlugIns/WreckBoxPlayerWidget.appex), ad-hoc signed.
#   scripts/make-app.sh            → build/WreckBox Player.app
#   scripts/make-app.sh install    → also copies it to /Applications (the widget gallery finds it there)
set -e
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
swift build -c release --product WreckBoxPlayer
swift build -c release --product PlayerWidget
BIN=".build/release"
APP="build/WreckBox Player.app"
EXT="$APP/Contents/PlugIns/WreckBoxPlayerWidget.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
cp "$BIN/WreckBoxPlayer" "$APP/Contents/MacOS/WreckBoxPlayer"
cp "$BIN/PlayerWidget" "$EXT/Contents/MacOS/PlayerWidget"
cp -R Sources/WreckBoxPlayer/Resources/Fonts "$APP/Contents/Resources/Fonts"
cp -R Sources/WreckBoxPlayer/Resources/Fonts "$EXT/Contents/Resources/Fonts"

ICONSET="$(mktemp -d)/Player.iconset"
"$BIN/WreckBoxPlayer" make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Player.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>WreckBox Player</string>
  <key>CFBundleDisplayName</key><string>WreckBox Player</string>
  <key>CFBundleIdentifier</key><string>local.wreckbox.player</string>
  <key>CFBundleExecutable</key><string>WreckBoxPlayer</string>
  <key>CFBundleIconFile</key><string>Player</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>WreckBox Player plays Spotify songs through the Spotify app.</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>WreckBox Player widget</string>
    <key>CFBundleURLSchemes</key><array><string>wbplayer</string></array>
  </dict></array>
</dict></plist>
PLIST

cat > "$EXT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>WreckBox Player Widget</string>
  <key>CFBundleDisplayName</key><string>WreckBox Player</string>
  <key>CFBundleIdentifier</key><string>local.wreckbox.player.widget</string>
  <key>CFBundleExecutable</key><string>PlayerWidget</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
</dict></plist>
PLIST

# The widget is sandboxed (macOS requires it) and may only read the folder the app writes its state to.
ENT="$(mktemp -d)/widget.entitlements"
cat > "$ENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
  <array><string>/Library/Application Support/WreckBox Player/Widget/</string></array>
</dict></plist>
PLIST
codesign --force -s - --entitlements "$ENT" "$EXT"
codesign --force -s - "$APP"
echo "Built $APP"

if [ "$1" = "install" ]; then
  pkill -x WreckBoxPlayer 2>/dev/null || true
  rm -rf "/Applications/WreckBox Player.app"
  cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/WreckBox Player.app"
  pluginkit -a "/Applications/WreckBox Player.app/Contents/PlugIns/WreckBoxPlayerWidget.appex" 2>/dev/null || true
  echo "Installed /Applications/WreckBox Player.app"
fi
