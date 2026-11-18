#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
args=(-c release)
output="$PWD/dist"
case "${1:-}" in
  --universal)
    args+=(--arch arm64 --arch x86_64 --scratch-path .build/universal)
    output="$output/universal"
    ;;
  "") ;;
  *) echo "Usage: $0 [--universal]" >&2; exit 2 ;;
esac
swift build "${args[@]}"
bin_dir=$(swift build "${args[@]}" --show-bin-path)
APP="$output/DevDock.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ICONSET="$PWD/.build/DevDock.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$bin_dir/DevDock" "$APP/Contents/MacOS/DevDock.new"
mv -f "$APP/Contents/MacOS/DevDock.new" "$APP/Contents/MacOS/DevDock"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DevDock</string>
<key>CFBundleIdentifier</key><string>cn.xieyuqiyu.devdock</string>
<key>CFBundleName</key><string>DevDock</string>
<key>CFBundleDisplayName</key><string>DevDock</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><false/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf '已构建：%s\n' "$APP"
if [[ "${1:-}" == --universal ]]; then
  lipo "$APP/Contents/MacOS/DevDock" -verify_arch arm64
  lipo "$APP/Contents/MacOS/DevDock" -verify_arch x86_64
  codesign --verify --deep --strict --all-architectures "$APP"
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$output/DevDock-macOS-universal.zip"
fi
