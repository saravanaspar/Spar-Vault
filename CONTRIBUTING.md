# Contributing

Use Flutter **3.47.6** with its Dart **3.13.5** SDK. Keep both `pubspec.lock` files committed. Linux native builds also need GTK3, libfido2 and OpenSSL development packages.

1. Create a branch from `main` and make a focused change.
2. Resolve both packages before analyzing the project:

   ```bash
   flutter pub get --enforce-lockfile
   (cd packages/vault_core && dart pub get --enforce-lockfile)
   flutter analyze
   flutter test
   (cd packages/vault_core && dart analyze && dart test)
   python3 -m unittest discover -s browser/tests -v
   python3 -m unittest discover -s scripts/tests -v
   ```

3. Describe the defect and resulting behavior in your pull request, with relevant validation. Changes to platform APIs must compile on their target platform. CI checks all four shipped platforms.

Authentication must authorize access to the actual protected key. A boolean success callback followed by reading an unprotected saved root key is unacceptable. Test cancellation, lifecycle locking, incorrect credentials, corrupted bindings and enrollment failure. Preserve password/key fallback and reject unsupported hardware rather than weakening protection.

Vault changes must preserve existing-file compatibility or include an explicit migration. Never log passwords, secure keys, OTP seeds, full vaults, native-host tokens or private signing material. Report exploitable vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Releases

Increment `version: X.Y.Z+build` in `pubspec.yaml`, update the About text and offline-cache version, record the changes in [CHANGELOG.md](CHANGELOG.md), and merge through a pull request. A successful main build creates the version tag and GitHub release after validation and all four platform builds pass. Published tags are immutable; use another version for corrections.

Documentation and repository CI-tooling updates can retain the current application version. CI still validates and builds every target, but leaves an already published release unchanged when the complete comparison from its tagged commit contains only permitted repository files. Changes to application code, dependencies, assets, native runners, browser integration, or bundled notices require a new version. An incomplete comparison or an existing draft from another commit is rejected rather than treated as a documentation update.

The workflow packages the complete desktop application bundles and license notices using `scripts/release_tools.py`. Preserve the application IDs and signing identities across updates. Native authentication, camera scanning, autofill, and nearby discovery must also be checked on the affected target devices.

### Android development and updates

`flutter run` and `flutter build apk --debug` install **Spar Vault Dev** with application ID `com.bnstechsystems.sable_vault.dev`. Profile builds use the same Dev identity. The release application retains `com.bnstechsystems.sable_vault`, so both applications can remain installed while testing. Their vaults, preferences, and system-authentication bindings are separate; export and restore a backup explicitly if test data is needed. Android permits one selected autofill service at a time.

Update the installed stable application with an APK signed by its original release key and a newer version code:

```bash
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

`adb install -r` replaces the application while retaining its private data. If Android rejects a signature mismatch or version downgrade, resolve the signing/version configuration and retry. Do not uninstall the stable application to work around that failure; uninstalling removes its local vault. Older debug builds that used the stable application ID remain separate from the new Dev application and can be recovered through encrypted backup restore.

### Android signing

For a local release build, create the ignored `android/key.properties` file with your private keystore configuration:

```properties
storeFile=/absolute/path/to/spar-vault-release.jks
storePassword=YOUR_STORE_PASSWORD
keyAlias=YOUR_KEY_ALIAS
keyPassword=YOUR_KEY_PASSWORD
```

Use the existing keystore when updating an installed release. On Windows, use forward slashes in `storeFile`. Keep this file and the keystore private and outside source control. Run `flutter build apk --release` after configuring all four properties. Without a keystore, the local release is unsigned; use `flutter build apk --debug` for development.

For trusted `main` builds, configure these repository Actions secrets:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64-encoded release keystore |
| `ANDROID_STORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_PASSWORD` | Signing-key password |
| `ANDROID_KEY_ALIAS` | Signing-key alias |

Secrets are not used for pull-request builds. With no signing secrets, CI produces an explicitly labelled `Android_Test` APK; partial configuration fails. Back up the production keystore privately. A different signing key cannot upgrade an existing Android installation in place.

### Desktop distribution

Build each desktop target on its matching operating system and ship its full bundle. Windows packages are unsigned by default. macOS CI packages are ad-hoc signed and not notarized. Production macOS distribution requires the appropriate signing identity and notarization. System lock also requires a valid `com.apple.application-identifier` and Keychain entitlements. Keep signing credentials out of source control.

Contributions are distributed under [MIT](LICENSE). Retain upstream notices.
