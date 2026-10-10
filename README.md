# Spar Vault — Offline Password Manager

**Spar Vault** is a free, open-source password manager and TOTP authenticator for **Android, Windows, Linux, macOS, and the web**. It stores logins, secure notes, authenticator secrets, and attachments in an encrypted vault on your device. Built with Flutter and Dart, it requires no account and includes no telemetry or cloud synchronization.

[Download the latest release](https://github.com/saravanaspar/Spar-Vault/releases/latest) · [Changelog](CHANGELOG.md) · [Security](SECURITY.md) · [Contributing](CONTRIBUTING.md)

## Download and install

Get application bundles and `SHA256SUMS.txt` from the [GitHub releases page](https://github.com/saravanaspar/Spar-Vault/releases). Choose the asset for your operating system; GitHub's **Source code** archives contain the project source, not an installable application.

| Platform | Release asset | Installation |
| --- | --- | --- |
| Android | `Spar_Vault_<version>_Android.zip` | Extract the APK and install it on your device. An `Android_Test.zip` asset is a debug-signed test build. |
| Windows x64 | `Spar_Vault_<version>_Windows_x64.zip` | Extract the entire bundle and launch `Spar_Vault/sable_vault.exe`. Keep its libraries and data folder beside it. |
| Linux x64 | `Spar_Vault_<version>_Linux_x64.tar.gz` | Extract the bundle and launch `Spar_Vault/sable_vault`. GTK3, libfido2, and OpenSSL runtime libraries are required. |
| macOS | `Spar_Vault_<version>_macOS.zip` | Extract the bundle and open the included `.app`. Default CI builds are ad-hoc signed and not notarized. |

Keep the same application ID and Android signing key when upgrading. Windows packages are unsigned. macOS System lock needs a properly signed application with the required Keychain identity. See [release configuration](CONTRIBUTING.md#releases) for distribution details.

Spar Vault is under active development and has not undergone an independent security audit. Read the [security model and recovery boundaries](SECURITY.md) before using it for sensitive credentials.

## Features

- **Encrypted vault:** AES-256-GCM encryption, a random 256-bit secure key, optional password unlock with Argon2id, and configurable inactivity locking.
- **Logins and secure notes:** search, favorites, password generation, encrypted password history, attachments, and local password-health checks.
- **Authenticator codes:** offline TOTP with configurable algorithms, digits, and periods; Android QR scanning and selected-account or full Google Authenticator export import.
- **System lock:** optional device authentication, using the protection available on each native platform.
- **Confirmed autofill:** installed-app selection on Android and exact HTTPS-origin matching through the Chrome/Edge extension on supported desktop or web configurations.
- **Backups and recovery:** encrypted `.svlt` export, authenticated restore, automatic backup copies, and secure-key rotation.
- **Nearby transfer:** discover a receiving native device on the same Wi-Fi or hotspot, compare the pairing number, and send selected items or the entire item collection.
- **Offline web access:** public application assets are cached after the first successful load; vault data remains in local encrypted storage.

## Platform support

| Platform | System lock | Integrations |
| --- | --- | --- |
| Android | Hardware Keystore with strong biometrics or the system PIN, pattern, or password; system credentials require Android 11+ | Native-app autofill, QR scanning, nearby transfer |
| Windows | Hardware-backed Windows Hello | Browser extension, nearby transfer |
| Linux | FIDO2 security key with PIN, touch, and `hmac-secret` support | Browser extension, nearby transfer |
| macOS | Keychain user presence with Touch ID or device password; requires a properly signed build | Nearby transfer |
| Web | Vault password or secure key | Browser extension, encrypted backup export and restore |

System lock is a local unlock method. Its credentials and bindings do not migrate with a backup. Unsupported hardware or signing configurations cannot enable it. Linux System lock requires a compatible security key; it does not use the Linux login password. An iOS System lock backend is not included.

## Create your first vault

1. Create a vault and keep a private external copy of its secure key.
2. Add credentials with **Add login**, or create a standalone note with **Add secure note**. A login can also contain related notes, TOTP codes, attachments, and app bindings.
3. Enable an optional vault password and available device authentication in **Settings → Unlock methods**.
4. Export an encrypted `.svlt` backup and keep it separately from your device and secure key.

To transfer items, open **Receive** on the destination and **Send** on the source, then compare and approve the displayed pairing number on both devices. Nearby transfer requires the same Wi-Fi network or hotspot and imports selected items under the destination vault's own key.

An encrypted backup needs its matching password or secure key. A key file alone contains no entries. Losing all enabled unlock methods leaves no recovery path; losing the vault without a backup loses its data. Keep existing application IDs and signing identities when upgrading.

## Frequently asked questions

### Does Spar Vault work offline?

Yes. Vault storage, password generation, password-health checks, and TOTP generation run locally. The web application can load offline after its public assets have been cached successfully. Nearby transfer needs a shared local network; it does not need a cloud account. Browser storage or cache clearing can remove local web data, so keep an external encrypted backup.

### Does it include cloud sync or a self-hosted server?

No. Spar Vault is a local password manager with encrypted backups and confirmed nearby transfers. It does not provide hosted accounts, a server backend, automatic cross-device synchronization, or a provider-operated recovery service. Hosting the static web application serves its public code; each browser still stores its own local vault.

### How are passwords and other vault contents encrypted?

The vault uses AES-256-GCM with a random 256-bit root key. Optional password unlock derives a wrapping key with Argon2id and encrypts that root key. Device authentication uses a separate local protected binding. See [SECURITY.md](SECURITY.md) for exact parameters and threat boundaries, and the [core vault implementation](packages/vault_core/lib/src/codec.dart) for the file format.

### What does System lock mean on each platform?

Android uses strong biometrics or its system PIN, pattern, or password on supported hardware. Windows uses hardware-backed Windows Hello. macOS uses Keychain user presence with Touch ID or the device password in a properly signed build. Linux requires a PIN-configured FIDO2 security key with touch and `hmac-secret` support; it does not use the Linux login password. Device bindings stay on their original device, and password or secure-key unlock remains available.

### Can I import codes from Google Authenticator?

Yes. Android can scan TOTP QR codes and import Google Authenticator QR exports. Multi-page exports are supported, and you can review and import selected accounts or all supported accounts. HOTP accounts are rejected. QR exports contain authenticator secrets: treat them as credentials. See the [authenticator import implementation](packages/vault_core/lib/src/authenticator_import.dart).

### Can it fill passwords in apps and browsers?

Android autofill supports explicitly selected installed apps with signing-certificate bindings and a confirmation step. The Chrome/Edge extension supports confirmed filling at matching HTTPS origins in supported desktop or web configurations. See [browser integration](browser/README.md) for setup and supported modes. Android website autofill is not supported because the platform form data cannot establish the complete origin required by the app's checks.

### What happens if I lose my password, secure key, or device?

Another enabled unlock method may still open the existing vault. A lost vault needs an encrypted backup and its matching credentials; a secure-key file alone cannot restore entries. If every usable unlock method is lost, there is no password reset or recovery service. Keep backups and keys privately outside the device, and verify that you can restore a backup.

### Is Spar Vault free and open source?

Yes. Spar Vault is maintained by **B&S TechSystems** and published under the [MIT License](LICENSE). Its source is available in [saravanaspar/Spar-Vault](https://github.com/saravanaspar/Spar-Vault). Component licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Development

The project and CI use Flutter **3.47.6**, Dart **3.13.5**, and Java **17** for Android. Install the native build tools for the platform you intend to run. Both dependency lockfiles are committed.

From the repository root:

```bash
flutter pub get --enforce-lockfile
(cd packages/vault_core && dart pub get --enforce-lockfile)
flutter run
```

Resolve both packages before running analysis or tests. See [CONTRIBUTING.md](CONTRIBUTING.md) for the complete validation commands and release configuration.

## Building

Build desktop applications on their corresponding operating systems.

| Target | Command | Requirements |
| --- | --- | --- |
| Android | `flutter build apk --release` | Android SDK, Java 17, and [release signing](CONTRIBUTING.md#android-signing) |
| Windows | `flutter build windows --release` | Visual Studio desktop C++ tools |
| Linux | `flutter build linux --release` | Clang, CMake, Ninja, pkg-config, GTK3, libfido2, and OpenSSL development packages |
| macOS | `flutter build macos --release` | Xcode and signing configuration for distribution and System lock |

The Android APK is written to `build/app/outputs/flutter-apk/app-release.apk`. Desktop distribution must include the complete generated application bundle, including its libraries and data. The retained `scripts/release_tools.py` packages these bundles with their license notices.

For a local web build:

```bash
flutter build web --release --no-web-resources-cdn
python3 scripts/prepare_web.py build/web
python3 scripts/serve_web.py build/web --port 8080
```

Open `http://127.0.0.1:8080`. Keep the same hostname and port because browser storage is scoped to the origin. Public hosting requires HTTPS and the supplied security headers. Keep vault backups and secure-key files outside public application assets.

## Releases

The [build workflow](.github/workflows/build-release.yml) analyzes and tests the project, then builds Android, Windows, Linux, and macOS. After all checks pass on `main`, a new application version is tagged and its bundles are published with SHA-256 checksums. Documentation and repository CI-tooling updates run the same checks and leave an already published version unchanged. Published version tags are not overwritten.

Android CI artifacts are labelled **Android_Test** when release signing secrets are absent. Windows bundles are unsigned; default macOS CI bundles are ad-hoc signed and not notarized, so their System lock requires production signing. See [release configuration](CONTRIBUTING.md#releases) for signing requirements.

## Documentation and contributions

- [CHANGELOG.md](CHANGELOG.md) records release changes.
- [CONTRIBUTING.md](CONTRIBUTING.md) covers development, testing, and releases.
- [SECURITY.md](SECURITY.md) describes the threat model, recovery boundaries, and vulnerability reporting.
- [Architecture](docs/ARCHITECTURE.md) describes storage, authentication, and platform integrations.
- [Browser integration](browser/README.md) covers the extension and native host.

Contributions and reproducible [bug reports](https://github.com/saravanaspar/Spar-Vault/issues/new/choose) are welcome. Report security vulnerabilities privately using the process in [SECURITY.md](SECURITY.md).

## License

Spar Vault is maintained by **B&S TechSystems** and distributed under the [MIT License](LICENSE). See [AUTHORS.md](AUTHORS.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution and bundled component licenses. Notices are also available in **Settings → Open-source licenses**.
