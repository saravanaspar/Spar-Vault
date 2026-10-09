# Spar Vault 0.2.1

Local-first Flutter password manager for Android, web, Linux and Windows. Source code and tests are provided. This is a development implementation that still needs independent security review and target-device release testing. No comparative “most secure” claim is made.

## Features

- Random 256-bit secure key; direct `.txt` key import; optional password unlock using Argon2id plus AES-GCM key wrapping. No provider recovery or reset.
- Five-minute inactivity lock by default, configurable to 1/2/5/10/15/30 minutes. Switching apps retains the session until that deadline; immediate background locking is optional. A privacy cover hides the app while backgrounded. Resume checks expiry even when timers were suspended.
- Vault, Codes, Security, Backups and Settings sections; Logins/Notes/Favorites filters; search; 10/20/50-item pagination.
- Offline password-health heuristics, random password generation, encrypted password history (latest ten), secure notes and attachments.
- Offline TOTP: Base32 or otpauth URI; SHA1/SHA256/SHA512; 6/8 digits. Clock accuracy matters; no QR scanning in this release.
- Authenticated backup verification before replacement; encrypted automatic copies with five-copy rotation and independent-backup reminders.
- Five-minute paired transfer files on every target; one-use authenticated LAN transfers on native targets. Matching vaults get a merge preview and explicit conflict/deletion choices. This is manual snapshot synchronization, not continuous background sync.
- Root-key rotation. Existing backups retain their old credentials.
- Android strong-biometric quick unlock, plus an independent opt-in Phone screen lock option (strong fingerprint OR system PIN/pattern/password). Both use hardware Keystore and authenticated cipher operations. Unsupported hardware fails closed.
- Android native-app autofill with explicitly pinned installed signing certificates, process-only session credentials and a confirmation screen. Android website autofill is refused because AssistStructure strips the port and cannot prove an exact origin.
- Chrome/Edge extension for confirmed HTTPS-origin autofill from the Linux/Windows app or an open web vault tab. No autosubmit, persisted passwords or remote services.

**Password, enabled biometrics or Phone screen lock can still unlock after the external key copy is lost. Losing every enabled unlock method means losing access. Losing the vault without a backup loses its data even if credentials survive.** The master key is not a cryptocurrency seed.

## Apply this source patch

Export an encrypted `.svlt` backup in the old app and keep its matching key privately. Stop the app. In your existing project directory:

```bash
unzip -o ~/Downloads/Spar_Vault_Advanced_Changed_Files.zip -d .
flutter pub get
flutter analyze
flutter test
```

No legacy-source deletion is required. No compiled website, APK, installer or vault/key files are included in the patch. Do not uninstall the Android app or clear browser data while upgrading. Keep the existing package/application IDs and signing key to preserve app data.

The new app reads old Sable/Spar v1 backups and migrates them when saved. Old apps cannot read newly saved schema-2 vaults. Keep an old backup for rollback; downgrade does not convert new data.

## VS Code / running

Open the folder containing `pubspec.yaml`; install the Flutter and Dart extensions. Run from its terminal:

```bash
flutter run -d 28215974   # your connected Android device
flutter run -d linux
flutter run -d chrome --web-port 8080
```

Windows needs Windows and Visual Studio's desktop C++ tools:

```powershell
flutter run -d windows
```

Stop with `q` and restart after this update; native Kotlin/manifest changes require a full rebuild, not hot reload. The Android app still uses its original application ID. The logo/icon assets remain unchanged.

For existing vaults, unlock once with the secure key or import its `.txt` file. Then go to **Settings → Unlock methods → Enable password unlock**. Choose a unique passphrase of at least 15 characters. The secure key continues to work.

To restore on your phone, select the encrypted `.svlt` backup first, then enter its password or import the matching key file. A `.txt` key alone contains no vault entries.

## Persistent local website

A Flutter debug browser profile can be temporary. For persistent storage use your normal browser at a stable origin:

```bash
flutter build web --release --no-web-resources-cdn --pwa-strategy=none --no-source-maps
python3 scripts/prepare_web.py build/web
python3 scripts/serve_web.py build/web --port 8080
```

Open `http://127.0.0.1:8080`. Keep that hostname and port: IndexedDB is origin-specific. Assets work offline after one successful cached load. Browser storage eviction/clearing can erase the vault. Public hosting needs HTTPS and equivalent supplied security headers. Never publish key/backup files beside app assets. A hosted vault trusts the code delivered by its origin.

Automatic browser backups use a granted folder where File System Access is supported. After reload, you may need to reselect it to renew permission. Other browsers retain five encrypted copies in separate IndexedDB storage; these share the same site-data-loss risk and are accessible through **Review browser backup copies**. Export independent backups regardless.

## Autofill setup

See [browser/README.md](browser/README.md) for the unpacked Chrome/Edge extension, per-user native host installation and web-tab connection. Enable confirmed autofill in Spar Vault and enter the extension ID. Each website request requires selecting a matching login inside the foreground vault.

On Android, enable autofill in Spar Vault; first enable opens the Android service selector and checks that Spar Vault is actually selected when you return. Cancelling leaves autofill off. Check the service status in Settings after Android revokes it. Then and bind an installed native app's exact package/signing certificates in an item's **Android app binding** subsection. The vault must remain unlocked. No plaintext autofill database or root key is given to the autofill service. Some forms have ambiguous/missing hints and are refused. Test on your actual apps.

## Validation and release

Pinned toolchain: Flutter 3.47.6 / Dart 3.13.5. Keep both lockfiles.

```bash
flutter analyze
flutter test
(cd packages/vault_core && dart pub get --enforce-lockfile && dart analyze && dart test)
python3 -m unittest discover -s browser/tests
node scripts/web_smoke.cjs http://127.0.0.1:8080
```

The last command requires Playwright and a Chromium installation. See [docs/VALIDATION.md](docs/VALIDATION.md) for actual results and platform limits, [SECURITY.md](SECURITY.md) for the threat model, and [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md) before distributing signed releases.

Shared Dart code does not remove native host requirements. Build Linux on Linux, Windows on Windows, Android with its SDK. Apple runners remain in the existing project but are not part of this update's requested platform validation. No analytics, cloud service, breach-query service or recovery escrow is added.

Restoring writes a fresh authenticated snapshot and resets device-specific automatic-backup/autofill settings. Re-enable them explicitly on the receiving device; passwords, entries, history and portable session/layout settings remain available.

## Android unlock and transfer patch (0.2.1)

Install `Spar_Vault_Android_Unlock_Transfer_Fix_Changed_Files.zip` over the 0.2 advanced source using `ANDROID_UNLOCK_TRANSFER_UPDATE.md`. Rebuild the native app; hot reload cannot install Kotlin changes. Settings → Unlock methods offers **Enable Phone screen lock**. This uses Android’s own fingerprint/PIN/pattern/password prompt on supported Android 11+ hardware and is not an online/synced passkey. Missing enrollment or app access opens the relevant Android setup screen. A normal biometric permission has no runtime popup. Your vault password and master key remain independent unlock methods.

Receive-transfer dialogs now scroll with the phone keyboard and own their controller until removal; other dialogs wait for their closing transition before caller-owned controllers are disposed. Local transfer shows this device’s name, Wi-Fi/Ethernet/interface label and the IP used for routing. The picker lists local interfaces, not discovered recipient devices.
