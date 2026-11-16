#!/bin/zsh
# 编译正式版并打包成 build/Piyi.app（本机自签名，双击即可打开）
set -e
cd "$(dirname "$0")/.."
swift build -c release --product Piyi
swift build -c release --product PiyiRelay
(cd Extension && { [[ -d node_modules ]] || npm ci --silent } && npm run build --silent)
BIN=$(swift build -c release --show-bin-path)
# 默认打到 build/Piyi.app；设 APP=<路径> 打到别处，不动正在用的那个
APP="${APP:-build/Piyi.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Piyi" "$APP/Contents/MacOS/Piyi"
# 扩展的中转程序和 App 放在一起：浏览器按 App 每次启动时写的登记文件找到它
cp "$BIN/PiyiRelay" "$APP/Contents/MacOS/PiyiRelay"
# 浏览器扩展：App 启动时装到 ~/Library/Application Support/Piyi Bridge/Extension，你在扩展页加载的是那一份
cp -R Extension/dist "$APP/Contents/Resources/Extension"
cp -R "$BIN/Piyi_Piyi.bundle" "$BIN/Piyi_Library.bundle" "$APP/Contents/Resources/"
# 界面语言：系统是中文时用中文，其余用英文。翻译表放在 App 自己的 en.lproj 里，SwiftUI 的文字和 String(localized:) 默认都到这里查；
# 中文就是代码里的原文。两个文件夹都在，系统自带的菜单（文件、编辑、窗口、帮助）和「设置」窗口标题也跟着切
cp -R Localization/*.lproj "$APP/Contents/Resources/"
# App 图标：Icon Composer 格式，actool 编译成 Assets.car（系统按层加玻璃质感）和给旧系统的 AppIcon.icns
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon --target-device mac \
  --minimum-deployment-target 26.0 --platform macosx --output-partial-info-plist /dev/null >/dev/null
# llama.cpp 是动态库：放进 Contents/Frameworks，并告诉程序去那里找。本机模型文件不进安装包，在设置里下载
cp -R "$BIN/llama.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Piyi"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Piyi</string>
  <key>CFBundleDisplayName</key><string>Piyi</string>
  <!-- 默认名 Piyi 和文件名一致，访达才会按 zh-Hans.lproj/InfoPlist.strings 在中文系统里显示「片羽」 -->
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
  <!-- 右键「服务」→「收进片羽」：选中的文字、网址、文件。消息名对应 QuickCollect.collect -->
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
echo "已生成 $APP"
