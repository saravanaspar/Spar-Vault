# Changelog

Notable changes to Spar Vault are recorded here, newest first. The entries below summarize the recorded source updates from 0.2.0 onward.

## Unreleased

### Changed

- Clarified the repository README's project identity, download instructions, offline operation, encryption, platform authentication, authenticator import, autofill, and recovery answers.

### Fixed

- Documentation and CI-tooling updates can complete main-branch CI without moving an existing release tag or republishing its assets. Application changes still require a new version.

## 0.2.5

### Fixed

- Release notes now distinguish Android builds signed with the configured release key from debug-signed `Android_Test` builds, instead of describing every Android package as a test build.

## 0.2.4

### Added

- Desktop System lock: hardware-backed Windows Hello, macOS Keychain user presence, and compatible FIDO2 security keys on Linux.
- GitHub Actions validation and Android, Windows, Linux, and macOS builds, with version tagging, complete release bundles, license notices, and SHA-256 checksums.
- Android release-keystore configuration and CI signing support. When signing secrets are absent, CI produces an explicitly labelled `Android_Test` APK; partially configured signing secrets are rejected.
- MIT license, author attribution, contributor guidance, third-party notices, and issue and pull-request templates.
- An in-app open-source licenses page.
- This changelog, covering the recorded 0.2.0–0.2.4 update history.

### Changed

- Renamed the shared device unlock option from **Phone screen lock** to **System lock**.
- Removed obsolete audit and update reports from the maintained documentation.
- Rewrote the README around application features, platform support, development, and builds.
- Consolidated Android signing and release configuration in the contributor guide.

### Fixed

- Desktop native key handling copies platform response bytes into owned, writable buffers before cleanup.
- Linux and Windows release packaging reads the executable name from the platform CMake configuration, fixing rejected bundles that contain the existing `sable_vault` runner.

### Removed

- One-time repository administration helpers: `protect_main.py`, `cleanup_docs.py`, and `setup_android_signing.py`.
- Tests that depended on the removed branch-protection helper. Build, packaging, and web tooling remain supported.

## 0.2.3

### Added

- Nearby device discovery and direct transfer of selected or all items on a shared Wi-Fi network or hotspot, with pairing-number confirmation on both devices.
- Offline Android camera and image QR scanning for TOTP.
- Google Authenticator export import, including multi-page exports and selected-account or full import. Unsupported HOTP accounts are rejected.
- Installed-app selection for Android autofill, with automatic signing-certificate binding.

### Changed

- Split item creation into **Add login** and **Add secure note**.
- Organized the login editor into Login, Extra notes, 2FA, Files, and Autofill tabs; standalone notes open directly in their note editor.
- Replaced the separate file/code and local-network transfer controls with the nearby Send/Receive flow on native platforms.
- Allowed screenshots across application pages and the Android autofill confirmation screen.

### Fixed

- Android unlock failures caused by attempting to wipe read-only method-channel key buffers.
- Narrow-screen overflow in Security results and cramped mobile editor layouts.
- The OTP widget regression test's lookup of the period indicator.
- Dependency setup instructions now resolve the core package before root analysis, preventing missing `package:test` errors in nested tests.

## 0.2.2

### Fixed

- Android protected-cipher authentication now applies authenticated data after the operating system authorizes the cipher operation.
- Recognized the documented per-use Keystore authentication duration and improved hardware-key fallback, binding replacement, and non-secret error diagnostics.
- Rejected late key-picker results after session locking.
- Enabled authenticated backup recovery from a bounded, malformed stored vault snapshot.
- Prevented deletion-history overflow from dropping tombstones and allowing old items to reappear during merges.
- Corrected overlapping local-transfer lifecycle and cleanup races.
- Retried failed automatic backups instead of treating the failed snapshot as completed.
- Reloaded edited TOTP configurations and used each account's configured period for code progress.
- Prevented stale Android certificate lookups from binding a different app package.
- Removed competing offline worker registration and included the application icon in the public asset cache.
- Corrected password-health wording and improved error popup text contrast.

### Changed

- New Android system-credential bindings authorize the protected cipher on each use. Older timed bindings remain readable until replaced.

## 0.2.1

### Added

- An independent Android Phone screen lock option using strong biometrics or the system PIN, pattern, or password.
- Android authentication setup guidance and autofill service selection/status checks.
- Device and interface labels for the original local-network transfer flow.
- Public-asset caching for offline web reloads.

### Fixed

- Prevented system authentication prompts from cancelling themselves during expected activity transitions, while preserving manual and inactivity locking.
- Improved authentication cancellation, timeout, lockout, and invalidation messages.
- Corrected transfer-dialog keyboard layout and controller lifetime handling.

## 0.2.0

### Added

- Optional password unlock using Argon2id and authenticated root-key wrapping, alongside secure-key unlock and key-file import.
- Configurable inactivity locking, optional immediate background locking, and a background privacy cover.
- Vault, Codes, Security, Backups, and Settings sections, with search, filters, favorites, and pagination.
- Encrypted password history, attachments, secure notes, offline TOTP, and password-health checks.
- Authenticated backup restore, automatic encrypted backup copies, paired transfers, item merging, and root-key rotation.
- Android biometric unlock and certificate-bound native-app autofill.
- Confirmed browser autofill through an extension and native-host or web-tab connection.

### Changed

- Introduced schema-2 vault data while retaining read support for legacy v1 backups. Older applications cannot read newly saved schema-2 data.
- Restores reset device-specific backup and autofill integrations so they can be enabled explicitly on the destination.
