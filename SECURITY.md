# Security and privacy

## Threat model

Mac Cleaner reads personal files and can move selected items to Trash. Its main
risks are false-positive classification, an unintended selection, stale paths,
symbolic-link traversal, sensitive data exposure, and overstated storage
savings. Scans are read-only; cleanup is a separate, reviewable action.

## Permission model

- The installed app is not restricted by App Sandbox because macOS sandboxing
  prevents Full Disk Access from reaching protected folders needed for the
  requested whole-Mac scan. Local development builds use an ad-hoc signature.
  The public release workflow requires Developer ID signing and Apple
  notarization before it publishes a download.
- Full Disk Access is a macOS setting that the user enables in System Settings.
  Once enabled, Mac Cleaner can read protected local files outside its app
  folder. The first-run notice explains this scope, and Settings links to the
  macOS control. Mac Cleaner cannot grant itself Full Disk Access, modify TCC,
  disable SIP or Gatekeeper, or silently approve permission prompts.
- The app does not install a privileged helper or run scheduled cleanup. It
  does not ask for camera, microphone, Contacts, Screen Recording, or
  Accessibility access. The permissions screen reads statuses only where
  macOS provides a supported check.
- Photos access is optional and is requested only when the user chooses a
  Photos-library scan. Photos items are not downloaded from iCloud. Local
  iCloud Desktop files are read-only; cloud-only items are skipped without a
  download. Other iCloud Drive areas and network volumes are outside the scan.
- The first-run notice acknowledgement is stored locally. It explains the
  app's behavior; it does not grant macOS permissions. The user can review it
  again in Settings.
- Folder exclusions and saved-folder bookmarks stay on this Mac. An excluded
  folder is skipped before its contents are opened. The disk root cannot be
  excluded.

## File safety

- File discovery, hashing, image comparison, and inventories do not change
  files. The app does not select results automatically for cleanup.
- The main file scan, duplicate hashing, photo fingerprinting, and cleanup
  identity checks open regular files without following a final symlink and
  confirm the path reported for the open file descriptor before reading it.
  Directory enumeration rejects opened paths that resolve differently from
  the expected path.
- The full-disk scan covers accessible locations and reports unreadable paths
  and partial results. It reads metadata in the signed-in account's Library,
  but ordinary app data remains view-only; only recognized cache/log
  candidates may be moved to Trash after review. Protected app-state and
  developer toolchain folders, other accounts' Library data, protected system
  areas, network volumes, and iCloud content are skipped except locally stored
  Desktop metadata. Dedicated
  tools inspect only their documented model, backup, report, app-support,
  Photos, and Xcode locations.
- Other local accounts and system-wide cache/log results are view-only.
  System-wide caches are not offered for cleanup.
- Selected files are rechecked before the Trash operation for their location,
  type, device/inode, size, modification time, and hard-link count. Symlinks,
  protected locations, credentials, Git repositories, and other protected
  components are not cleanup candidates. Cleanup coordinates the final check
  with macOS, then checks the identity of the item returned by the Trash API.
  Duplicate groups must retain at least one copy.
- The app uses the macOS Trash API and never empties Trash. It reports partial
  failures instead of claiming that every selected item moved. Coordination
  and identity checks reduce time-of-check/time-of-use risks but cannot
  eliminate every hostile concurrent path replacement.
- App removal is restricted to readable apps in standard Applications folders.
  Apple apps, Mac Cleaner, running apps, symlinked paths, and changed bundle
  identities are protected. App data and leftover suggestions start unchecked,
  require path review, and are revalidated before moving to Trash. A matching
  bundle identifier does not prove that data is unused or contains no private
  state.

## Data handling and network use

- No telemetry, account connection, cloud cleanup, Gmail cleanup, Chrome
  extension, or native browser messaging is included. Scan data is not uploaded.
- The latest full-disk review is saved locally so it can be reopened after a
  restart. It includes file names and paths. Settings can clear that review.
- Activity history stores bounded, generic summaries without file names or
  paths. Diagnostics exports include app/device details and aggregate scan
  totals, but omit file names, paths, account names, excluded-folder names,
  and file contents.
- App Updater can contact a user-selected publisher's HTTPS Sparkle feed after
  explaining the request. It reads version metadata only; it does not download
  or install an update. A user-started code trust check may contact Apple's
  certificate/notarization services. The Mac Health software-update check
  contacts Apple's update service only after the user presses its button. None
  of these checks sends file names, contents, scan results, or cleanup history.
  The user-started Homebrew check invokes only `brew outdated --cask --json=v2`
  with Homebrew auto-update and analytics disabled. It may contact Homebrew's
  configured metadata source, stores the latest cask versions locally, and
  never runs an upgrade or sends Mac Cleaner scan data.
- Privacy Cleanup reviews recognized local browser cache folders only. It
  does not remove history, cookies, passwords, tokens, download lists, or
  website storage.

## Security checks and known limits

- App Security verifies code-signature integrity, sealed resources, and
  embedded code for installed apps. Optional trust checks use macOS validation
  where available. Startup review covers readable launch definitions and
  selected bundled helpers. These checks provide context; they are not a
  malware verdict and do not inspect every modern background item or live
  process.
- Mac Cleaner does not include an antivirus engine or claim malware
  protection. ClamAV was evaluated: its one-time `clamscan` engine requires an
  installed signature database, and ClamAV documents `freshclam` as the tool
  for downloading and updating those signatures. The engine is GPLv2. Mac
  Cleaner does not bundle an external engine or silently download definitions;
  App Security remains a code-integrity review, not malware scanning.
  See the [ClamAV scan documentation](https://docs.clamav.net/manual/Usage/Scanning.html),
  [signature update documentation](https://docs.clamav.net/manual/Usage/SignatureManagement.html),
  and [license](https://github.com/Cisco-Talos/clamav/blob/main/COPYING.txt).
- macOS's Service Management API controls helpers inside an app's own bundle.
  Mac Cleaner cannot reliably enumerate or toggle every other app's modern
  background item. It shows readable launch definitions and links to System
  Settings for supported management.
- DNS cache flushes, Spotlight reindexing, and Time Machine snapshot thinning
  are not performed. These operations require system-level authorization or
  helpers that Mac Cleaner does not install. Time Machine snapshot listing is
  read-only; Apple manages snapshot storage.
- Local builds are not notarized or independently security-reviewed. The
  public-release workflow verifies signing and notarization, but that is not an
  independent security review. Full-disk scan coverage, app-data matching,
  APFS physical-space estimates, and third-party app state have the limitations
  described in [FEATURES.md](FEATURES.md). Path checks and Trash operations are
  separate OS calls; a hostile process changing the same path concurrently can
  still create a race.
