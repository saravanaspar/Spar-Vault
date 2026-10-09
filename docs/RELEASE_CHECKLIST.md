# Before real credentials

Current delivery: development source and any explicitly listed tested builds. Not a signed, audited production release.

- Commission an independent review of the key lifecycle, custom envelope protocol, AEAD parameters, randomness, parsers, async cancellation and import replacement flow.
- Review resolved dependencies and their provenance. Retain lockfiles, establish a vulnerability/update policy, and pin build tools and CI actions for release automation.
- Test encrypted storage and atomic replacement on Windows, macOS, Linux, Android and iOS. Exercise disk-full, abrupt termination, power-loss, quota/eviction and corrupted-file failures.
- Test screenshot/app-switcher behavior and OS backup exclusion on actual Android/iOS devices. Confirm entitlement, sandbox, directory ACL and file-protection behavior.
- Verify background, minimize, screen-lock, idle-lock, reveal expiry and clipboard behavior on every target; account for OS clipboard history and sync.
- Test web CSP, network traffic, malicious framing, updates, service-worker caching, stale tabs, storage transactions, offline reloads, deployment cache policy and supply-chain compromise scenarios. Keep the domain and delivered code under tightly controlled ownership.
- Restore synthetic backups across native and browser builds, including non-Latin text and maximum supported field sizes. Test incorrect-key import does not alter the existing vault.
- Build signed Android/iOS/Windows/macOS installers on suitable host systems, protect signing keys, and define a verifiable update channel. Linux packaging and OS integration also need release review.
- Remove or revise the development-build label only after documented review. Do not remove the security limitations from release documentation.

## Added in 0.2

- Independently review Argon2id parameters/wrapper AAD, password change/removal, root rotation, legacy migration and old-backup behavior. Benchmark KDF cost/memory on each device; do not loosen the pinned profile silently.
- Exercise biometrics with TEE/StrongBox, missing hardware, cancellation, enrollment changes, key invalidation, process death and rotation/restore. Confirm that cipher authorization is required on each use.
- Test Android autofill with incorrect package/signers, changed certificates, expiry/lock, cancellation, missing/ambiguous fields and spoofed requests. All website forms must fail closed in this release.
- Test native messaging and web-tab approval on Chrome/Edge/Linux/Windows: permission grants, wrong extension IDs/tokens/origins/ports, tab navigation during approval, same-origin attacker scripts and locked/background sessions. Review native-host installer/ACLs and sign distributable executables.
- Review paired-file/LAN framing, code secrecy, expiry/clock changes, nonce binding, one-use consumption, traffic limits and concurrent cancellation. Test true multi-device traffic, firewalls and Android local-network permissions.
- Verify automatic copy rotation cannot delete unrelated files; test revoked directory permission, SAF provider failures, storage quota, interrupted writes and independent restore.
- Test history/attachments/TOTP persistence and limits, plaintext export warnings, merge conflicts/deletion resurrection choices, pagination and software-keyboard activity expiry.

## Android 0.2.1 follow-up

- Exercise biometric-only and Phone screen lock enrollment/unlock on the actual Xiaomi Android 14 device, with correct/wrong fingerprint, PIN/pattern/password fallback, cancellation, lockout and re-enrollment. Confirm no root unwrap is possible without the CryptoObject's hardware authorization.
- Check missing screen credential, no strong sensor, Android 16 biometrics-for-apps restrictions, rejected settings, unsupported hardware and native bindings from the previous release.
- Check a strict background-lock setting during the system credential Activity, real Home/background, privacy cover, 90-second prompt timeout, original inactivity expiry, manual lock and late callbacks.
- Exercise first Android autofill service selection, cancelled/rejected selector, revocation in Android settings, OEM settings screens and actual certificate-bound native login forms. Websites remain refused.
- On Android, web, Linux and Windows test receive dialog with visible keyboard, pasted valid/invalid/expired code, Cancel, outside-tap dismissal and file picker cancellation. Check sender/network labels and real two-device LAN transfer.

- Bump the `spar_offline.js` cache version on each release, verify the exact public asset allowlist matches its JavaScript build, and test offline reload, worker upgrades and eviction. Rework the allowlist before claiming support for a separate Wasm build.
