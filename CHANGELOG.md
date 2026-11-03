# Changelog

## 0.5.4 - 2026-11-02

- Include current-account Library metadata in whole-Mac scans so file sizes,
  duplicates, and recognized cleanup candidates are visible in one review.
- Keep ordinary Library app data view-only; recognized cache and log candidates
  still require the same selection and Trash confirmation.
- Continue skipping protected app-state folders and other accounts' Library data.
- Protect Rustup, Cargo, Node, Python, Java, and Conda toolchain folders from
  duplicate cleanup suggestions.

## 0.5.0 - 2026-11-02

- Add a user-started Homebrew cask update check with local result history and
  copyable update commands; Mac Cleaner never updates Homebrew or installs apps.
- Include reported FileVault, Firewall, Gatekeeper, System Integrity Protection,
  and Apple update status in the explainable Mac Health score.
- Keep unavailable or unrequested health checks out of the score and rescale
  the remaining published weights.
- Add an optional generic completion alert for user-started Mac Health checks;
  notification access remains off until enabled in Settings.

## 0.4.0 - 2026-11-02

- Add read-only swap-memory usage to the Performance screen and menu bar panel.
- Show swap values only when macOS reports a valid capacity and usage pair.
- Add a Downloads shortcut that runs the full-Mac scan and filters the review
  to Downloads.
- Add a Trash shortcut that opens Finder; Mac Cleaner never empties Trash.

## 0.3.90 - 2026-11-01

- Keep slow iCloud Desktop directory opens from exhausting the open capacity
  used to scan regular local folders such as Documents and Downloads.

## 0.3.89 - 2026-11-01

- Keep protected-folder status checks out of full-Mac scans. Check access from
  Privacy & Permissions or after returning to that page from System Settings,
  while scans read folders directly and report anything macOS still blocks.
- Restore saved Desktop folder access without opening a cloud-backed directory
  on the scan action; check local Desktop copies during the scan.
- Isolate slow iCloud Desktop opens so they cannot use up the directory-open
  capacity reserved for local folders such as Documents and Downloads.

## 0.3.88 - 2026-11-02

- Start full-Mac Smart Scans without waiting for protected-folder access checks
  on the main window. Keep app checks and system-tool access probes off the UI
  thread, and allow scans to report inaccessible locations without freezing.

## 0.3.87 - 2026-11-02

- Extend full-Mac Smart Scan with the existing read-only app signature and
  startup-item review. Show progress, preserve partial file results if the user
  stops the security check, and reuse the result when opening App Security.
- Clarify that signature checks provide context and are not malware detection.

## 0.3.86 - 2026-11-02

- Clarify Full Disk Access and local file access status in system-tool screens.
- Explain the app's broader access model during first-run review and in the
  privacy settings.

## 0.3.85 - 2026-11-01

- Use macOS Full Disk Access for whole-Mac scans so the app can include protected
  standard folders without the App Sandbox blocking them.
- Start the full-Mac scan directly after the one-time access setup instead of
  asking the user to choose Macintosh HD when a bookmark is unavailable.

## 0.3.84 - 2026-11-01

- Grant the sandbox standard local Documents, Downloads, Movies, Music, and
  Pictures folder access needed for full-disk scans, and explain the folder
  access request in macOS's permission prompts.

## 0.3.83 - 2026-11-01

- Release temporary file-read buffers during duplicate hashing so large scans
  do not accumulate data in memory. Add coverage for duplicates larger than a
  single hash chunk.

## 0.3.82 - 2026-11-01

- Add an optional, off-by-default App Security completion notification using
  generic copy and the existing macOS notification permission.

## 0.3.81 - 2026-11-01

- Add privacy-safe App Security summaries to Activity and include security
  checks in its local trend chart.

## 0.3.80 - 2026-11-01

- Add plain-language context when a startup helper runs from a temporary
  folder or Downloads. The path is a review signal, not a malware verdict.

## 0.3.79 - 2026-11-01

- Extend Startup & Background and App Security to include launch plists and
  LoginItems bundled inside installed apps. For another app's bundled helper,
  Mac Cleaner reports its location and signature context but clearly marks
  registration status as unavailable.

## 0.3.78 - 2026-11-01

- Add a read-only App Security review of user and shared startup definitions,
  including macOS approval status and code-signature context. Findings are not
  malware verdicts.

## 0.3.73 - 2026-11-01

