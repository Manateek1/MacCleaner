# Feature status

Mac Cleaner 0.5.6 build 109 builds on the first usable local-only beta
(0.4.0). The features below run in the app; they are not navigation placeholders. The suite
covers whole-Mac file review, conservative cleanup tools, local app and health
inventories, and review-first moves to Trash. Remaining platform boundaries and
release-quality checks are listed below. Cloud storage, email, Chrome
extensions, and browser messaging are outside the requested scope.

## Implemented in the current milestone

- Native SwiftUI window and sidebar navigation.
- Keyboard navigation from the Navigate menu: Command-1 through Command-9 open
  Overview, Smart Scan, Large & Old Files, Exact Duplicates, Similar Photos,
  System Junk, My Tools, Privacy & Permissions, and Activity. Settings lists
  these shortcuts; Command-comma opens the standard macOS Settings window.
- First-run scan and privacy notice with a one-time, locally saved
  acknowledgement. The notice explains what is read, what is skipped, and
  that cleanup requires a separate choice and confirmation. Mac Cleaner uses
  Full Disk Access for local scans and starts at the Mac's disk root after the
  user enables it once in System Settings; no folder picker is needed for each
  scan. Photos is requested only when the user selects it and is not requested
  again after macOS records a choice.
- Overview with live volume capacity information.
- Local disk scans after Mac Cleaner confirms it can open Documents and
  Downloads. This permission check opens only those two directories; it does
  not list their contents. If macOS blocks access, Mac Cleaner opens the
  relevant settings and explains how to enable Full Disk Access. The app starts
  at the disk root directly and does not ask the user to choose Macintosh HD.
  Full Disk Access can be turned off in System Settings.
  Specific-folder scans remain available.
- Full-disk traversal streams directory entries, reports location and file
  progress, limits waits for folders that do not open promptly, checks
  cancellation while walking, and caps the total locations inspected. It scans
  the signed-in account, including accessible Library metadata, and accessible
  local account folders outside their Library directories. Ordinary files in
  the signed-in account's Library stay view-only; only recognized cache/log
  candidates can be moved to Trash after review. Other accounts' Library data
  is skipped; their other accessible files are view-only. It also scans
  `/Users/Shared`, selected system cache/log folders, accessible non-user areas on the system disk, and
  connected, mounted local external volumes when accessible. If the Desktop
  is iCloud-backed, it reads metadata only for files already stored locally and
  marks their results read-only. It reports how many local Desktop files it
  checked and skips cloud-only or downloading items without downloading them.
  Exact duplicate hashing and Similar Photos skip
  iCloud items. Other iCloud Drive areas, network volumes, protected system
  folders, other accounts' Library data, protected app-state folders, and
  developer toolchain folders are skipped.
  Unreadable locations are counted in the scan results. The result shows
  how many files and folders were checked, names up to five inaccessible paths,
  and counts any paths omitted from the concise summary. Reaching the safety cap
  is labeled as a partial scan and identifies the configured limit.
- Read-only Smart Scan across large and older files, exact duplicates,
  recognized caches/logs, and recognized AI-tool temporary files, with progress,
  cancellation, skipped-item counts, and explicit scan results. A full-Mac Smart
  Scan then checks installed app signatures and readable startup items using the
  same App Security review shown on its own page. It records aggregate results
  without storing app names or paths, and offers a direct link to the detailed
  review. Folder-specific scans do not run a Mac-wide App Security check.
- Large and old files with configurable thresholds. Specialized file-review pages
  filter a saved Smart Scan to the current tool’s categories. Switching tools
  clears the prior selection, and category totals update after cleanup.
- Exact duplicate file detection using size grouping, partial hashes, and full
  streamed SHA-256; a saved oldest- or newest-modified suggestion is marked to
  keep, and users can choose a different copy to keep while other accessible
  copies currently shown are checked for review. Hard-linked files are excluded.
