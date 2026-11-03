# Development

## Requirements

- macOS Tahoe 26 or newer on Apple silicon.
- Xcode 26 or newer with the macOS SDK.
- XcodeGen (`brew install xcodegen`) to regenerate the project from `Project.yml`.

## Generate, build, and launch

```sh
xcodegen generate
./script/build_and_run.sh
```

If Xcode is unavailable or its license has not been accepted yet, use the
Swift Package build path:

```sh
MAC_CLEANER_USE_SWIFTPM=1 ./script/build_and_run.sh --verify
```

The run script supports `--build-only`, `--verify`, `--debug`, `--logs`, and
`--telemetry`.
It uses `/Applications/Xcode.app` when that is present, even if the active
developer directory is set to Command Line Tools.

## Tests

```sh
xcodebuild -project MacCleaner.xcodeproj -scheme MacCleaner \
  -configuration Test -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- test
```

Tests create and remove only their own synthetic temporary fixtures. XCTest
uses a separate, unsandboxed `Test` build configuration. The shipped app is
also unsandboxed so macOS Full Disk Access can support whole-Mac read-only
scans. macOS privacy controls still apply, and selected cleanup actions require
review and confirmation. If the Xcode SDK license has not been accepted yet,
run `./script/run_core_checks.sh` to compile and run the scanner's Command Line
Tools test harness.

## Project files

- `Project.yml` is the source of truth for XcodeGen project settings.
- `MacCleaner.xcodeproj` is committed for opening directly in Xcode.
- `script/build_and_run.sh` is the local build/launch entry point.

## Public release

Public downloads must be signed with an Apple Developer ID Application
certificate and notarized before they are attached to a GitHub release. See
[`RELEASING.md`](RELEASING.md) for the workflow and required repository
secrets. Never commit certificates, passwords, or API keys.

## Troubleshooting

- If Xcode cannot find the SDK, open Xcode once and accept its first-launch
  setup, then run `xcode-select -p` and check the selected developer directory.
- The first disk scan opens a macOS grant panel at Macintosh HD. Select the disk
  and choose **Allow Access**. Later scans reuse the app-scoped bookmark; you
  can remove it in Settings. macOS can deny access to protected folders even
  after this grant, and the app reports inaccessible items.
- If a specific-folder scan reports permission failures, grant access through
  the app's Open panel.
- If the app cannot move a selected item to Trash, it reports the file and the
  OS error. No fallback permanently deletes the item.
