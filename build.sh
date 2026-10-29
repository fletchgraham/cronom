#!/bin/zsh
# Build Cronom.app. Usage: ./build.sh [--install] [--run]
set -euo pipefail
cd "$(dirname "$0")"

# Fall back to the standalone CLT if Xcode's license hasn't been accepted.
if ! xcrun swift --version >/dev/null 2>&1 && [[ -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Cronom"

APP=build/Cronom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Cronom"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Cronom</string>
  <key>CFBundleIdentifier</key><string>com.fletchgraham.cronom</string>
  <key>CFBundleExecutable</key><string>Cronom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

for arg in "$@"; do
  case $arg in
    --install)
      rm -rf /Applications/Cronom.app
      cp -R "$APP" /Applications/
      APP=/Applications/Cronom.app
      echo "Installed to $APP" ;;
    --run)
      pkill -x Cronom || true
      open "$APP" ;;
  esac
done
