#!/bin/zsh
# Builds the release version and packages it as build/Piyi.app (self-signed locally, opens with a double-click)
set -e
cd "$(dirname "$0")/.."
swift build -c release --product Piyi
swift build -c release --product PiyiRelay
(cd Extension && { [[ -d node_modules ]] || npm ci --silent } && npm run build --silent)
BIN=$(swift build -c release --show-bin-path)
# Builds to build/Piyi.app by default; set APP=<path> to build elsewhere without touching the one in use
APP="${APP:-build/Piyi.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Piyi" "$APP/Contents/MacOS/Piyi"
# The extension relay sits alongside the App: the browser finds it through the registration file the App writes on each launch
cp "$BIN/PiyiRelay" "$APP/Contents/MacOS/PiyiRelay"
# Browser extension: the App installs it to ~/Library/Application Support/Piyi Bridge/Extension on launch, and that's the copy you load on the extensions page
cp -R Extension/dist "$APP/Contents/Resources/Extension"
cp -R "$BIN/Piyi_Piyi.bundle" "$BIN/Piyi_Library.bundle" "$APP/Contents/Resources/"
# Interface language: Chinese when the system is Chinese, English otherwise. The translation table lives in the App's own en.lproj, where SwiftUI text and String(localized:) look by default;
# Chinese is the original text in the code. With both folders present, the system menus (File, Edit, Window, Help) and the Settings window title switch too
cp -R Localization/*.lproj "$APP/Contents/Resources/"
# App icon: Icon Composer format, compiled by actool into Assets.car (the system adds the glass effect per layer), plus an AppIcon.icns.
# actool only comes with full Xcode; with only the Command Line Tools, the same layers are stacked into a plain icon, without the glass effect
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon --target-device mac \
    --minimum-deployment-target 26.0 --platform macosx --output-partial-info-plist /dev/null >/dev/null
else
  echo "Xcode not found: using the plain app icon without the glass effect (install Xcode and rebuild to get the glass version)"
  swift scripts/flat_icon.swift "$APP/Contents/Resources/AppIcon.icns"
fi
# llama.cpp is a dynamic library: put it in Contents/Frameworks and tell the program to look there. On-device model files aren't in the package; they're downloaded in Settings
cp -R "$BIN/llama.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Piyi"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Piyi</string>
  <key>CFBundleDisplayName</key><string>Piyi</string>
  <!-- The default name Piyi matches the file name, so that Finder shows "片羽" on Chinese systems via zh-Hans.lproj/InfoPlist.strings -->
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleIdentifier</key><string>io.github.zhihao-r.piyi</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>CFBundleExecutable</key><string>Piyi</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Right-click Services → "Collect to Piyi" (收进片羽): selected text, URLs, files. The message name maps to QuickCollect.collect -->
  <key>NSServices</key><array><dict>
    <key>NSMenuItem</key><dict><key>default</key><string>收进片羽</string></dict>
    <key>NSMessage</key><string>collect</string>
    <key>NSPortName</key><string>Piyi</string>
    <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>public.url</string></array>
    <key>NSSendFileTypes</key><array><string>public.item</string></array>
    <key>NSRequiredContext</key><dict/>
  </dict></array>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null
echo "Built $APP"