- Save Similar Photos match tolerance and expose it in Settings and Restore Defaults.

## 0.3.72 - 2026-11-01

- Include macOS-reported startup-disk status in the explainable Mac Health score.

## 0.3.71 - 2026-11-01

- Add Command-1 through Command-9 navigation shortcuts and list them in Settings.

## 0.3.70 - 2026-11-01

- Add a reviewed Trash action for completely checked local Xcode device-support
  folders. Xcode must be closed; changed, linked, shared, incomplete, unsupported,
  and over-limit folders stay in place.

## 0.3.69 - 2026-11-01

- Compare Similar Photos across image formats registered with ImageIO, including
  available camera RAW types, Photoshop, PICT, and TGA, while excluding medical
  images, texture containers, icons, and multi-picture sequences.

## 0.3.68 - 2026-11-01

- Reuse an active Macintosh HD permission for later scans in the same session
  when macOS cannot persist the disk bookmark, including after closing a scan
  review. Settings show session-only access accurately, and Forget Access ends
  that grant immediately.

## 0.3.67 - 2026-11-01

- Add an optional generic notification when an app update source check finishes.
  It reuses the existing macOS notification permission and does not disclose app
  names, versions, or feed addresses.

## 0.3.66 - 2026-11-01

- Give Space Lens selection, Finder reveal, and storage refresh controls
  descriptive VoiceOver labels.

## 0.3.65 - 2026-11-01

- Let users choose whether Performance shows the top 5, 8, or 12 process
  readings. The preference is saved locally and included in Restore Defaults.

## 0.3.64 - 2026-11-01

- Add live CPU and resident-memory rankings for readable processes owned by the
  signed-in account. Readings stay in memory, and Activity Monitor remains one
  click away for the broader system view.

## 0.3.63 - 2026-11-01

- Reduce false matches in Similar Photos by checking a compact color sample in
  addition to perceptual brightness patterns.
- Scan curated photo and camera RAW extensions only when the installed macOS
  ImageIO decoders report support for them.

## 0.3.62 - 2026-10-31

- Record installed app versions locally between App Updater scans and show
  observed changes without attributing them to a specific updater.
- Bound saved app-version history to 1,000 entries and 90 days for apps no
  longer present.

## 0.3.61 - 2026-10-31

- Fix Screen Cleaning Mode so its on-screen countdown displays the live time
  remaining instead of placeholder text.

## 0.3.60 - 2026-10-31

- App Leftovers now flags a fixed set of familiar app-data suffixes when an
  exact unused app identifier appears in another checked location. These
  possible matches stay unchecked and require Finder review; moving still
  revalidates both the path and its matching anchor before sending it to Trash.

## 0.3.59 - 2026-10-31

- Add a user-started macOS update status check using Apple's list-only update
  command. It reports available update names and versions without downloading
  or installing anything; scan results and file names are not sent.

## 0.3.58 - 2026-10-31

- Add local Chrome cache review for recognized web, code, graphics, image, and
  shader cache folders. Chrome must be closed before a selected cache can move
  to Trash; profile databases and site data stay untouched.

## 0.3.57 - 2026-10-31

- Add a read-only startup disk status check in Mac Health. Show a warning only
  when macOS explicitly reports a failing status; unsupported or unknown output
  remains “Not reported.”

## 0.3.56 - 2026-10-31

- Add an on-demand, read-only Mac protection panel for FileVault, the built-in
  firewall, Gatekeeper app assessments, and System Integrity Protection.
- Show unrecognized or inaccessible states as “Not reported”; the checks do
  not change settings, request permissions, or claim to scan for malware.

## 0.3.55 - 2026-10-31

- Preserve the latest full-disk findings in private, local app storage so a
  completed review survives an app restart or update. Names and paths remain
  on this Mac, and Settings can clear the saved review.
- Reopen saved findings for preview after restart; cleanup still requires a
  valid saved disk grant and the existing per-file safety checks.
- Update the one-time scan notice to disclose saved local review details.

## 0.3.54 - 2026-10-31

- Include accessible local account folders in full-disk scans while keeping
  their findings view-only from the signed-in account.
- Skip each account's private Library data and explain the expanded scan scope
  in the one-time scan notice.
- Verify that other-account files cannot be moved to Trash and that their
  Library caches stay out of scan results.

## 0.3.53 - 2026-10-31

