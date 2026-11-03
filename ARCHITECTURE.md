# Architecture

## Current structure

- `MacCleaner/App` — SwiftUI app entry point.
- `MacCleaner/Views` — sidebar navigation, dashboard, scanners, results,
  activity, and settings.
- `MacCleaner/Models` — scan requests, findings, file identities, and activity
  summaries.
- `MacCleaner/Services/FileScanner.swift` — background directory enumeration,
  file classification, duplicate hashing, and progress reporting.
- `MacCleaner/Services/SpaceLensDirectoryReader.swift` — bounded direct-folder
  file metadata browsing using descriptor-relative, no-follow opens.
- `MacCleaner/Services/ScanExclusions.swift` — local folder exclusion storage,
  nested-path normalization, and component-boundary matching.
- `MacCleaner/Services/SafeFilePolicy.swift` — centralized cleanup policy,
  path checks, identity revalidation, and Trash moves.
- `MacCleaner/Services/ScanViewModel.swift` — main-actor UI state and selected
  folder access lifetime.
- `MacCleaner/Services/ActivityStore.swift` — local summary history.
- `MacCleaner/Services/ActivityTrends.swift` — calendar-day aggregation for the
  local seven-day activity chart.
- `MacCleaner/Services/DeviceBackupService.swift` — bounded, metadata-only
  inventory of the current user's standard local MobileSync backup folder,
  metadata fingerprint revalidation, and confirmed move-to-Trash support.
- `MacCleaner/Services/XcodeDeviceSupportInventory.swift` and
  `XcodeDeviceSupportRemovalService.swift` — metadata-only inventory of the
  standard local iOS Device Support folder, complete-tree snapshots, and
  revalidated Trash moves after review while Xcode is closed.
- `MacCleaner/Services/ApplicationSecurityAuditService.swift` — installed-app
  signature, sealed-resource, and nested-code verification across architectures,
  with per-app progress, cancellation, and result classification.
- `MacCleaner/Services/SystemMonitor.swift` — on-demand CPU, memory-page,
  volume-capacity, network-rate, external-volume, and uptime snapshots for the
  Performance screen and configurable menu-bar panel.
- `MacCleaner/Services/SystemActivityReader.swift` — read-only network counters
  and mounted local non-internal-volume metadata.
- `ApplicationInventory.swift` and `ApplicationRemoval.swift` — app discovery,
  batch and single-app removal, resettable exact bundle-ID data candidates,
  installed-app identifier inventory, possible-leftover discovery, sensitive-
  data exclusions, Trash flows, and path-identity revalidation.
- `ApplicationLeftoversView.swift` — searchable possible-leftover review,
  exact-path reveal, explicit selection, and confirmed move-to-Trash flow.
- `StartupInventory.swift` — read-only launch definition parsing, limited
  signature validation and legacy authorization information.
- `SimilarPhotoScanner.swift` — local approximate visual matching.
- `Tests/MacCleanerTests` — synthetic file-tree tests.

## Scan pipeline

1. The first-run view records a local, versioned scan notice acknowledgement.
   `NSOpenPanel` lets the user select a scan location. The app is not App
   Sandboxed; macOS permissions, privacy controls, and the user's Full Disk
   Access setting determine which paths it can actually read.
2. Disk access is saved in an app-scoped bookmark until forgotten or access
   stops working. A security-scoped access is held while the associated review
   is open.
3. A utility-priority task streams entries from one directory at a time with
   `opendir`/`readdir`, checks cancellation between entries, skips packages,
   symbolic links, protected locations, other accounts, and broad app-private
   Library data, records regular-file identity with `lstat`, and retains the
   number of directory entries checked plus the exact safety cap in results.
   User exclusions are checked before opening each directory; their matched
   paths are listed separately from unreadable locations in scan results.
4. Findings are classified with configured size/age thresholds and isolated
   cache rules. Exact-duplicate candidates are grouped by size, partial SHA-256
   samples, then streamed through full SHA-256 hashing. Files are rechecked
   after hashing. Hard-linked files are excluded from duplicate groups.
5. Results are displayed with paths, sizes, modification dates, rationale,
   confidence, and a suggested duplicate copy to retain. Full-disk findings can
   be filtered by Desktop, Documents, Downloads, Pictures, or other checked
   locations. Low-risk selection is limited to the findings currently shown.
   Nothing is preselected.
