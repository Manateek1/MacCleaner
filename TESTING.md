# Testing

## Automated tests

Tests use uniquely named temporary folders and synthetic files. They do not
scan or modify the user's real files. Cleanup tests use an injected operation
that moves fixture files only to disposable test folders, never the system
Trash.

Navigation tests verify that the nine numbered shortcuts are unique and map in
order, and that the shared navigation model changes sections as expected.
Hosted UI tests navigate through all 22 primary sidebar sections and verify
that the menu-bar icon opens a visible System Monitor panel with CPU and storage
cards. They also verify Command-8 navigation to Privacy & Permissions and scroll
sidebar rows fully into view before clicking them. The menu-bar panel layout
test also measures the hosted SwiftUI view and guards against a collapsed,
one-line window by requiring its intended minimum size.

Run with:

```sh
xcodebuild -project MacCleaner.xcodeproj -scheme MacCleaner \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- test
```

The XCTest suite covers byte-exact duplicate grouping (including same-size
different-content files), keeping one copy, cancellation, repository
protection, size/age thresholds, AI and developer cache classification with
tool-specific explanations and protected Xcode archives and Simulator device
data, hard links, symlinks,
protected credentials, system-root rejection, changed file identity, selected
root replacement by symlink, current duplicate survivor validation, refreshed
duplicate groups after cleanup, and path component boundaries.
Finding-location tests cover Desktop, Documents, Downloads, Pictures, external
volumes, and sibling paths that must not match by a similar folder name.
Local AI model inventory tests use temporary fixture folders to check Ollama
manifest names and shared blobs, Hugging Face snapshot links and path safety,
LM Studio model grouping, and the entry safety limit.
CPU and network utilization calculations from counter deltas, unavailable first
samples, invalid elapsed time, and counter resets are covered by
`SystemMetricsTests`. Swap-usage math rejects missing or inconsistent capacity,
and uptime display formatting is covered. Mac Health tests cover known
battery-health values, the documented weights for storage, memory, battery,
startup disk, protection settings, and Apple update checks, plus omitting
unavailable or unrequested readings and elevated battery-service status.
Local protection-status tests cover enabled, disabled, missing, and
unrecognized outputs for FileVault, Firewall, Gatekeeper, and System Integrity
Protection without making any system changes.
Startup disk health tests cover SMART status parsing for verified, failing,
missing, and unsupported reports, plus a read-only local probe.
macOS update tests use fixed sample output to cover available update titles and
versions, up-to-date, unknown, failed, and timed-out states. Tests never contact
Apple's update service.
Homebrew tests cover cask-only JSON parsing, safe token validation, standard
executable discovery, disabled auto-update and analytics flags, and keeping
the result limited to copyable commands. Tests invoke only a temporary fixture
executable and never run a package update.
Browser privacy tests cover exact Chrome cache paths, running-browser blocking,
review revalidation, and preserving Chrome history, cookies, and saved passwords.
Privacy-permission tests cover media and Contacts status mapping without
requesting access, plus the non-specific explanation for permissions macOS
reports as off or not yet allowed.
App-security tests cover signature-status classification, full-bundle
validation flags, unsigned-app handling, per-app progress, and cancellation.
Device-backup tests cover metadata-only size inventory, recognized versus
incomplete folders, symlink and entry-limit exclusions, exact trash targets,
stale-review rejection, root containment, per-backup and total-entry limits,
cancellation, and a missing backup folder.
Application-removal tests cover exact related-path discovery, sensitive and
development-data exclusions, invalid selections, changed data locations,
protected and running apps, root boundaries, symlinks, changed plists, and
replaced bundles, plus partial batch preparation when a selected app is
running. App Leftovers tests cover exact bundle-ID matches, recognized suffix
suggestions anchored by exact unused identifiers, installed and running-app
exclusions, sensitive names, incomplete and capped inventories, the required
Finder-review acknowledgement, selected-only moves to a disposable fixture
Trash, and changed match anchors being rejected.
Disk-scan tests cover Desktop/Documents/Downloads and accessible locations
outside the account, read-only findings from other local accounts, current
account Library metadata with safe cleanup restrictions, exclusion of
protected app-state, developer toolchains, and other-account Library data,
streamed directory progress, partial results at the entry limit, saved
first-run notice state, and local full-disk review storage round-trips, private
file permissions, scope validation, and clearing.
Scan-view-model coverage verifies that a saved review can be restored when the
disk bookmark is absent while cleanup selection remains unavailable.
Partial-result tests verify the files-and-folders cap,
the number of entries retained, and the bounded skipped-location summary.
Scan-exclusion tests cover local preference persistence, duplicate and nested
path normalization, path-component boundaries, skipping excluded subtrees,
listing applied exclusions, and refusing a scan rooted inside an excluded path.
TrashService tests use a temporary destination to verify a reviewed move,
reject changed files before invoking the move, require an unchanged duplicate
survivor, and report a mismatched destination identity as a failure.
Activity tests cover seven-day calendar grouping, event categories, and
backward-compatible loading of saved records from before activity categories
were added.
Diagnostics-export tests check aggregate scan totals and confirm that file
paths, file names, account names, and excluded-folder names are not serialized.
Similar-photo tests cover byte-identical versus visual-match labels, the bounded
exact-hash read budget, candidate-index matching at the maximum tolerance,
recompressed images, hard links, and partial scan limits. A cross-format
integration test dynamically writes duplicate fixtures for every still-image
type that ImageIO can both encode and decode on the test Mac and confirms the
real scanner groups each pair. It exercised 12 formats on the current Mac; the
set varies with the installed macOS ImageIO decoders.
Similarity-preference tests cover tolerance bounds, plain-language labels, and
restoring the saved default.
Space Lens directory-reader tests cover direct-file sorting, protected names,
symlink skipping, scan-root boundaries, and partial results at a folder-entry
limit. All fixtures are temporary local folders.
Photos-library safety tests cover authorization-state handling and requiring a
current unselected survivor in every selected visual-match group. The real Photos
library is not touched by unit tests. Permission-label tests cover plain-language
names for Photos authorization states, including limited and restricted access.
Startup-inventory tests cover malformed and symlinked definitions and ensure
only the executable, not its arguments, is displayed; launch explanations,
declared disabled state, schedules, watched paths, and on-demand entries.