- Add an App Leftovers view of current-user App Group folders, matched to
  installed apps through valid signed access declarations. Shared folders are
  view-only, and incomplete owner checks are labeled.
- Match bounded directory-open work to the calling task's quality of service
  to avoid priority inversions during interactive review.

## 0.3.52 - 2026-10-31

- Expand App Leftovers to seven exact app-identifier locations in the current
  user's Library, including logs, saved app state, and application scripts.
  Shared group containers and fuzzy name matches remain out of cleanup.

## 0.3.51 - 2026-10-31

- Add a reviewed Trash action for completely checked local Xcode archives.
  Changed, linked, shared-file, incomplete, unsupported, and over-limit bundles
  remain in place; device-support folders stay view-only.

## 0.3.50 - 2026-10-31

- Add a saved duplicate-scan preference to recommend keeping the oldest- or
  newest-modified copy. A recommendation never selects or removes files, and
  users can still choose a different copy in each group.

## 0.3.49 - 2026-10-31

- Add review-first cleanup for local AI models. Selected provider models and
  recognizable model files go to Trash after one exact review; shared Ollama
  blobs and files that fail safety checks stay in place.

## 0.3.48 - 2026-10-31

- App Updater now notes when an app's numeric build changes after a supported
  feed check. The update itself remains with the app's own updater.

## 0.3.47 - 2026-10-31

- Extend Local AI Models discovery to recognizable model-weight files elsewhere
  in the current user's home folder, with protected-location skips and a shared
  safety limit. This remains a read-only inventory.

## 0.3.46 - 2026-10-30

- Add a read-only view of local Time Machine snapshot names and dates. Snapshot
  sizes aren’t reported, and Mac Cleaner does not thin or delete snapshots.

## 0.3.45 - 2026-10-31

- Add optional local notifications when scans or cleanup reviews finish. Each
  preference is separate, and macOS permission is requested only when first
  enabled.

## 0.3.44 - 2026-10-31

- Add 7-, 30-, and 90-day Activity views; the 90-day chart groups actions by
  week and keeps up to 500 local summary records for trend history.

## 0.3.43 - 2026-10-31

- Add a confirmed Restore Defaults action for appearance, file-review settings,
  tool favorites, and menu-bar readings. Saved access, scan exclusions,
  saved folders, activity history, and user files remain untouched.

## 0.3.42 - 2026-10-31

- Add a saved System, Light, or Dark appearance preference. Light remains the
  default, and the same choice applies to the main window, Settings, and menu
  bar panel.

## 0.3.41 - 2026-10-31

- Save selected scan folders with macOS security-scoped bookmarks and run
  Smart Scan on them again from Settings. Removing a shortcut only removes its
  bookmark.

## 0.3.40 - 2026-10-31

- Extend Startup & Background's read-only inventory to the current user's,
  shared, and Apple launch-agent and launch-daemon folders.

## 0.3.39 - 2026-10-30

- Add local Safari and Firefox cache review with app-quit checks, exact-path
  review, change detection, and Trash-only cleanup. History, cookies, site data,
  downloaded files, and saved passwords remain outside this cleanup.

## 0.3.38 - 2026-10-30

- Add an on-demand code-signature and certificate trust check to App Security.
  It can include Apple's online certificate and notarization checks; a passing
  result does not mean an app is safe or free of malware.

## 0.3.37 - 2026-10-30

- Add a timed Screen Cleaning Mode that covers connected displays and exits
  with Escape, an on-screen button, or its automatic timeout.

## 0.3.36 - 2026-10-30

- Add a review for older crash and diagnostic reports in the current account's
  standard DiagnosticReports folder. Recent reports stay out of the list;
  selected older reports move to Trash only after a separate confirmation.

## 0.3.35 - 2026-10-30

- Extend Xcode Storage with a read-only inventory of standard local device
  support folders, showing their names, locations, dates, file counts, and
  logical sizes. Neither archives nor support data can be removed in this view.

## 0.3.34 - 2026-10-30

- Add a read-only Xcode Storage inventory for local `.xcarchive` builds, showing
  archive names, locations, modified dates, file counts, and logical sizes.
  Archives are explicitly protected from cleanup actions.

## 0.3.33 - 2026-10-30

- Add a diagnostics export with app/macOS versions, scan totals, and review
  settings. It excludes file names and paths, account names, excluded-folder
  names, and file contents.

## 0.3.32 - 2026-10-30