- Conservative cache/log and AI-tool cache candidate rules. The default Xcode
  Derived Data, Simulator, Homebrew, pip, and npm caches are identified by tool
  and get specific plain-language explanations. Xcode archives, Simulator
  device data, and `node_modules` dependencies are excluded from these cache
  rules.
- Local AI Models inventories model names and logical sizes from common Ollama,
  Hugging Face Hub, and LM Studio locations, and searches the current user's
  home folder for recognizable model-weight files elsewhere. It reads small
  Ollama manifests and filesystem metadata, never opens model weights or
  connects to an online service. Results start unchecked. A separate review
  lists every selected model and its path before one confirmation moves items
  to Trash. Ollama cleanup moves the selected model record and only blobs no
  longer referenced by other readable models; Hugging Face and LM Studio move
  only the selected repository/model folder; other locations move only the
  recognized model-weight files. The service rechecks file identity and
  protects changed items, hard links, protected locations, and links that lead
  outside a model folder. Activity stores only a generic cleanup summary with
  no model names or paths.
- Plain-language explanations with expandable technical details, Quick Look
  previews, search by name/location, category filters, file-type grouping, and
  an estimate of potential space to review. Full-disk results can be filtered
  to Desktop, Documents, Downloads, Pictures, or other checked locations. The
  low-risk selection button applies only to the results currently shown. Large
  result lists load in batches. The latest full-disk review is saved locally
  with its names and paths so it survives a restart; Settings can clear it.
- Similar Photos compares local images with orientation-aware thumbnails,
  perceptual hashes, and a compact color sample to reduce false matches between
  unrelated pictures with similar light and dark patterns. It scans image
  formats registered with ImageIO on this macOS version, including photo and
  camera RAW formats plus Photoshop, PICT, and TGA when available. It excludes
  medical images, texture containers, icons, and HEIC/MPO multi-picture
  sequences. Animated GIF and WebP files are compared by their first frame. It
  distinguishes byte-identical files using full SHA-256
  checks from photos that only look alike, and uses hash bands to narrow visual
  comparisons. Match tolerance is saved locally and shared between the scan
  screen and Settings, with plain labels for strict, balanced, and broader
  matching. It also scans Photos-library images that are locally available,
  without downloading iCloud content. It shows previews, dimensions, dates, and
  a highest-resolution keep suggestion. Selection is manual; at least one
  current photo per group must remain before local files go to Trash or selected
  Photos items are removed after a separate confirmation. Automated integration
  coverage dynamically exercises every writable still-image format registered
  with ImageIO and enabled by the scan policy on the test Mac; that format set
  varies by macOS version.
- Space Lens shows proportional folder sizes and file-type summaries from the
  latest scan. It supports folder drill-down, breadcrumb navigation, and
  recursive folder search, and browses and previews direct files inside the
  accessible scan root. It reads
  only file metadata until a user opens Quick Look. Only files already flagged
  by the scan can be selected for Trash review; other files are preview-only.
- Applications lists apps found in standard Applications folders, with bundle
  identifiers, versions, logical bundle sizes, search, Finder reveal, and batch
  selection.
- App removal reviews the exact app bundle and optionally selected related-data
  locations before moving them to Trash. Reset App moves only selected data and
  leaves the app installed. All related locations start unchecked; exact
  bundle-ID matches alone do not prove ownership. Locations with sensitive
  names or incomplete inspection are unavailable. The filter does not inspect
  file contents. Apple apps and Mac Cleaner are protected, running apps are
  refused, and batch review skips apps that cannot be reviewed while keeping
  eligible apps available. User login helpers are included only when their
  program points directly into the app bundle; helpers with environment or
  sign-in settings stay unavailable. Symlinked paths and changed helper
  definitions are rejected, and app identity is revalidated before action.
