#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacCleaner"
PROJECT="$ROOT_DIR/MacCleaner.xcodeproj"
SCHEME="MacCleaner"
USE_SWIFTPM="${MAC_CLEANER_USE_SWIFTPM:-0}"
MAC_CLEANER_VERSION="$(awk '/MARKETING_VERSION:/ { print $2; exit }' "$ROOT_DIR/Project.yml")"
MAC_CLEANER_BUILD_NUMBER="$(awk '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$ROOT_DIR/Project.yml")"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ "$USE_SWIFTPM" == "1" ]]; then
    DEVELOPER_DIR="/Library/Developer/CommandLineTools"
  else
    DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi
DERIVED_DATA="${TMPDIR:-/tmp}/maccleaner-derived-data-${UID}/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

export DEVELOPER_DIR

if [[ ! -d "$PROJECT" ]]; then
  echo "Missing $PROJECT. Run 'xcodegen generate' first." >&2
  exit 1
fi

close_existing_app() {
  if ! /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    return
  fi

  /usr/bin/osascript -e 'tell application id "com.manateek1.MacCleaner" to quit' >/dev/null 2>&1 || true
  for _ in {1..10}; do
    if ! /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done

  echo "$APP_NAME did not close. Stopping so the new build will not open beside it." >&2
  exit 1
}

close_existing_app

if [[ "$USE_SWIFTPM" == "1" ]]; then
  swift build
  BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"
  APP_BUNDLE="$ROOT_DIR/build/SwiftPM/$APP_NAME.app"
  APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
  APP_CONTENTS="$APP_BUNDLE/Contents"
  APP_MACOS="$APP_CONTENTS/MacOS"
  APP_RESOURCES="$APP_CONTENTS/Resources"
  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$BUILD_BINARY" "$APP_EXECUTABLE"
  chmod +x "$APP_EXECUTABLE"
  ICONSET="$APP_RESOURCES/MacCleaner.iconset"
  cp -R "$ROOT_DIR/MacCleaner/Assets.xcassets/AppIcon.appiconset" "$ICONSET"
  /usr/bin/iconutil -c icns -o "$APP_RESOURCES/MacCleaner.icns" "$ICONSET"
  rm -rf "$ICONSET"
  cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.manateek1.MacCleaner</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>Mac Cleaner</string>
  <key>CFBundleIconFile</key>
  <string>MacCleaner.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>$MAC_CLEANER_BUILD_NUMBER</string>
  <key>CFBundleShortVersionString</key>
  <string>$MAC_CLEANER_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>Mac Cleaner compares photos stored on this Mac to find similar pictures. Selected photos are removed only after you confirm.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Mac Cleaner checks files already stored on your Desktop. Cloud-only files are not downloaded, and nothing is moved without your confirmation.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Mac Cleaner checks Documents for large files, exact duplicates, and recognized temporary files. Scans are read-only; selected files go to Trash only after you confirm.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Mac Cleaner checks Downloads for large files, exact duplicates, and recognized temporary files. Scans are read-only; selected files go to Trash only after you confirm.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
  /usr/bin/codesign --force --sign - "$APP_BUNDLE"
else
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY=- \
    build
fi

case "$MODE" in
  --build-only|build-only)
    ;;
  run)
    /usr/bin/open -n "$APP_BUNDLE"
    ;;
  --debug|debug)
    lldb -- "$APP_EXECUTABLE"
    ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.manateek1.MacCleaner"'
    ;;
  --verify|verify)
    existing_pids="$(pgrep -x "$APP_NAME" 2>/dev/null | tr '\n' ' ' || true)"
    /usr/bin/open -n "$APP_BUNDLE"
    for attempt in {1..10}; do
      current_pids="$(pgrep -x "$APP_NAME" 2>/dev/null | tr '\n' ' ' || true)"
      for pid in $current_pids; do
        case " $existing_pids " in
          *" $pid "*) ;;
          *) exit 0 ;;
        esac
      done
      sleep 1
    done
    echo "$APP_NAME did not remain running after launch." >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
