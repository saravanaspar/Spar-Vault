# Architecture — 0.2

`packages/vault_core` is pure Dart and has no network or storage access. It owns bounded schema-1/schema-2 parsing, CSPRNG root/password generation, unchanged legacy inner AEAD framing, Argon2id password wrappers, RFC 6238 TOTP and paired-transfer ticket/package authentication.

`lib/app/vault_controller.dart` owns the live root and session epoch, serializes writes with compare-and-swap, authenticates staged restores before replacement, tracks encrypted password history/deletion records, previews and merges incoming same-root snapshots, updates encrypted preferences and rotates roots. Password KDF workers use Flutter compute on native targets. They cannot reopen an expired session.

`lib/main.dart` manages session activity/deadlines, resume expiry, privacy covers, explicit clipboard/export actions, section navigation, pagination and foreground autofill approval. `lib/ui` contains entry editors/details, restore credentials, merge choices, TOTP timers and shared input/card widgets. Soft-keyboard changes explicitly report user activity.

`lib/platform` conditionally selects native versus browser storage, integration, bridge and transfer code. Native files keep existing application-support identifiers. Browser IndexedDB keeps the previous vault record, with separate encrypted-only automatic-copy storage. `web/spar_integrations.js` provides granted File System Access or IndexedDB copy rotation; no remote assets or account API are involved.

Android Kotlin implements separate strong-biometric and phone-screen-credential hardware-bound wrapping, SAF directory permission/backup rotation, native autofill certificate/cache checks and explicit secure confirmation. Website autofill fails closed because the Android form API omits the port. No external identity service or broad package-query permission is used.

Linux/Windows opt-in autofill opens a random loopback broker and private expiring state file only while unlocked. `browser/host.py` is the bounded native-messaging relay, installed for one OS user and extension ID. `browser/extension` checks target origins, requests vault approval and fills one top-frame form. Web mode connects to an exact configured open vault tab through nonce-bound messaging; it shares the vault origin's existing trust boundary.

Native LAN transfer binds a selected private IPv4, requires HMAC proof of a fresh nonce, returns an AEAD-bound encrypted snapshot and consumes the ticket once. File pairing works everywhere. Receiving same-ID/current-root snapshots previews changes; foreign vaults use guided restore. This is manual snapshot synchronization, not continuous background sync or automatic propagation.

Existing platform bundle IDs, storage paths and legacy cryptographic contexts remain unchanged. Flutter shares functionality across platforms; signing, OS permissions, packaging and hardware protections still need each target's toolchain and device validation. Complete zeroization, OS-compromise resistance, rollback prevention and security certification are not claimed.

Android setup status is exposed through the existing `spar/integrations` method channel. Authentication settings and autofill selection are awaited and rechecked, including service selection on resume. A prompt-in-progress session guard distinguishes our system authentication Activity from normal backgrounding; it never suppresses inactivity/manual/detached locking or accepts an old result. Dialog routes complete their exit transition before callers dispose text controllers, and transfer code input owns its own widget lifecycle.