- App Updater lists installed app versions and their declared update source.
  It checks a selected Sparkle HTTPS feed for version metadata only, keeps the
  last check locally, and records each app's version/build inventory by local
  app path. Later scans show observed changes and clearly state that Mac Cleaner
  cannot tell which updater caused them. The first scan creates a baseline;
  local history is bounded to 1,000 apps and 90 days for apps no longer found.
  It also checks Homebrew cask updates when the user starts a check, using
  Homebrew's available metadata. It disables Homebrew auto-updates and analytics
  for the command, displays the installed and listed versions, records the
  latest result locally, and can copy—but never run—the Homebrew update command.
  It routes App Store and Apple updates to their native update apps. It never
  downloads or installs an update; use the source app to apply it.
- App Security checks each installed app's signature, sealed resources, and
  embedded code across architectures, and whether a Team ID is present. It
  reports progress, can be cancelled, and distinguishes missing signatures
  from checks macOS could not complete. For an individual app, users can also
  run an additional code-signature and certificate trust check for one app.
  The startup review also calls out launch programs placed in temporary folders
  or Downloads so users can check whether that location is intentional. This
  location signal is context, not a malware finding.
  That optional check may contact Apple's certificate and notarization services.
  It does not change files or call an app malicious.
- App Leftovers checks exact bundle-ID names and a small, fixed set of familiar
  suffix variants in the current user's Application
  Support, Caches, Preferences, Containers, Logs, Saved Application State, and
  Application Scripts locations against readable app bundles in
  `/Applications`, `~/Applications`, and `/System/Applications`.
  A suffix variant appears only when another safe, exact unused identifier
  anchors the possible match. The app labels it as unconfirmed, never selects
  it automatically, and requires a separate Finder review before it can move
  to Trash.
  It uses file names and size metadata to estimate folder sizes and flag
  sensitive-looking paths; it never opens file contents. Results start
  unchecked. Open each exact path in Finder and acknowledge that you reviewed
  it before selection. Sensitive, incomplete, or unreadable folders stay
  unavailable. A name match does not prove the data is unused. It also lists
  current-user App Group folders and matches them only to valid signed access
  declarations from apps in those standard locations. App Group folders are
  view-only because app copies or helpers outside the inventory may share them.
- Startup & Background lists readable launch agents and launch daemons from
  the current user, shared Library, and Apple system Library, plus launch
  plists and LoginItems bundled in apps found in standard Applications folders.
  It shows declared purpose, launch conditions, executable, disabled flag,
  signature information, and legacy authorization when available. macOS does
  not expose another app's bundled-helper registration status to this review;
  recent Login Items open in System Settings for management.
- Finder reveal, explicit selection, clear/select-eligible controls, file
  identity revalidation, system/protected path checks, and moving selections
  to Trash after confirmation.
- Space Lens selection, Finder reveal, and storage refresh controls expose
  descriptive labels to VoiceOver.
- Local activity summaries without file names or paths.
- Device Backups reviews folders in the current account's standard local
  iPhone/iPad backup location. It shows folder names, file counts, logical
  sizes, and the newest file-modified date without opening backup contents.
  The inventory reports progress and can be cancelled; cancelling discards
  partial cleanup candidates.
  Only folders with expected backup metadata and fully checked, symlink-free
  contents can be selected. Users confirm the exact paths, attest no backup or
  sync is running, and move selected backups to Trash; incomplete, unreadable,
  symlinked, changed, or safety-limited folders stay in place.
- Diagnostic Reports reviews `.crash`, `.ips`, `.diag`, `.hang`, `.spin`, and
  `.panic` reports in the current account's standard local DiagnosticReports
  folder. Reports newer than the chosen 30, 90, 180, or 365-day cutoff stay out
  of the list. The scan reads metadata only; Quick Look opens contents only
  when requested. Results start unchecked. Selected reports are revalidated
  and move to Trash only after a separate review of their exact names. Report
  names, paths, and contents are not added to activity history.
