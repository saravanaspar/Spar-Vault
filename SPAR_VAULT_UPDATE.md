# Spar Vault 0.2 source upgrade

Download `Spar_Vault_Advanced_Changed_Files.zip`. It contains only changed/new source, tests, documentation and dependency lockfile changes. No compiled website, APK, installer, vault data, real credentials, or logo changes.

Before applying, export an encrypted `.svlt` backup from your existing app and keep its matching secure key privately. Stop the app, then run from `~/Projects/Spar_Vault`:

```bash
unzip -o ~/Downloads/Spar_Vault_Advanced_Changed_Files.zip -d .
flutter pub get
flutter run -d 28215974
```

For Linux use `flutter run -d linux`; for web use `flutter run -d chrome --web-port 8080`; for Windows run `flutter run -d windows` on a Windows host. Fully restart/rebuild after patching; hot reload cannot load Kotlin/manifest changes. No `rm` command or legacy file deletion is needed. Do not uninstall the phone app or clear browser site data; those actions can remove the only vault copy.

After your first secure-key unlock, use **Settings → Unlock methods → Enable password unlock**. You can then unlock with either a unique 15+ character passphrase or the secure key. Importing the `.txt` key file is supported in unlock and restore. Biometrics are an explicit Android-only option on compatible hardware.

Inactivity lock now defaults to five minutes and can be changed in Settings. Immediate locking when minimized is off by default; a privacy cover hides the app while it is in the background. Resume checks elapsed time even if the OS suspended timers.

The interface now has Vault, Codes, Security, Backups and Settings, with item filters and pagination. It adds encrypted history/attachments, offline TOTP and health checks, verified restore, automatic encrypted backup copies, paired manual transfers/merges and root rotation. Browser autofill setup is in `browser/README.md`.

Old v1 backups remain readable; old apps cannot read newly saved schema-2 backups. Preserve an old backup if you need rollback. After key rotation, old backups still need their old credentials; export a fresh backup and re-enable biometric binding if desired.

Password and biometric unlock change the original recovery rule: a working alternate method can still unlock after your key copy is lost. There is still no provider reset. Losing all enabled unlock methods means losing access.

Android autofill supports certificate-bound native apps; website requests are refused because the Android form API omits the port. The desktop/web extension checks exact HTTPS origins. LAN transfers are native-only; encrypted transfer files work on all targets. Browser backup copies do not protect against clearing/evicting the same browser storage.

Read `docs/VALIDATION.md` for the checks actually run and remaining platform tests. This is a development implementation, not an independent security audit or production security certification.

Restoring writes a fresh authenticated snapshot and resets device-specific automatic-backup/autofill settings. Re-enable them explicitly on the receiving device; passwords, entries, history and portable session/layout settings remain available.