`./script/run_core_checks.sh` compiles and runs twenty-three core checks with the
selected Xcode toolchain (or Command Line Tools when Xcode is unavailable),
including CPU counter-delta calculations. If the active developer directory
is Command Line Tools but `/Applications/Xcode.app` is installed, the script
uses Xcode; a versioned Xcode selected by `xcode-select` is also honored. It
prints the chosen developer directory and Swift version for CI diagnostics,
and duplicate checks report progress from their first candidate. The script
keeps its module cache in the ignored `build/` directory, uses synthetic
temporary fixtures, stress-scans a 10,000-file tree, and does not move any
files to Trash.
My Tools favorite tests cover stable storage, including Downloads and Trash
entries, and ignoring unknown section IDs.
Manual UI verification confirmed that search filters tools and a newly pinned
favorite remains in the shortcuts after navigating away and back.

The XCTest suite uses Xcode's test runner. GitHub Actions tests on the stable
macOS Tahoe 26 runner and the preview macOS 27 runner (`xcode-27`). The release
archive remains built on Tahoe 26 for the declared minimum OS.

On Nov 7, 2026, Mac Cleaner 0.5.7 build 110 passed the GitHub macOS 26 release
gate (run 42411613124): 329 unit tests, both hosted UI tests, all 23 standalone
core checks (including the 10,000-file stress scan), and Xcode static analysis.
The UI suite reached all 22 sidebar sections and confirmed the menu-bar panel
shows its title, CPU card, and storage card.
Intel and macOS versions earlier than Tahoe 26 remain outside the product
support target. The current hosted suite also checks Command-8 navigation and
runs on both the Tahoe 26 stable runner and the macOS 27 preview runner; see
compatibility PR #4 for its results.

