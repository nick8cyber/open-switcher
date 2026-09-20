#!/bin/bash
# Сборка OpenSwitcher.app (аналог build.cmd из Windows-версии).
# Использование: ./build.sh [arm64|x86_64|universal]; без аргумента — хост-архитектура.
set -e
cd "$(dirname "$0")"
ARCH="${1:-host}"

if [ "$ARCH" = "universal" ]; then
    swift build -c release --arch arm64 --arch x86_64
elif [ "$ARCH" = "arm64" ] || [ "$ARCH" = "x86_64" ]; then
    swift build -c release --arch "$ARCH"
else
    swift build -c release
fi

# путь продукта зависит от способа сборки (одна архитектура vs универсальная)
BIN=""
for p in .build/release/OpenSwitcher .build/apple/Products/Release/OpenSwitcher \
         .build/arm64-apple-macosx/release/OpenSwitcher .build/x86_64-apple-macosx/release/OpenSwitcher; do
    [ -f "$p" ] && BIN="$p" && break
done
[ -z "$BIN" ] && { echo "BUILD FAILED: executable not found"; exit 1; }

APP=build/OpenSwitcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/OpenSwitcher"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>OpenSwitcher</string>
    <key>CFBundleDisplayName</key><string>OpenSwitcher</string>
    <key>CFBundleIdentifier</key><string>com.openswitcher.app</string>
    <key>CFBundleExecutable</key><string>OpenSwitcher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

echo "Готово: $APP"
"$APP/Contents/MacOS/OpenSwitcher" --selftest selftest_result.txt