6. On confirmation, the safety service checks the selected root boundary,
   protected paths, symlink-free ancestry, file identity, file type, and hard
   link count again. Eligible files are moved through `FileManager.trashItem`.
   Per-file failures are shown in the result view. These separate path-based
   validation and Trash steps reduce stale-path risk but cannot eliminate a
   hostile concurrent path replacement.

Space Lens reads direct-file metadata on demand for the currently open folder,
using the scan's still-active security-scoped access. It opens each directory
component relative to a file descriptor with symlink following disabled and
uses `fstatat` without following symlinks. The browser is capped at 50,000
directory entries per folder, reports partial listings and skipped items, and
never reads file contents. Quick Look opens only after a user clicks Preview.
Only current scan findings can be selected for cleanup; other visible files
are preview and Finder-reveal only.

App Leftovers separately compares exact bundle-ID names in four top-level
locations under the current user's Library with identifiers from standard
Applications folders. It reads top-level names and basic item metadata only;
it does not recurse into folders or calculate folder sizes. Incomplete installed-
app inventories make results view-only. Results start unselected, and the UI
requires a Finder-review acknowledgement before selection. Before a confirmed
move to Trash, the service repeats the installed-app, running-app, path, and
identity checks. This is a conservative name-based hint, not proof that data is
orphaned.

Device Backups reads names and filesystem metadata only from the current user's
standard `Library/Application Support/MobileSync/Backup` folder. It fingerprints
each checked path and its type, inode, size, and modification time so a backup
that changed after review cannot be moved. Folders with missing backup metadata,
symlinks, unreadable entries, or more than the safety limit are view-only. A
confirmed selection moves each unchanged backup folder to Trash; the service
does not open backup contents or empty Trash. The displayed date is the newest
file-modified date, not a verified backup completion time. Expected metadata
does not prove that a backup is complete or restorable. Enumeration streams
directory entries, reports progress, and discards partial candidates on cancel.
It caps work at 250,000 entries per backup, 500,000 entries total, and 1,024
top-level folders per scan.

Xcode Device Support inventory reads names and filesystem metadata only from
the current user's standard `Library/Developer/Xcode/iOS DeviceSupport` folder.
Eligible folders receive a complete-tree fingerprint; a confirmed Trash action
rechecks every path, inode, device, size, modification and change time, type, and
link count before moving the folder. Linked, hard-linked, cross-volume,
unreadable, unsupported, changed, or over-limit trees remain in place. Xcode is
checked again immediately before each move. The operation never opens file
contents or empties Trash.

## Data and background work

Scans run off the main thread and check for cancellation during streamed
enumeration and hashing. The initial implementation keeps scan metadata and
findings in memory, with a 1,000,000-entry safety cap and partial-result reporting.
User-selected exclusion paths are stored locally in `UserDefaults`; they are
never added to activity history or transmitted. Activity history contains only
dates, counts, byte totals, event categories, and summary text. Scanned file
names, contents, and credentials are not stored or transmitted.

## Current system integrations

- Unsandboxed app process using macOS file permissions, TCC, and Full Disk
  Access controls for local file access.
- Finder reveal for selected results.
- FileManager Trash operation.
- Foundation volume-capacity metadata.
- Mach host CPU and VM statistics, sampled only while a monitor view is open.
- Active `en` interface byte counters, local non-internal-volume metadata, and
  system uptime, sampled or read only while a monitor view is open.
- Dispatch memory-pressure events, reported as events from macOS rather than
  inferred from free-page counts.
- IOPowerSources battery state and health, plus the public IOPM battery-info
  call for cycle count where macOS returns it.
- Status-only authorization queries for camera, microphone, Contacts, Screen
  Recording, and Accessibility; they never request access.
- A pure Mac Health assessment that weighs available storage (35%), memory
  pressure (25%), battery condition (25%), and the startup disk's SMART status
  when reported (15%). Missing signals are omitted and the remaining weights
  are rescaled.

No helper, background agent, cloud client, mail client, browser extension,
native messaging host, or system-permission modification is included. The
App Updater makes network requests only when the user starts a manual update
check. The Maintenance view opens Apple Disk Utility and System Settings when
needed; it does not perform privileged maintenance tasks or run a background
helper. Hardware temperature is not exposed through a supported API used by
this monitor.
