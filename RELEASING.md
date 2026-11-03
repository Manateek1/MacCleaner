# Releasing Mac Cleaner

GitHub Releases publishes an Apple silicon `.zip` for macOS Tahoe 26 and later
only after tests pass, the app is signed with Developer ID, Apple's notarization
service accepts it, and Gatekeeper assessment succeeds. Local development builds
are not release downloads.

## One-time maintainer setup

The repository owner needs an Apple Developer Program account and a Developer ID
Application certificate with its private key. Export the certificate and key
from Keychain Access as a password-protected `.p12` file. Convert the file to a
Base64 line locally. Never commit the file or send it in a pull request or chat.

In GitHub repository settings, create a protected Actions environment named
`macos-release`:

- Require approval from a trusted release maintainer before a job can use its
  secrets.
- Allow deployments from `main` only.
- Add the following as **environment secrets**, not repository-wide secrets:

  - `DEVELOPER_ID_CERTIFICATE_P12_BASE64` — Base64 export of the `.p12` file.
  - `DEVELOPER_ID_CERTIFICATE_PASSWORD` — password used to export that file.
  - `DEVELOPER_TEAM_ID` — ten-character Apple Developer Team ID.
  - `APPLE_ID` — Apple Account used for notarization.
  - `APPLE_APP_SPECIFIC_PASSWORD` — app-specific password for notarization.

Also protect the `v*` tag pattern so only trusted release maintainers can create
or update version tags. Protect `main` so releases come from reviewed, tested
changes.

## Publishing a version

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Project.yml`.
2. Merge the change to `main` after its macOS checks pass.
3. Create and push a matching version tag, such as `v0.5.3` for app version
   `0.5.3`.
4. In **Actions → Signed macOS release**, run the workflow from `main` and enter
   that tag. The build job checks that the tag points to a commit on `main`, then
   runs core checks, unit and UI tests, and an unsigned Tahoe/Apple silicon
   archive without release credentials.
5. Approve the `macos-release` deployment when GitHub asks. The signing job
   checks that the tag still points to the tested commit, signs the downloaded
   app, submits it for notarization, staples Apple's ticket, and checks
   Gatekeeper. The publish job rechecks the tag and download checksum before it
   creates the GitHub Release.

The workflow intentionally fails when any required environment secret is
missing. Do not publish an ad-hoc or unnotarized build as an easy-install
download.