- Xcode Storage inventories `.xcarchive` builds in Xcode's standard local
  Archives folder, including date-grouped archives. It shows names, locations,
  modified dates, file counts, and logical sizes without opening file contents.
  Fully checked archives with ordinary files can be selected, rechecked against
  their scan snapshot, and moved to Trash after one review of exact names and
  paths. Archives may contain app builds and debugging symbols; Xcode must be
  closed. Linked, shared-file, unreadable, incomplete, unsupported, or
  over-limit archives remain view-only. No archive is moved automatically.
- Xcode Storage also inventories folders in the standard local iOS Device
  Support location by name, location, modified date, file count, and logical
  size without opening file contents. Fully checked folders with ordinary,
  unshared files can be selected, rechecked against their scan snapshot, and
  moved to Trash after one review of exact names and paths. Xcode must be closed.
  Linked, hard-linked, unreadable, changed, incomplete, unsupported, and
  over-limit folders remain view-only. Custom device-support locations and other
  Xcode storage are not included.
- Activity offers 7-, 30-, and 90-day views for recorded scans, cleanup actions,
  App Security checks, and app update checks. Security summaries contain only
  aggregate counts; app names, bundle identifiers, findings, and paths are not
  stored. The 90-day view groups by week. Activity retains up to 500 local
  summaries without file names or paths. Older known event types are inferred
  when the app reads them.
- Optional scan-complete, cleanup-complete, App Security, app update source,
  and user-started Mac Health notifications use generic copy
  with no file names or paths. macOS authorization is requested only when a
  notification is first enabled, and each notification preference can be
  changed independently in Settings.
- Read-only CPU utilization, active/wired/compressed/free memory-page totals,
  current swap usage, macOS memory-pressure events, volume capacity, battery
  charge/power state,
  Apple-reported battery condition, cycle count when available, active network
  transfer rates, mounted local non-internal-volume capacity, and time since
  restart in Performance. Users choose which system monitor readings appear
  in the menu-bar panel. Sampling pauses when monitored views are closed.
- Live CPU and resident-memory rankings for readable processes owned by the
  signed-in account, with a direct link to Activity Monitor for its broader
  system view. Settings can show the top 5, 8, or 12 entries. The process
  sample is read-only and stays in memory.
- Mac Health displays a limited, explainable score from available storage (25%),
  macOS memory-pressure events (20%), Apple-reported battery condition (15%),
  startup-disk status when reported (15%), FileVault and Firewall state (5%
  each), Gatekeeper and System Integrity Protection state (5% each), and the
  user-started Apple update result (5%). Missing or unrequested checks are
  omitted and the remaining weights are rescaled.
  Storage guidance uses visible 20% and 10% available-space thresholds; the
  score is not a hardware diagnosis.
- Mac Health also reports read-only FileVault, firewall, Gatekeeper app
  assessment, and System Integrity Protection states when macOS returns a
  recognizable result. Unknown output stays “Not reported”; this is not a
  malware scan and Mac Cleaner does not change those settings.
- Mac Health reads the startup disk’s macOS SMART status on demand and includes
  this signal in the score when reported. It labels
  only an explicit “Failing” report as needing attention, keeps unsupported or
  unknown output as “Not reported,” and makes no prediction about future drive
  failure.
- Mac Health checks Apple’s available software updates only after the user
  clicks Check for Updates. It uses the list-only system command, reports known
  update names and versions, and does not download or install updates. The check
  contacts Apple but sends no scan findings or file names; it never runs on page
  open.
- Maintenance shortcuts open Mac Cleaner's review screens or Apple Disk Utility
  and System Settings. No privileged helper, scheduled cleanup, or automatic
  system change runs in the background.
- Mac Health & Maintenance can list Time Machine local snapshot names and dates
  on the startup volume. It does not estimate snapshot sizes or thin/delete
  them; Apple manages their storage.
- Full Disk Access provides the local scan permission. This build is not App
  Sandbox restricted because macOS sandbox rules prevent Full Disk Access from
  reaching protected standard folders. macOS can still restrict additional
  locations independently.
- Settings shows the installed app version and explains the local file-handling
  behavior. Folder exclusions are stored locally, apply to future scans, and
  never include the entire disk root.