- Identify the local Simulator cache with a clear explanation, while protecting
  simulator device data and keeping Xcode archives out of cache candidates.

## 0.3.31 - 2026-10-30

- Explain recognized Xcode Derived Data, Homebrew, pip, and npm caches in plain
  language, including what may happen after cleanup. Xcode archives and
  installed project dependencies remain outside these cache rules.

## 0.3.30 - 2026-10-30

- Inventory local Ollama, Hugging Face, and LM Studio models by readable name,
  location, file count, and size. The inventory is read-only and stays on this
  Mac; model files remain managed by their original app.

## 0.3.29 - 2026-10-30

- Add one-scan finding filters for Desktop, Documents, Downloads, Pictures, and
  other checked locations. Low-risk selection follows the visible results.

## 0.3.28 - 2026-10-30

- Verify signed app resources and embedded code across architectures, with
  progress and cancellation in App Security.

## 0.3.27 - 2026-10-30

- Add local iPhone/iPad backup review with logical size, newest file-change date,
  safety-limited inventory, and explicit move-to-Trash review for recognized
  backups. Backup contents are not opened.

## 0.3.26 - 2026-10-30

- Expand Privacy & Permissions with quiet status checks for camera, microphone,
  Contacts, Screen Recording, and Accessibility, plus direct System Settings
  links. These statuses do not trigger permission prompts.

## 0.3.25 - 2026-10-30

- Add live network transfer rates, external-drive capacity, and time since
  restart to Performance.
- Let users choose which system readings appear in the menu-bar panel and link
  to Apple's Activity Monitor for per-app process details.

## 0.3.24 - 2026-10-29

- Make scan coverage counts explicit and identify the files-and-folders safety
  limit when a scan is partial.
- Show five examples of inaccessible locations, count additional omitted paths,
  and preserve the exact scan limit in the result.

## 0.3.23 - 2026-10-29

- Add a seven-day local activity chart for recorded scans, cleanup actions,
  and app update checks.
- Keep existing activity history readable by deriving conservative categories
  for older entries that predate the chart.

## 0.3.22 - 2026-10-29

- Add local folder exclusions for future scans and show which exclusions were
  applied; a scan cannot start inside an excluded folder.
- Add tests for exclusion storage, path boundaries, skipped subtrees, and
  accurate scan summaries.

## 0.3.21 - 2026-10-29

- Expand Space Lens to browse and Quick Look direct files in accessible folders,
  including files that were not cleanup findings, and add breadcrumb navigation.
- Keep cleanup selection limited to files already flagged by the scan, and
  bound each folder listing while skipping symlinks and protected paths.

## 0.3.20 - 2026-10-29

- Add a limited Mac Health score with a visible formula based on available
  storage, macOS memory-pressure events, and battery condition.
- Show Apple-reported battery condition and cycle count when available, and add
  safe maintenance shortcuts to local reviews and Apple tools.

## 0.3.19 - 2026-10-29

- Keep the shipped suite local-only by removing the optional Chrome extension
  and moving cloud, email, and browser integrations out of scope.

## 0.3.18 - 2026-10-29

- Add a guided first-run access session for the Mac disk and optional Photos
  library. Photos access is requested only when selected and has no repeat
  prompt after macOS records a choice.

## 0.3.17 - 2026-10-29

- Group scan findings by filename extension, with counts for each group.

## 0.3.16 - 2026-10-29

- Let users choose which exact duplicate copy to keep and check other accessible
  copies for review.

## 0.3.15 - 2026-10-29

- Add last-accessed sorting to scan findings when the filesystem provides it.

## 0.3.14 - 2026-10-29

- Include mounted, accessible local external drives in whole-Mac scans while
  continuing to skip iCloud and network volumes.

## 0.3.13 - 2026-10-29

- Include shared files in whole-Mac scans while continuing to skip other user
  accounts.

## 0.3.12 - 2026-10-29

- Bound App Leftovers metadata inspection and skip folders macOS cannot open
  promptly, keeping incomplete candidates unavailable.
- Show progress while reviewing app-data locations.

## 0.3.11 - 2026-10-29

- Keep App Leftovers usable during the current session when macOS will not save
  a bookmark for Macintosh HD, and explain when disk access may need to be
  chosen again after reopening.

## 0.3.10 - 2026-10-29

- Estimate App Leftovers folder sizes from file metadata without reading file contents.
- Keep sensitive, incomplete, or unreadable locations unavailable for cleanup.