## Manual checks performed

- Launched an earlier sandboxed build and verified its dashboard shows live
  volume capacity values.
- Selected a disposable synthetic folder, confirmed exact duplicate grouping,
  and verified a synthetic SSH key fixture was excluded.
- Moved one selected duplicate fixture to Trash; its matching original stayed
  in place, and the app reported that nothing was permanently deleted.
- Reviewed and moved a disposable app bundle to Trash using the app's confirmation;
  no real app or related data was moved.
- Completed a read-only App Leftovers scan in the installed app. The results
  remained unselected and no real location was moved.
- Installed build 0.3.3 (6) and completed Smart Scan across accessible areas of
  the system disk. Directory and duplicate-check progress advanced, unreadable
  locations were reported, real findings stayed unselected, and nothing moved.
- In the 0.4.0 release build, started a fresh read-only whole-Mac scan from the
  Downloads shortcut. Folder traversal, duplicate review, and the App Security
  pass completed; the results stayed filtered to Downloads. The scan displayed
  its inaccessible-location summary, and no result was selected or moved.
- In the 0.4.0 release build, searched My Tools for Downloads and Trash. The
  Downloads shortcut opened the whole-Mac review with the Downloads filter; the
  Trash shortcut opened Finder's Trash. No Trash contents were changed.
- Opened the 0.5.0 build directly from the checkout. App Updater found 117
  installed apps, ran the user-started Homebrew check, and displayed the valid
  no-outdated-casks result. Mac Health showed the expanded score and the
  available read-only protection and startup-disk states. The completion
  notification settings remained off; no permission prompt appeared and no
  files were moved.
- Verified live swap usage on the Performance screen and switched the app to
  Dark, then back to Light. Light appearance was restored. Zoomed the main
  window and restored its previous size without breaking the Performance view.
- Completed read-only scans of local pictures and an already-authorized Photos
  library. Both returned visual-match groups; local results and Photos items
  stayed unselected, and no Photos items were removed.
- Opened and closed Quick Look from a local Similar Photos result.
- Opened Privacy & Permissions in the installed 0.3.4 build, confirmed the
  saved disk-access and Photos statuses, and followed both links to their scan
  screens.
- In the installed 0.5.1 build, opened the blue Overview, Smart Scan, Large &
  Old Files, Exact Duplicates, Performance, Mac Health, Applications, and App
  Updater screens. The saved scan remained review-only; no files were selected
  or moved.
- Built and unit-tested the Mac Health score and Maintenance navigation. An
  isolated, sandboxed preview showed live storage, an elevated macOS
  memory-pressure event, and Apple-reported battery condition. macOS did not
  return a battery cycle count. No scan ran and the preview was not granted
  disk access.
- Ran an isolated, sandboxed sample-folder scan for Space Lens. It showed the
  flagged large file as selectable and other local files as preview-only;
  Quick Look opened a sample document. The selection was cleared without
  moving anything, and no real user files were scanned.

## Manual checks still needed

- Verify full-disk cancellation and the partial-result warning at the one
  million-entry cap using a large synthetic tree; keep real findings unselected.
- Verify denial and partial-failure messages for unreadable folders.
- In a disposable Photos library, verify the first-time allow/deny prompts and
  the separately confirmed removal flow. The current manual scan used an
  already-authorized personal library; no Photos items were removed.
- Exercise cancellation with a large temporary file tree.
- Verify moving a disposable fixture to Trash and restoring it from Trash.
- Test external-volume removal and disconnection behavior.
- Test large directories near and above the 1,000,000-file safety cap.
- Verify VoiceOver and keyboard-only selection/confirmation.
- Verify resizing at narrow and wide window sizes; zoom and restore plus light
  and dark appearance were checked in 0.4.0, with Light restored.
- Exercise supported installs on Tahoe 26 and later Apple silicon releases.