- Settings can save selected folders using macOS security-scoped bookmarks and
  run Smart Scan on them again without reopening the folder picker. Removing a
  saved shortcut removes only its bookmark; it does not change the folder.
- Settings can save System, Light, or Dark appearance. Light is the default,
  and the preference applies to the main window, Settings, and menu bar panel.
- Settings can restore appearance, file-review settings, tool favorites, and
  menu-bar readings to their defaults after confirmation. Disk access, scan
  exclusions, saved scan folders, activity history, and files are preserved.
- Diagnostics export includes app and macOS versions, processor architecture,
  scan totals, access status, and review thresholds. It omits file names and
  paths, account names, excluded-folder names, and file contents.
- Privacy & Permissions shows whether Documents and Downloads are accessible
  under Full Disk Access, the current Photos
  permission state, and no-prompt camera, microphone, Contacts, Screen Recording,
  and Accessibility status checks with links to their System Settings panels.
  Those optional permissions are not used or requested by Mac Cleaner. The page
  also describes one-time, user-started HTTPS app update checks.
- Privacy Cleanup reviews recognized local Safari, Chrome, and Firefox cache
  folders. It requires the browser to be closed before moving its cache to
  Trash, rechecks the exact folder before the move, and never includes browser
  history, download lists, cookies, site storage, passwords, or downloaded
  files. Chrome support is limited to known cache folders under its local cache
  profiles; Chrome profile databases remain untouched. The page links to each
  browser's own privacy controls for other items.
- My Tools provides searchable shortcuts to implemented Mac Cleaner sections
  and locally saved favorites. Downloads starts the whole-Mac scan and filters
  review results to that folder. Trash opens Finder so users can restore or
  manage trashed files; Mac Cleaner does not empty Trash.
- Screen Cleaning Mode temporarily covers connected displays with a plain
  surface. It exits on Escape, a visible button, or a 30-second, one-minute,
  or two-minute timer and does not request permissions or change files.
- Unit tests for duplicates, hard links, symlinks, sensitive paths, old/large
  thresholds, AI cache rules, path containment, changed files, and selected
  roots replaced by symlinks, duplicate survivor validation, stale group
  removal after cleanup, and CPU counter-delta calculations.

## In progress / limitations

- Scans retain metadata in memory and stop at one million filesystem entries,
  including folders, returning and clearly labeling partial results instead
  of discarding them. At most 50 inaccessible paths are stored per result, and
  the UI displays up to five examples while retaining the full inaccessible
  location count.
- Disk scans prioritize the current account, other accessible local account
  folders, selected system cache/log folders, and accessible top-level
  system-disk locations. The current account's Library is scanned for
  metadata, but ordinary app data remains view-only; only recognized
  cache/log candidates can be moved to Trash. Other accounts' Library data,
  protected app-state folders, network volumes, cloud-only iCloud items and
  other iCloud Drive areas, plus protected system areas are skipped. Other
  account findings remain view-only. Locally stored iCloud Desktop metadata is
  the read-only exception. macOS can deny additional locations; errors are
  counted and shown.
- User exclusions skip an exact folder and its descendants in future scans.
  A selected custom-folder scan inside an excluded location is blocked with a
  Settings link in its explanation. Exclusions do not rescan or alter a review
  that is already open.
- Duplicate storage totals are logical file sizes. APFS clone block sharing
  cannot be measured by this implementation, so actual reclaimed space may be
  lower than the logical estimate.
- Cache and AI rules are intentionally conservative and cover only selected
  folders. They do not claim complete app-by-app detection.
- Local AI Models searches only the current user's home folder and known local
  provider folders. It recognizes selected model file extensions and can miss
  uncommon formats or models stored in other user accounts or protected areas.
  It does not inspect model contents. Per-model logical sizes can overlap; the
  unique total deduplicates repeated references to the same file identity but
  cannot measure APFS clone sharing. Cleanup asks the user to close apps using
  the selected models first; it cannot verify that a model is idle. Shared
  Ollama blobs stay in place while any readable model references them. Changed,
  unreadable, linked, or over-limit model folders stay in place rather than
  being partially removed.
