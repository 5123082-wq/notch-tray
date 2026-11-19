#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_APP="${1:-$PROJECT_DIR/../Notch Tray.app}"
BUILD_DIR="${NOTCH_TRAY_BUILD_DIR:-$PROJECT_DIR/.build}"
SIGNING_IDENTITY="${NOTCH_TRAY_SIGNING_IDENTITY:-$(cat "$PROJECT_DIR/signing-identity.txt" 2>/dev/null || true)}"
if [ -z "$SIGNING_IDENTITY" ] || [ "$SIGNING_IDENTITY" = "-" ]; then
  echo 'A persistent signing certificate is required. Set NOTCH_TRAY_SIGNING_IDENTITY or signing-identity.txt.' >&2
  exit 1
fi
mkdir -p "$BUILD_DIR/module-cache" "$OUTPUT_APP/Contents/MacOS" "$OUTPUT_APP/Contents/Resources"
ARCH="$(uname -m)"
xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macosx14.0" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -framework AppKit -framework QuartzCore -framework QuickLookThumbnailing \
  "$PROJECT_DIR"/Sources/*.swift -o "$OUTPUT_APP/Contents/MacOS/NotchTray"
cp "$PROJECT_DIR/Info.plist" "$OUTPUT_APP/Contents/Info.plist"
for file in README.md THIRD_PARTY_NOTICES.md LICENSE; do
  if [ -f "$PROJECT_DIR/$file" ]; then cp "$PROJECT_DIR/$file" "$OUTPUT_APP/Contents/Resources/"; fi
done
cp -R "$PROJECT_DIR/Licenses" "$OUTPUT_APP/Contents/Resources/"
if [ -f "$PROJECT_DIR/AppIcon.icns" ]; then cp "$PROJECT_DIR/AppIcon.icns" "$OUTPUT_APP/Contents/Resources/"; fi
codesign --force --sign "$SIGNING_IDENTITY" "$OUTPUT_APP"
codesign --verify --deep --strict "$OUTPUT_APP"
echo "$OUTPUT_APP"
