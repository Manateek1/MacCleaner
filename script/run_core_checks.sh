#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_BINARY="$ROOT_DIR/build/MacCleanerCoreChecks"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  SELECTED_DEVELOPER_DIR="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  if [[ -n "$SELECTED_DEVELOPER_DIR" && "$SELECTED_DEVELOPER_DIR" != */CommandLineTools && -d "$SELECTED_DEVELOPER_DIR" ]]; then
    DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"
  elif [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -n "$SELECTED_DEVELOPER_DIR" && -d "$SELECTED_DEVELOPER_DIR" ]]; then
    DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"
  else
    DEVELOPER_DIR="/Library/Developer/CommandLineTools"
  fi
fi
export DEVELOPER_DIR

SWIFT_COMPILER="$(/usr/bin/xcrun --find swiftc)"
MACOS_SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="$ROOT_DIR/build/ModuleCache"
mkdir -p "$ROOT_DIR/build"
printf '[CoreCheck] Developer directory: %s\n' "$DEVELOPER_DIR"
"$SWIFT_COMPILER" --version | sed -n '1p'

compile_core_checks() {
  if [[ -n "${MAC_CLEANER_SWIFT_TARGET:-}" ]]; then
    "$SWIFT_COMPILER" -target "$MAC_CLEANER_SWIFT_TARGET" "$@"
  else
    "$SWIFT_COMPILER" "$@"
  fi
}

compile_core_checks \
  -swift-version 5 \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  -sdk "$MACOS_SDK" \
  -module-name MacCleanerCoreChecks \
  "$ROOT_DIR/MacCleaner/Models/ScanModels.swift" \
  "$ROOT_DIR/MacCleaner/Models/SystemMetrics.swift" \
  "$ROOT_DIR/MacCleaner/Services/LocalProtectionStatusService.swift" \
  "$ROOT_DIR/MacCleaner/Services/LocalMacOSUpdateService.swift" \
  "$ROOT_DIR/MacCleaner/Services/FileScanner.swift" \
  "$ROOT_DIR/MacCleaner/Services/SafeFileAccess.swift" \
  "$ROOT_DIR/MacCleaner/Services/ScanExclusions.swift" \
  "$ROOT_DIR/MacCleaner/Services/SafeFilePolicy.swift" \
  "$ROOT_DIR/Tests/CoreCheckRunner/main.swift" \
  -o "$CHECK_BINARY"

"$CHECK_BINARY"
