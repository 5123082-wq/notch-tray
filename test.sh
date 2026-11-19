#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${NOTCH_TRAY_BUILD_DIR:-$PROJECT_DIR/.build}"
mkdir -p "$BUILD_DIR/tests" "$BUILD_DIR/module-cache"
# Focus-sensitive AppKit tests need a real app bundle and application identity.
run_native_test() {
  local TEST_NAME="$1" TEST_EXECUTABLE="$2" SUCCESS_MESSAGE="$3"
  local TEST_APP="$BUILD_DIR/${TEST_NAME}Tests.app"
  local TEST_LOG="$BUILD_DIR/${TEST_NAME}-app.log" TEST_ERRORS="$BUILD_DIR/${TEST_NAME}-app-errors.log"
  mkdir -p "$TEST_APP/Contents/MacOS"
  cp "$TEST_EXECUTABLE" "$TEST_APP/Contents/MacOS/NativeTests"
  cp "$PROJECT_DIR/Tests/AppKitTests-Info.plist" "$TEST_APP/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleIdentifier -string "local.notchtray.tests.${TEST_NAME}" "$TEST_APP/Contents/Info.plist"
  codesign --force --sign - "$TEST_APP"
  : > "$TEST_LOG"
  : > "$TEST_ERRORS"
  if ! "$TEST_APP/Contents/MacOS/NativeTests" "$BUILD_DIR/tests" > "$TEST_LOG" 2> "$TEST_ERRORS"; then
    cat "$TEST_LOG"
    cat "$TEST_ERRORS" >&2
    exit 1
  fi
  cat "$TEST_LOG"
  if ! /usr/bin/grep -qF "$SUCCESS_MESSAGE" "$TEST_LOG"; then
    cat "$TEST_ERRORS" >&2
    exit 1
  fi
}
APP_SOURCES=()
for FILE in "$PROJECT_DIR"/Sources/*.swift; do
  if [ "$(basename "$FILE")" != "main.swift" ]; then APP_SOURCES+=("$FILE"); fi
done
# Check keyboard focus before the other native test processes create windows.
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  "$PROJECT_DIR/Sources/ReleaseUpdates.swift" "$PROJECT_DIR/Tests/ReleaseUpdateTests.swift" -o "$BUILD_DIR/release-update-tests"
"$BUILD_DIR/release-update-tests"
STORAGE_SOURCES=("$PROJECT_DIR/Sources/ScreenshotIdentity.swift" "$PROJECT_DIR/Sources/TrayStorage.swift"
  "$PROJECT_DIR/Sources/ScreenshotSettings.swift" "$PROJECT_DIR/Sources/ScreenshotMonitor.swift"
  "$PROJECT_DIR/Sources/ScreenshotEdit.swift")
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  -framework AppKit -framework QuartzCore -framework QuickLookThumbnailing \
  "${APP_SOURCES[@]}" "$PROJECT_DIR/Tests/QuickLookTests.swift" -o "$BUILD_DIR/QuickLook-tests"
run_native_test QuickLook "$BUILD_DIR/QuickLook-tests" 'Quick Look checks passed.'
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  -framework AppKit "${STORAGE_SOURCES[@]}" "$PROJECT_DIR/Tests/StorageTests.swift" \
  -o "$BUILD_DIR/storage-tests"
"$BUILD_DIR/storage-tests" "$BUILD_DIR/tests"
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  -framework AppKit -framework ImageIO -framework CoreServices \
  "${STORAGE_SOURCES[@]}" "$PROJECT_DIR/Tests/ScreenshotStorageTests.swift" \
  -o "$BUILD_DIR/screenshot-storage-tests"
"$BUILD_DIR/screenshot-storage-tests" "$BUILD_DIR/tests"
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  "${STORAGE_SOURCES[@]}" "$PROJECT_DIR/Tests/ScreenshotEditTests.swift" -o "$BUILD_DIR/screenshot-edit-tests"
"$BUILD_DIR/screenshot-edit-tests" "$BUILD_DIR/tests"
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  -framework AppKit -framework ImageIO -framework CoreServices \
  "${STORAGE_SOURCES[@]}" \
  "$PROJECT_DIR/Tests/ScreenshotRebootTests.swift" -o "$BUILD_DIR/screenshot-reboot-tests"
"$BUILD_DIR/screenshot-reboot-tests" "$BUILD_DIR/tests"
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  "$PROJECT_DIR/Sources/TrayMotion.swift" "$PROJECT_DIR/Tests/MotionTests.swift" -o "$BUILD_DIR/motion-tests"
"$BUILD_DIR/motion-tests"
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  "$PROJECT_DIR/Sources/ShelfSwipeGesture.swift" "$PROJECT_DIR/Tests/ShelfSwipeGestureTests.swift" \
  -o "$BUILD_DIR/swipe-gesture-tests"
"$BUILD_DIR/swipe-gesture-tests"
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  "$PROJECT_DIR/Sources/ShelfPagingMotion.swift" "$PROJECT_DIR/Tests/ShelfPagingMotionTests.swift" \
  -o "$BUILD_DIR/paging-motion-tests"
"$BUILD_DIR/paging-motion-tests"
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  -framework AppKit -framework ApplicationServices \
  "$PROJECT_DIR/Sources/ShortcutAction.swift" "$PROJECT_DIR/Tests/ShortcutActionTests.swift" \
  -o "$BUILD_DIR/shortcut-tests"
"$BUILD_DIR/shortcut-tests"
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  -framework AppKit -framework QuartzCore -framework QuickLookThumbnailing \
  "${APP_SOURCES[@]}" "$PROJECT_DIR/Tests/RevealTests.swift" -o "$BUILD_DIR/reveal-tests"
"$BUILD_DIR/reveal-tests" "$BUILD_DIR/tests"
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  -framework AppKit -framework QuartzCore -framework QuickLookThumbnailing \
  "${APP_SOURCES[@]}" "$PROJECT_DIR/Tests/DropTests.swift" -o "$BUILD_DIR/drop-tests"
"$BUILD_DIR/drop-tests" "$BUILD_DIR/tests"
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  -framework AppKit -framework QuartzCore -framework QuickLookThumbnailing \
  "${APP_SOURCES[@]}" "$PROJECT_DIR/Tests/FileTileTests.swift" -o "$BUILD_DIR/file-tile-tests"
"$BUILD_DIR/file-tile-tests" "$BUILD_DIR/tests"
for TEST in ScreenshotController ScreenshotView ShelfSwipeIntegration ImageEditing Cleanup; do
  xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
    -framework AppKit -framework QuartzCore -framework QuickLookThumbnailing -framework ImageIO -framework CoreServices \
    "${APP_SOURCES[@]}" "$PROJECT_DIR/Tests/${TEST}Tests.swift" -o "$BUILD_DIR/${TEST}-tests"
  if [ "$TEST" = "ImageEditing" ]; then
    run_native_test "$TEST" "$BUILD_DIR/${TEST}-tests" 'Image editing checks '
  else
    "$BUILD_DIR/${TEST}-tests" "$BUILD_DIR/tests"
  fi
done
