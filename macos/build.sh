#!/bin/bash
# Сборка OpenSwitcher.app (аналог build.cmd из Windows-версии).
# Использование: ./build.sh [arm64|x86_64|universal]; без аргумента — хост-архитектура.
set -e
cd "$(dirname "$0")"
ARCH="${1:-host}"

# Удаляем продукты прошлых сборок: иначе после хост-сборки остаётся старый
# .build/release/OpenSwitcher, и кросс-сборка arm64 на Intel-хосте пакует его (x86_64!).
rm -f .build/release/OpenSwitcher .build/apple/Products/Release/OpenSwitcher \
      .build/arm64-apple-macosx/release/OpenSwitcher .build/x86_64-apple-macosx/release/OpenSwitcher
rm -rf .build/release/*.dSYM .build/apple/Products/Release/*.dSYM \
       .build/arm64-apple-macosx/release/*.dSYM .build/x86_64-apple-macosx/release/*.dSYM

if [ "$ARCH" = "universal" ]; then
    swift build -c release --arch arm64 --arch x86_64
elif [ "$ARCH" = "arm64" ] || [ "$ARCH" = "x86_64" ]; then
    swift build -c release --arch "$ARCH"
else
    swift build -c release
fi

# Детерминированный путь продукта: режим сборки — один конкретный путь,
# без поиска «что найдётся первым».
case "$ARCH" in
    arm64)     BIN=".build/arm64-apple-macosx/release/OpenSwitcher" ;;
    x86_64)    BIN=".build/x86_64-apple-macosx/release/OpenSwitcher" ;;
    universal) BIN=".build/apple/Products/Release/OpenSwitcher" ;;
    *)         BIN=".build/release/OpenSwitcher" ;;
esac
[ -f "$BIN" ] || { echo "BUILD FAILED: executable not found: $BIN"; exit 1; }

# Гейт архитектуры: реальная архитектура бинаря должна совпадать с ожидаемой.
HOST_ARCH="$(uname -m)"
EXPECTED_ARCH="$ARCH"
[ "$ARCH" = "host" ] && EXPECTED_ARCH="$HOST_ARCH"
ACTUAL_ARCH="$(lipo -archs "$BIN" 2>&1 | xargs)" || { echo "BUILD FAILED: lipo could not read $BIN: $ACTUAL_ARCH"; exit 1; }
has_arch() { case " $ACTUAL_ARCH " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
if [ "$ARCH" = "universal" ]; then
    if ! has_arch arm64 || ! has_arch x86_64; then
        echo "BUILD FAILED: universal binary expected [arm64 x86_64], got [$ACTUAL_ARCH] ($BIN)"; exit 1
    fi
elif ! has_arch "$EXPECTED_ARCH"; then
    echo "BUILD FAILED: architecture mismatch: expected $EXPECTED_ARCH, got [$ACTUAL_ARCH] ($BIN)"; exit 1
fi

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

# Selftest — только если бинарь исполняем на этом хосте:
# своя архитектура, либо x86_64 на arm64-хосте при установленной Rosetta.
CAN_RUN=0
RUN_PREFIX=()
if has_arch "$HOST_ARCH"; then
    CAN_RUN=1
elif [ "$EXPECTED_ARCH" = "x86_64" ] && [ "$HOST_ARCH" = "arm64" ]; then
    if [ -x /usr/bin/arch ] && /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
        CAN_RUN=1
        RUN_PREFIX=(/usr/bin/arch -x86_64)
    fi
fi

if [ "$CAN_RUN" = "1" ]; then
    "${RUN_PREFIX[@]}" "$APP/Contents/MacOS/OpenSwitcher" --selftest build/selftest_result.txt
else
    echo "selftest skipped: target arch not executable on host"
fi
