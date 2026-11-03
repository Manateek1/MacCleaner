# Mac Cleaner

Mac Cleaner is a native macOS utility for reviewing local storage and choosing
what to move to Trash. Scans are read-only, results are explained in plain
language, and cleanup stays under your control.

## Download

The app targets macOS Tahoe 26 or later and runs on Apple silicon.
The signed download will appear on the
[GitHub Releases page](https://github.com/Manateek1/MacCleaner/releases/latest)
once Developer ID signing and Apple notarization are configured. Until then,
the repository includes source and instructions for building it locally.

## What works

- Native SwiftUI macOS app with Overview, Smart Scan, Large & Old Files,
  Downloads, Exact Duplicates, Similar Photos, System Junk, AI Clutter, Space Lens,
  Local AI Models, Privacy Cleanup, Performance, Applications, App Updater, App
  Security, App Leftovers, Startup & Background, Trash, My Tools, Privacy &
  Permissions, Activity, Xcode Storage, Diagnostic Reports, and Settings.
- Light, blue-accented dashboard with a custom Mac Cleaner app icon and
  direct sidebar navigation.
- A guided first-run setup explains local file access and offers optional
  Photos access. After Full Disk Access is enabled once in System Settings,
  Smart Scan opens the whole-Mac scan directly without a folder picker.
- Smart Scan includes the signed-in account, including accessible Library
  metadata, accessible folders in other local accounts, shared files, selected
  system cache/log folders, accessible non-user areas of the system disk, and
  connected local external drives. Ordinary files in the signed-in account's
  Library remain read-only; only recognized cache/log candidates are offered
  for review. Other accounts' Library data, protected app-state folders, and
  developer toolchain folders are skipped; other-account results remain
  read-only. If Desktop is in iCloud
  Drive, local file metadata appears as read-only results; cloud-only files are
  not downloaded, and content-based checks skip iCloud items. Other iCloud
  Drive areas, network volumes, and protected system folders are skipped, with
  visible folder and file progress. Specific-folder scans remain available.
  The latest full-disk
  findings are saved locally with names and paths so a review survives restart;
  Settings can clear that saved review.
- Large and old file discovery, exact SHA-256 duplicate grouping with a saved
  oldest/newest keep recommendation, conservative cache/log rules, and a
  separate rule set for AI tool cache paths. Common
  Xcode, Simulator, Homebrew, pip, and npm caches are named and explained
  before review; simulator device data, Xcode archives, and installed project
  dependencies are excluded.
- Local model inventory for common Ollama, Hugging Face, and LM Studio folders,
  plus recognizable model-weight files elsewhere in your home folder. Models
  start unchecked. Review exact names and paths, then move a selection to Trash
  after one confirmation. Shared Ollama data stays in place when another model
  still needs it.
- Xcode Storage lists standard local archives and device-support folders by
  name, location, date, file count, and logical size. Fully checked, ordinary
  archives can be reviewed by exact name and path, then moved to Trash after
  one confirmation; incomplete, linked, shared-file, or oversized archives
  and device-support folders remain view-only.
- Diagnostic Reports finds older reports from the current account. Recent
  reports stay out of the review; selected items can move to Trash after you
  inspect their names, dates, and optional Quick Look preview.
- Screen Cleaning Mode covers connected displays for 30 seconds, one minute,
  or two minutes, and can be exited at any time.
- App Security checks app bundle integrity and reviews user/shared startup
  definitions plus helpers bundled inside installed apps for signature context.
  It also flags startup programs located in temporary folders or Downloads as
  a location to review; that signal is not a malware verdict.
  macOS approval details are reported for supported legacy definitions;
  registration status for another app's bundled helper is unavailable. An
  optional code trust check may contact Apple for certificate revocation and
  notarization. These checks provide context; they do not detect malware.
- App Updater can show when an app's numeric build changes after a supported
  feed check. It can also check Homebrew cask app versions using the metadata
  currently available to Homebrew and copy an update command for review. It
  does not refresh Homebrew's catalog, download, run, or install updates.
- Privacy Cleanup reviews recognized local Safari, Chrome, and Firefox cache
  folders. Chrome must be closed before a selected cache can move to Trash;
  history, cookies, downloaded files, saved passwords, and website sign-in data
  stay in the browsers.
- Plain-language explanations, Quick Look previews, name/location search,
  category filters with finding counts, size/date sorting, scan progress and
  cancellation, and size/age settings. Full-disk results can also be reviewed
  by Desktop, Documents, Downloads, Pictures, or other checked locations.
- The Downloads shortcut scans accessible parts of the Mac and filters the
  review to Downloads. The Trash shortcut opens Finder for restoring or
  managing trashed items; Mac Cleaner never empties Trash.
- Space Lens shows a proportional map and folder drill-down for the files the
  latest scan checked, with previews of findings in each folder.
- Similar Photos distinguishes byte-identical local image copies from visual
  matches and can scan locally available Photos-library images without
  downloading from iCloud. It includes previews, adjustable tolerance, and
  explicit confirmation before local files go to Trash or Photos items are
  removed. Visual matches are suggestions and need review.
- Files are unselected by default. Before cleanup, the app revalidates the
  file identity, checks path protections, and asks before moving selections to
  Trash. It never purges Trash.
- Local activity includes aggregate App Security results and omits file names
  and paths.
- Optional completion alerts cover scans, cleanup reviews, App Security,
  user-started app update checks, and Mac Health checks. They start off, use
  generic text, and ask macOS for notification access only after you turn one
  on in Settings.
- Diagnostics can be exported as a report with version details, scan totals,
  and thresholds only; file names and paths are omitted.
- Read-only CPU, memory-page, swap, storage, and available battery readings in
  the Performance screen and menu-bar panel. Sampling runs only while one of
  those views is open.
- Mac Health & Maintenance can list local Time Machine snapshot names and
  dates on the startup volume without changing them. Sizes are not reported,
  and Apple manages the snapshots.
- Mac Health can check FileVault, firewall, Gatekeeper, and System Integrity
  Protection status on demand. The checks are read-only, show unrecognized
  states as unavailable, and do not claim to scan for malware.
- Mac Health can also read the startup drive’s SMART status from macOS. A
  verified report is limited and cannot predict future drive failure.
- Mac Health can check Apple’s available software updates when you press the
  button. It lists update names and versions without downloading or installing;
  no scan findings or file names are sent.
- Mac Health’s visible score includes storage, memory pressure, battery, startup
  disk status, selected macOS protection settings, and an optional user-started
  Apple update check. Its weights and unavailable inputs are explained in the
  app; the score is not an Apple diagnosis.
- Application inventory, individual and batch removal reviews, and Reset App.
  Related data is matched only by exact bundle-ID paths in common user Library
  locations, starts unselected, and is moved to Trash only after review. Paths
  with sensitive-looking names are kept out of the selectable list, but the app
  does not inspect their contents or claim every other path is private-data-free.
- App Leftovers compares exact app identifiers across seven common Library
  locations—Application Support, Caches, Preferences, Containers, Logs, Saved
  Application State, and Application Scripts—with apps found in standard
  Applications folders. It estimates size from file metadata without opening
  file contents. It also lists local App Group folders and any installed app
  with a valid signed declaration for each group. Shared folders are always
  view-only because other app copies and helpers may use them too.
  Results start unchecked; open each exact path in Finder and acknowledge that
  you reviewed it before the app allows selection. A match does not prove the
  data is unused.
- Readable launch definitions with declared purpose, launch conditions,
  disabled flags, and legacy macOS authorization details, plus launch agents,
  daemons, and LoginItems stored inside apps in standard Applications folders.
  Recent login items open in macOS Settings. The app does not claim another
  app's bundled helper is registered or running; this is not a complete list of
  running services.

Mac Cleaner is scoped to local files and macOS tools. Cloud providers, email
cleanup, Chrome extensions, and browser messaging are not included. Manual app
update checks are user-started; scan data and results stay on this Mac.

See [FEATURES.md](FEATURES.md) for the full implemented and planned inventory.

## Requirements

- macOS Tahoe 26 or later
- Xcode with the macOS SDK
- Apple silicon Mac

## Privacy and safety

Scans are read-only. The app will not delete files when a scan completes. Any
cleanup action must show the selected paths and require explicit confirmation.
Known credential, sensitive app-data, cloud-sync, AI history/model and nested
development repository locations are skipped. Protected macOS locations are
skipped or view-only. macOS may deny additional locations, and the app reports
skipped items and partial scans.

Mac Cleaner is not App Sandboxed. Full Disk Access is an optional macOS setting
that enables broader read-only scanning of protected folders. The app does not
upload scan results. User-started app, Apple, and Homebrew metadata checks make
their own network requests; see [SECURITY.md](SECURITY.md) for details.

## Build and run

```sh
xcodegen generate
./script/build_and_run.sh
```

See [DEVELOPMENT.md](DEVELOPMENT.md) for setup and test instructions. The
project is generated from `Project.yml` and the generated Xcode project is
committed for direct opening in Xcode.