- Results can group by filename extension or sort by file size, modification
  date, last access date, or name. Files without extensions are grouped
  together. Access times come from
  filesystem metadata; they can be unavailable or approximate, and unknown
  dates sort last. The suggested duplicate copy follows the saved oldest- or
  newest-modified preference, then path order. Choosing a different copy checks
  other accessible copies in that group for review; files still move to Trash
  only after the separate confirmation.
- Space Lens folder sizes, recursive folder search, and file-type totals cover
  only locations and files included in the scan. Its direct-file browser reads
  metadata for up to 50,000 entries in the open folder, skips protected or
  unreadable items, and does not browse outside the granted scan root. Files
  that were not flagged remain preview-only. A cleanup invalidates the size
  map until rescan.
- Network rates are sampled from active `en` interfaces and can omit virtual
  or other non-Ethernet-style interfaces. The first reading establishes a
  baseline. External-drive details include mounted local volumes macOS marks
  non-internal; network volumes are excluded. Mounted disk images may appear
  alongside physical drives. Process rankings show only details that macOS
  exposes for the signed-in account; system-owned processes and other hidden
  activity remain in Activity Monitor. CPU is shown per core and can exceed
  100% when a process uses multiple cores.
- Memory pressure is displayed when macOS sends a pressure event after the
  monitor starts; until then its state is shown as waiting rather than inferred
  from free memory. Battery health and cycle count appear only when macOS
  provides them. Hardware temperature is not exposed through a supported API
  used by this app. CPU, memory, storage, network, uptime, and battery readings
  refresh every two seconds only while Performance, Mac Health, or the menu-bar
  panel is visible.
- The Mac Health score uses storage, memory pressure, battery condition,
  startup-disk status, four selected macOS protection settings, and an optional
  Apple update result. Its weights and unavailable-check behavior are shown in
  the app. It does not assess other disk diagnostics, process load, or startup
  impact, and it is not an Apple diagnosis or malware verdict.
- The Maintenance page does not run DNS cache flushes, Spotlight reindexing, or
  Time Machine snapshot thinning. Those operations need more system-level
  control than the app's supported interface provides; the page opens Apple tools instead of
  claiming that a privileged task ran.
- System-wide cache/log candidates remain view-only. Older reports from the
  current account's standard DiagnosticReports folder have a separate, explicit
  Trash review. Browser profiles/data, archives
  and device-support folders outside Xcode's standard locations, backups
  outside the standard location, and custom package-manager cache locations are
  not comprehensively scanned. Xcode device-support folders that cannot be
  completely verified stay view-only, as do archives that cannot be completely
  verified.
  The recognized Xcode, Simulator, Homebrew, pip,
  and npm cache roots are only their common defaults; cache file contents are
  not opened. App
  Leftovers checks exact names and a fixed suffix list in seven common
  locations in the current user's Library; suffix suggestions require an exact
  unused identifier in another checked location and can still be wrong. It
  does not search arbitrary names, other accounts, external drives, or apps
  installed in custom folders. Its App Group view
  lists current-user group folders and valid signed owners found in standard
  Applications folders, but cannot prove that an unlisted app copy or helper
  does not also use one; these folders are never offered for cleanup. It can
  miss real leftovers and can also list data still used by an
  app outside the scanned Applications folders. Folder sizes are logical
  estimates based on file metadata; the scan never reads file contents and
  marks sensitive, packaged, truncated, or unreadable folders unavailable.
  Folder selection requires a separate Finder review and acknowledgement.
- Safari history and website data use Safari's own controls because clearing
  history can affect devices using Safari in iCloud and removing website data
  can sign users out. Firefox keeps bookmarks, download history, and browsing
  history in one profile database, so Mac Cleaner opens Firefox's privacy
  controls instead of removing that database. Chrome history, cookies, saved
  passwords, downloads, and profile storage are not included in cleanup.
  Recent-document references and other macOS activity records are not modified.
