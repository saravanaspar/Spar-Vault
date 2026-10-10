# Spar Vault

A local-first password manager built with Flutter for Android, Windows, Linux, macOS, and the web. Spar Vault stores logins, secure notes, authenticator codes, and attachments in an encrypted vault on your device. It requires no account and includes no telemetry, cloud sync, or recovery service.

[Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Architecture](docs/ARCHITECTURE.md)

## Features

- **Encrypted vault:** a random 256-bit secure key, optional password unlock with Argon2id, and configurable inactivity locking.
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

## Getting started

Create a vault, keep a private external copy of its secure key, and export an encrypted backup. You can enable password unlock and available device authentication in **Settings → Unlock methods**.

Use **Add login** for credentials and related notes, codes, files, and app bindings. Use **Add secure note** for a standalone note. To transfer items, open **Receive** on the destination and **Send** on the source, then compare and approve the displayed number on both devices. Nearby transfer requires a shared network and imports items under the destination vault's own key.

An encrypted backup needs its matching password or secure key. A key file alone contains no entries. Losing all enabled unlock methods leaves no recovery path; losing the vault without a backup loses its data. Keep existing application IDs and signing identities when upgrading.

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

The [build workflow](.github/workflows/build-release.yml) analyzes and tests the project, then builds Android, Windows, Linux, and macOS. After all checks pass on `main`, it tags the tested version and publishes the application bundles with SHA-256 checksums. Published version tags are not overwritten.

Android CI artifacts are labelled **Android_Test** when release signing secrets are absent. Windows bundles are unsigned; default macOS CI bundles are ad-hoc signed and not notarized, so their System lock requires production signing. See [release configuration](CONTRIBUTING.md#releases) for signing requirements.

## Documentation and contributions

- [CHANGELOG.md](CHANGELOG.md) records release changes.
- [CONTRIBUTING.md](CONTRIBUTING.md) covers development, testing, and releases.
- [SECURITY.md](SECURITY.md) describes the threat model, recovery boundaries, and vulnerability reporting.
- [Architecture](docs/ARCHITECTURE.md) describes storage, authentication, and platform integrations.
- [Browser integration](browser/README.md) covers the extension and native host.

Spar Vault is under active development and has not undergone an independent security audit. Contributions and reproducible bug reports are welcome; report security vulnerabilities privately using the process in [SECURITY.md](SECURITY.md).

## License

Spar Vault is maintained by **B&S TechSystems** and distributed under the [MIT License](LICENSE). See [AUTHORS.md](AUTHORS.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution and bundled component licenses. Notices are also available in **Settings → Open-source licenses**.