## 0.3.9 - 2026-10-30

- Add recursive folder search and a broad file-type size breakdown to Space Lens.
- Let full-disk scans move past folders that take too long to open, and identify
  the current folder while scanning.
- Correct Settings so it no longer lists the implemented App Updater as planned.

## 0.3.8 - 2026-10-30

- Add an App Security review for installed apps' main executable signatures.
- Clearly separate matching signatures, missing signatures, and checks that
  macOS could not verify; this is not malware detection or a notarization check.

## 0.3.7 - 2026-10-30

- Add an App Updater that lists installed versions and declared update sources.
- Check selected Sparkle HTTPS feeds for advertised versions; no installer is
  downloaded or installed, and the app's own updater remains responsible for
  applying an update.

## 0.3.6 - 2026-10-30

- Include user login helpers that point directly into an app bundle in app
  removal and reset reviews.
- Keep helpers with environment or sign-in settings unavailable, and recheck
  their exact program path before moving them to Trash.

## 0.3.5 - 2026-10-30

- Add a searchable My Tools hub with favorites saved locally on this Mac.
- Link directly to implemented scan, system, and privacy tools.

## 0.3.4 - 2026-10-30

- Add a Privacy & Permissions page that shows saved Mac disk access and current
  Photos access, with clear links to the related scan screens.
- Explain that macOS remembers access choices and that unused permissions are
  not requested.

## 0.3.3 - 2026-10-29

- Scan the Photos library for visually similar pictures alongside local image
  files, with access requested only when the user starts a scan.
- Keep Photos scans local by disabling iCloud image downloads; clearly report
  items that aren't available on this Mac.
- Require a separate confirmation before selected Photos items are removed, and
  recheck the selection and remaining group members before asking Photos to act.

## 0.3.2 - 2026-10-29

- Label byte-identical image copies separately from visual-similarity groups.
- Verify exact image copies with bounded full-file SHA-256 checks and report
  when the verification read limit prevents a conclusive exact-copy result.
- Use perceptual-hash bands to reduce unnecessary pair comparisons while
  preserving candidates within the supported tolerance range.

## 0.3.1 - 2026-10-29

- Explain each readable startup definition's declared purpose, launch
  conditions, disabled flag, associated app, and macOS authorization status.
- Improve search across startup labels, referenced apps, launch mechanisms,
  purpose text, and executable paths. Keep changes to other apps in macOS
  Login Items settings, where macOS supports them.

## 0.3.0 - 2026-10-28

- Add a one-time scan notice and local acknowledgement before requesting disk
  access; saved macOS access is reused for later scans.
- Make the full-disk access flow reject an accidentally selected folder and
  clearly report canceled, stale, and unavailable access.
- Replace whole-folder enumeration with streaming directory reads, responsive
  cancellation checks, and progress that counts folders as well as files.
- Limit full-disk scope to the signed-in account, selected cache/log folders,
  and accessible non-user system-disk areas; skip other accounts, external
  volumes, iCloud, protected system folders, and app-private Library data.
- Add coverage for disk-scan scope, directory progress, and the saved notice.

## 0.2.0 - 2026-10-28

- Add App Leftovers review for exact bundle-ID paths in four common user
  Library locations, with bounded inventory, view-only incomplete results,
  exact-path review, and confirmed selected-only moves to Trash.
- Add batch app removal and Reset App reviews for individually selected,
  exact bundle-ID data locations; sensitive and incomplete locations remain
  unavailable and all moved items go to Trash.
- Show the app version and local file-handling summary in Settings.
- Add an optional Chrome tab-review extension and a native setup screen.
- Add reviewable application-bundle removal and a read-only startup-definition
  inventory with a link to macOS Login Items settings.
- Add a native SwiftUI macOS application and generated Xcode project.
- Add sandboxed user-selected folder scanning, large/old and exact duplicate
  discovery, conservative cache and AI-tool rules, and local activity summaries.
- Add a centralized file safety policy and confirmed move-to-Trash flow that
  revalidates duplicate survivors and refreshes remaining groups.
- Add synthetic regression coverage for file changes, root symlink replacement,
  and duplicate state after cleanup.
- Add on-demand CPU, memory-page, and storage monitoring in the Performance
  screen and native menu-bar panel.
- Add architecture, feature status, security, testing, and development docs.