- Device Backups checks only the current account's standard local MobileSync
  backup folder. It does not inspect other accounts, custom backup locations,
  connected-device state, or iCloud backups. The displayed date is the newest
  file-modified date, not a verified backup completion time. Expected metadata
  does not prove that a backup can restore a device. Sizes are logical sums and
  may not equal space reclaimed when storage is shared or cloned.
- GitHub can publish a tested Apple silicon developer-preview ZIP as a marked
  prerelease. The app is ad-hoc signed, with no Apple Developer ID signature or
  notarization, so Gatekeeper may warn about or prevent opening it. A notarized
  release is not available yet; local builds are also for development and
  testing.
- To use Full Disk Access for a whole-Mac scan, this build is not restricted by
  App Sandbox. While Full Disk Access is enabled, Mac Cleaner can read protected
  local files outside its app folder. Scans remain read-only; cleanup still
  requires selection and confirmation. macOS can continue to block some areas,
  which are reported as skipped. Full Disk Access can be turned off in System
  Settings. Local development builds and the marked preview use an ad-hoc
  signature. The preview does not pass Gatekeeper's Developer ID and
  notarization checks; a frictionless public release still requires those
  checks.
- Application sizes exclude symlinks and shared support data, may be partial,
  and are not a measure of space that can definitely be recovered. Inventory
  is limited to accessible standard Applications folders.
- App Updater checks Sparkle HTTPS feeds declared in app metadata and Homebrew
  cask metadata when the user asks. A Homebrew result uses its available
  catalog, which can be stale. Mac Cleaner disables Homebrew auto-update and
  analytics for the command, but Homebrew may contact its configured update
  source. Neither source downloads or installs packages, and Mac Cleaner does
  not independently verify feed signatures or update packages. It can report
  version/build changes observed between app inventories, but cannot prove
  which updater caused them or verify the installed files. App Store receipts
  are detected, but per-app availability
  is not queried; use the App Store to review its Updates page. Other apps must
  be checked in their own updater.
- App Security verifies app signature integrity, sealed resources, and nested
  code across architectures. An optional code trust check validates signing
  certificates and notarization where macOS can establish them, but it is not a
  malware scan or a verdict about developer reputation. Missing or
  unverifiable signatures require context and are not a malware verdict. A
  cancellation waits for the current bundle's integrity check to finish. It
  also reviews user and shared launch definitions, checking macOS approval
  status, the listed program's signature, and whether its path is under a
  temporary folder or Downloads. The path is only a reason to verify that the
  startup choice is intentional. Review findings are explanations, not malware
  verdicts; this does not include every modern background item or inspect live
  processes.
- App-data review during removal covers exact bundle-ID paths in seven common
  locations in the current user's Library and user login helpers that point
  directly into the app bundle. App Leftovers covers exact bundle-ID paths and
  carefully constrained suffix suggestions in those seven Library locations,
  and displays shared App Group folders with their known signed owners without
  offering them for cleanup. Suffix suggestions remain unconfirmed until the
  user checks the exact path. These tools do not find every associated file,
  login item, subscription, or
  app-managed data store. Their sensitive
  data filter uses path names and metadata, not file contents, so it cannot
  guarantee a selectable folder contains no private state. Selected folders may
  contain data the app can recreate or needs; inspect their exact paths and
  keep anything uncertain. Some apps require their own uninstaller.
  Revalidation reduces but does not eliminate filesystem races.
- Startup definitions are not a complete list of modern login items or running
  processes. macOS does not expose a supported API for this app to toggle other
  apps' login items, so those changes open System Settings. Launch conditions
  and disabled flags describe plist configuration, not live process state.
  Signature validation is not a malware or publisher-trust verdict.
