# Spar Vault 0.2.1 — Android unlock and transfer fix

Apply this source-only patch after the previous Spar Vault 0.2 advanced update. The ZIP contains changed/new source, tests and documentation only. It contains no APK, compiled web package, vaults, real credentials or logo changes. No old files need deleting.

Export a `.svlt` backup and retain its matching secure key before upgrading. Stop `flutter run` with `q`, then from your existing project:

```bash
unzip -o ~/Downloads/Spar_Vault_Android_Unlock_Transfer_Fix_Changed_Files.zip -d .
flutter pub get
flutter run -d 28215974
```

A full native rebuild is required. Hot reload/restart does not install Kotlin or manifest changes. Do not uninstall the app or clear its data.

## Phone screen lock

Unlock with your vault password/key once. Open **Settings → Unlock methods → Enable Phone screen lock**, confirm its implications, then complete Android’s own fingerprint or PIN/pattern/password prompt. Lock the vault and choose **Unlock with Phone screen lock** next time. Supported Android 11+ hardware is required. The phone PIN is never entered into a Spar Vault text field or stored by the app. The PIN/pattern/password option is provided by Android; wording depends on your phone.

This is local device unlock, not a WebAuthn passkey or synced Google credential. Anyone who knows the phone screen credential can use it. It does not restore a deleted vault. Removing phone security, a failed hardware binding, clearing app data, restoring or rotating the root key may require enabling it again. A working password/key remains an independent unlock method. Losing all enabled methods means losing access; there is no provider reset.

Biometric-only unlock remains separately available. If no fingerprint is enrolled or Android has blocked app access, the app offers the appropriate enrollment/security/app settings screen. Android grants `USE_BIOMETRIC` at installation and has no standard runtime permission popup. No permission or authentication bypass is added. Cancellation, lockout, timeout, unavailable hardware and invalidated bindings have specific messages.

A system prompt no longer cancels itself merely because it makes the app inactive. The privacy cover remains. The inactivity deadline, manual locking and process detachment still cancel pending authentication; even an OS success cannot revive an expired session. Prompt timeout is 90 seconds. Normal background locking still follows your selected policy.

## Android autofill

In **Settings → Autofill integration**, turn on confirmed autofill. The app opens the Android selector and checks that you selected **Spar Vault** on return. Cancelling leaves a previously disabled preference off. The status identifies whether the Android service is selected; changes in Android settings are rechecked on resume. Use the settings button to enable the service again after revocation.

Then bind the exact native app package/signing certificate in the saved login's Android app binding subsection. The vault must be unlocked and every fill needs confirmation. Website/browser forms remain unsupported by Android autofill in this implementation; the desktop/web extension uses exact HTTPS origins. Accessibility permission is not required or requested.

## Transfer fixes

The receive-code dialog scrolls with the software keyboard, keeps its controller alive through closing and clears it on removal. Invalid, expired or cancelled transfers cannot overwrite your vault. Android’s file picker grants access to the file selected; broad storage permissions are unnecessary. The paired encrypted transfer protocol and its checks are unchanged.

Local send now shows the sender phone/computer name and Wi-Fi/Ethernet/interface label, with the IP underneath. This chooser lists this device’s interfaces, not nearby receiving devices. The private code still contains an IP and port for routing. A device name is a label, not proof of identity. Connect both devices to the same trusted network, privately copy the entire fresh code to the receiver, then choose Receive over local network. No network-wide discovery scan was introduced.

Web, Linux and Windows retain password/key unlock and shared transfer-dialog fixes. Web startup also registers a public-assets-only cache for offline reloads after one successful release load; encrypted vaults/transfers are never cached by it. Phone screen lock is Android-only. Use `flutter run -d chrome`, `flutter run -d linux`, or `flutter run -d windows` on their respective supported hosts.

## Verification

29 Flutter tests pass, including eight new checks for Android setup/lifecycle and transfer input. Android Kotlin compilation passes. Actual Xiaomi fingerprint/PIN, hardware Keystore, OEM settings and autofill still require device testing. See `docs/VALIDATION.md`, `SECURITY.md` and the release checklist for details. This is not an independently audited release.
