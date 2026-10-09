# Spar Vault confirmed autofill

This source extension supports Chrome/Chromium and Edge on Linux and Windows. Android Chrome is not supported by this desktop extension. It fills only a single visible password form on the top page at its exact HTTPS origin, after approval in Spar Vault. It refuses HTTP pages, ambiguous forms, new-password forms, cross-origin form actions and changed target origins. It never submits forms.

## Extension

1. Open `chrome://extensions` or `edge://extensions`, enable Developer mode, and Load unpacked → this `extension` folder.
2. Copy its 32-letter ID. In Spar Vault → Settings → Autofill, enable confirmed autofill and configure that ID.
3. Open the extension's Integration options. Choose Desktop app or Open web vault tab.
4. Save your login with its HTTPS website URL in the vault. Click the extension on the login page → Request autofill. Switch to the vault and approve the exact site/account within 30 seconds. The target login tab can then receive the selection; no autosubmit.

The extension needs activeTab, scripting, nativeMessaging and storage. Only non-secret connection settings are stored. Web mode asks for optional access to the selected vault origin only. Prior optional origin grants are removed when changing connections. Permissions are origin-level; the vault tab is additionally located by exact pathname.

## Linux native host

The unlocked desktop app shows its **Native host state file** in Settings after autofill and the extension ID are configured. Use that exact path:

```bash
python3 browser/install_host.py --extension-id YOUR_32_LETTER_ID --state-file '/path/shown/by/Spar/Vault/bridge.json'
```

Python 3 is required. Installation writes only current-user Chrome/Chromium/Edge native-messaging manifests and a private host directory. Restart your browser. Reinstall if the extension ID, Python location or app state path changes. Snap/Flatpak browser sandboxes can block native hosts; use web mode or a browser installation with native-messaging support.

## Windows native host

Python 3 is needed for local packaging/installation. Build the executable on Windows, then install it for the current user:

```powershell
python -m pip install pyinstaller
python -m PyInstaller --onefile --name spar_native_host browser/host.py
python browser/install_host.py --extension-id YOUR_32_LETTER_ID --state-file "C:\path\shown\by\Spar\Vault\bridge.json" --host-executable dist/spar_native_host.exe
```

The installer registers only HKCU native-host entries and restricts allowed_origins to that extension ID. Source-only delivery includes no executable or installer. Test a signed packaged host before distributing to other people.

## Web tab

Enter the full HTTPS vault URL in extension options, or `http://127.0.0.1:8080/` for your local development build. Grant the requested vault-origin permission. Keep that exact vault page open and unlocked, and configure this extension's ID in the vault. No native host is needed. Switch to the vault tab to approve requests; the extension keeps the request running while its popup is closed.

Web mode uses a nonce-bound same-window message bridge and mandatory foreground approval. Code/other scripts already running on the vault origin remain trusted; the bridge does not isolate secrets from a compromised first-party vault or malicious extension. There is no externally_connectable endpoint.

## Boundary and removal

The native app opens a random loopback port only when integration is explicitly enabled and the vault is unlocked. A private 0600 file holds its session token, port, expiry and one extension ID. No root key or credential list is written there. The host validates bounded framing, allowed caller, private state, expiry and response binding. Requests are rate/concurrency bounded and require approval in the app. Locking deletes the state file, invalidates the token and closes the port. Same-user malware/administrators can still attack an unlocked process.

To disable, switch off autofill in the vault and remove the extension. Linux host files are under `~/.local/share/spar-vault/browser-host` and the three browser profile `NativeMessagingHosts` folders. Windows host files are under `%LOCALAPPDATA%\SparVault\BrowserHost`; remove only this host's HKCU NativeMessagingHosts entries if uninstalling. Do not delete your actual vault data.