- Similar-photo matching uses brightness and color samples, aspect ratio, and
  approximate visual fingerprints, so it can still miss matches or suggest
  different images. Disk scans prioritize Pictures, Desktop, Downloads and
  Documents and skip the account Library to avoid treating app assets as
  personal photos. It stops after 10,000 image files and reports partial
  results. Exact file hashing is capped at 4 GB per scan and reports when that
  limit prevents byte-for-byte verification. Image files larger than 256 MB
  are skipped to keep image comparison within a 256 MB per-image read limit.
  Photos-library scans stop after 10,000 assets, skip previews unavailable on
  this Mac, and never download from
  iCloud. Removing Photos items changes the library and may sync through iCloud
  Photos. APFS sharing means logical sizes are not guaranteed savings.

## Planned milestones and backlog

### Remaining local system and app management boundaries

- Provider-specific local model removal through each model manager where a
  supported, user-controlled interface can be used safely.
- Modern background-item visibility beyond the readable launch-agent and
  launch-daemon folders, and management where supported.
- Other independently verifiable update sources beyond Sparkle, Homebrew,
  App Store handoff, and native updater routing still need individual review.
- Validated malware scanning options and conservative findings. Code signature
  and certificate trust checks are available per app; the audit still does not
  detect malware.
- Safe maintenance actions for DNS and Spotlight if a supported, user-controlled
  approach can be implemented without a persistent privileged helper. Time
  Machine snapshots are view-only; thinning is not offered because this app does
  not use a privileged maintenance helper. Memory pressure, battery health,
  and cycle count are displayed when reported by macOS.
### Remaining release-quality work

- Additional feature-specific settings beyond appearance, file-review
  thresholds, saved scan folders, exclusions, notification preferences,
  process-ranking row count, menu-bar readings, and the saved Similar Photos
  match tolerance.
- Startup impact is not measured because macOS does not provide this app a
  reliable per-item performance impact value. Counts of startup definitions are
  not a substitute for an impact measurement.
- Additional per-feature settings may be useful after the current settings are
  evaluated with everyday use. Available completion alerts already cover
  scans, cleanup reviews, App Security, app updates, and user-started Mac Health
  checks.

### Explicitly out of scope for the local-only app

- Cloud storage cleanup, Gmail/email cleanup, Chrome extensions, native
  messaging, and other account-connected browser or cloud tools.
- App Updater already performs user-started HTTPS checks for version metadata;
  it does not download or install app updates. A user-started code trust check
  may contact Apple's certificate and notarization services. Scan data and
  results stay local. Malware-definition downloads are not included.

### Future local security and privacy work

- Privacy cleanup for recent-document references, recent-app references, and
  other supported macOS activity records. App Security now checks a limited
  set of user and shared launch definitions; broader modern background-item
  visibility and management remain unfinished.
- Research reputable malware-scanning options, license compatibility,
  signature verification, and conservative heuristic detections. Do not claim
  antivirus coverage without a validated engine.
- Provider-specific model deletion remains omitted where it would bypass the
  current review-and-Trash safeguards or require an unsupported destructive API.
- Evaluate Endpoint Security and other platform restrictions before adding any
  background or real-time monitoring.

### Phase 5: broader QA and distribution

- Independent feature-level accessibility and keyboard-navigation review,
  broader light/dark and resizing coverage, and live large-tree/performance
  runs on Tahoe 26+ Apple silicon remain future QA.
- The developer-preview workflow builds and tests an arm64 app on macOS 26,
  ad-hoc signs the app bundle, and publishes a checksum-verified GitHub
  prerelease without Apple credentials. The app is not Developer ID signed or
  notarized, and Gatekeeper may block it.
- The separate signed release workflow signs with a Developer ID certificate,
  submits the app to Apple notarization, staples the ticket, and attaches the
  verified ZIP and checksum to GitHub Releases. It requires maintainer-owned
  signing credentials in GitHub Actions secrets.
- The ad-hoc signed preview is a developer download, not a frictionless install.
  Frictionless distribution remains unfinished until signing and notarization
  are configured.
