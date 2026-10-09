# Validation — Spar Vault 0.2.1

Validated 2026-10-08 with Flutter 3.47.6 / Dart 3.13.5 in Linux. All secrets used for checks were synthetic, in disposable stores/browser contexts. No real vault was read or modified.

| Check | Result |
| --- | --- |
| Pure Dart vault core | 28 tests passed |
| Flutter controller/UI/native storage/transport/broker | 29 tests passed |
| Root Flutter and core Dart analyzers | No issues |
| Native host Python checks | 3 tests passed |
| Android Kotlin sources | Compile passed against Android API 36, Flutter embedding and AndroidX lifecycle; Kotlin compiler 2.2.10 / JDK 17 |
| Release web build | JavaScript build and Wasm compatibility dry run passed; separate Wasm release not delivered |
| Chromium enrollment | Key copy/download and password enrollment passed |
| Chromium data save | Login title, username and encrypted storage checked |
| Wrong password and damaged import | Refused; current encrypted record retained |
| Key/password unlock and reload | Passed |
| Web autofill bridge | Configured ID, nonce binding and approved-only exact-origin credential response passed |
| Password-authenticated restore in fresh browser context | Passed; device integrations reset |
| Automatic browser encrypted copies | Five-copy rotation/readback passed |
| Offline reload/password unlock | Passed after static cache initialization |
| Primary browser flow external requests / missing assets / page errors | Zero observed |
| Extension's actual injection function | Tested in Chromium: exact HTTPS origin/port, cross-origin action and ambiguous-password-form refusal |
| Complete Chrome/Edge extension installation/connection | Not completed here: full Chrome requires a Unix socket blocked by this environment; source installation instructions provided |
| Compiled Android/Windows/Linux release apps | Not built or device-tested here |

Core checks include the original independent Python AES-GCM/HKDF fixture, new independent libargon2 reference vector, password-wrapper binding/wrong password/tampering/bounded KDF profile, all 18 RFC 6238 SHA1/SHA256/SHA512 vectors, transfer AEAD/code/expiry/request-nonce binding, address validation, attachment limits/unsafe paths, encrypted metadata, duplicate IDs, fresh save randomness and key destruction.

Flutter checks cover expired pending KDF/save/unlock work, password/key alternatives, rotation and old-backup credentials, staged-restore invalidation on lock, restored integration opt-ins reset, history, conflict/deletion-safe merges, CAS/write failures, encrypted native file persistence and Linux 0600 modes, one-use native LAN transport/replay refusal, loopback broker token/Origin refusal and approved-only responses, enrollment copy/clipboard timeout, phone layout, five-minute inactivity, preserving a minimized session, expiry on resume, rejecting late interactions after expiry, and pagination/search resets.

The browser checks use Playwright 1.62.1 / Chrome for Testing headless-shell 155.0.8059.39. Flutter semantic text-input focus must be activated before typing; the script uses keyboard input and verifies restored content, rather than treating DOM proxy values as proof of a saved field. `scripts/web_smoke.cjs` is the reproducible vault check. `scripts/extension_smoke.cjs` supports full extension checks on a host where installation is possible; `SPAR_SKIP_EXTENSION_LOAD=1` tests only its actual injection function.

Android's Kotlin compile validates symbols/type checking, not hardware Keystore enforcement, OEM lifecycle, SAF providers, framework authentication intents or actual form fill. Deprecation warnings use compatible old autofill presentations and the pre-API-31 hardware-query fallback. Android biometric wrapping, enrollment invalidation, screenshot/backup behavior, app-certificate binding and autofill confirmations still need testing on the user's device. No claim is made that the APK or native runner binaries were built in this update.

Windows/native-host packaging, per-user registry setup/ACLs, Linux desktop packaging, browser extension grants/native messaging, end-to-end real app/page autofill, Android 17 network prompts and true multi-device LAN traffic require target-platform validation. LAN encryption is an application protocol, not TLS; it needs independent review. File transfers have cryptographic tests, while the full UI/device chooser matrix needs device testing.

Not performed: independent audit, penetration test, dependency vulnerability assessment, supply-chain attestation, signed releases/installers, store submission, signed update service or OS-compromise protection. These checks are implementation evidence, not security certification.

## 0.2.1 patch checks

Eight new checks cover readable/bounded network labels, receive-transfer input on a 390×844 phone viewport with a 320px keyboard inset (invalid code, cancel, reopen and controller cleanup), missing fingerprint setup before wrapping, blocked permission setup then enrollment, system credential Activity backgrounding with strict background lock, inactivity cancellation and pending-byte cleanup, device unlock waiting for foreground before opening the vault, and first autofill selection/rejection plus later revocation status. Android interactions use a fake method-channel implementation; they do not prove actual sensor, Keystore or OEM behavior. The full Flutter suite has 29 passing tests.

Updated Kotlin symbols are compiled against Android API 36 with the existing Flutter embedding, Kotlin 2.2.10 and JDK 17. Device installation/hardware testing and an independent security audit have not been performed for this patch. User logs only expose Android prompt cancellation and redacted Flutter UI errors, so the exact original OEM exception is not claimed to have been reproduced. The patch removes an identified lifecycle cancellation path and the receive dialog's caller-controller lifetime risk.

The follow-up release web smoke exposed a missing offline-worker registration in the source bootstrap. `web/spar_offline.js` now explicitly caches only an exact list of public JavaScript-release assets, and startup registers it without blocking normal app load. The smoke check waits with a bounded timeout for control and verifies static-cache URL scope before offline reload. It does not cache vaults, transfers or user API responses.
