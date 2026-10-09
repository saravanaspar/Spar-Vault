import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vault_core/vault_core.dart';

import 'app/vault_controller.dart';
import 'features/files.dart';
import 'platform/local_store.dart';
import 'platform/integrations.dart';
import 'platform/transfer.dart';
import 'platform/bridge.dart';
import 'ui/entry_editor.dart';
import 'ui/widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (_) =>
      debugPrint('Spar Vault: UI error (details redacted).');
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Spar Vault: runtime error (details redacted).');
    return true;
  };
  runApp(const SparVaultApp());
}

const ink = Color(0xFF12141B),
    panel = Color(0xFF1D202A),
    accent = Color(0xFFE0BB83);

class SparVaultApp extends StatelessWidget {
  const SparVaultApp({super.key, this.store, this.now, this.integrations});
  final VaultStore? store;
  final DateTime Function()? now;
  final PlatformIntegrations? integrations;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Spar Vault',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      fontFamily: 'LocalSans',
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: ink,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.dark,
        surface: panel,
        primary: accent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF171A23),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      cardTheme: const CardThemeData(color: panel, elevation: 0),
    ),
    home: VaultHome(
      store: store ?? createLocalStore(),
      now: now,
      integrations: integrations,
    ),
  );
}

class VaultHome extends StatefulWidget {
  const VaultHome({
    super.key,
    required this.store,
    this.now,
    this.integrations,
  });
  final VaultStore store;
  final DateTime Function()? now;
  final PlatformIntegrations? integrations;
  @override
  State<VaultHome> createState() => _VaultHomeState();
}

class _VaultHomeState extends State<VaultHome> with WidgetsBindingObserver {
  late final VaultController vault;
  late final integrations = widget.integrations ?? PlatformIntegrations();
  final transfer = LocalTransfer(), bridge = AutofillBridge();
  final keyInput = TextEditingController(),
      passwordInput = TextEditingController(),
      confirmInput = TextEditingController(),
      search = TextEditingController();
  MasterKey? generated;
  VerifiedBackup? staged;
  Timer? idleTimer, clipboardTimer;
  OverlayEntry? privacy;
  Completer<bool>? foregroundWait;
  DateTime? lastActivity, copiedAt, lastAutomaticBackup;
  String? copiedValue, startupError, backupError, lastAutoSnapshot;
  bool acknowledged = false,
      wasUnlocked = false,
      passwordMode = false,
      enrollPassword = false,
      biometricReady = false,
      deviceUnlockReady = false,
      authenticationPending = false;
  DeviceSecurityStatus deviceSecurity = const DeviceSecurityStatus();
  String? integrationError;
  AppLifecycleState lifecycle = AppLifecycleState.resumed;
  int secretEpoch = 0, section = 0, page = 0, filter = 0;
  Future<void> integrationQueue = Future.value();
  DateTime get now => widget.now?.call() ?? DateTime.now();
  DateTime get deadline => (lastActivity ?? now).add(
    Duration(minutes: vault.preferences.idleMinutes),
  );
  bool get active => vault.unlocked || generated != null || staged != null;
  @override
  void initState() {
    super.initState();
    vault = VaultController(widget.store)..addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_keyEvent);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await vault.initialize();
      if (mounted) {
        passwordMode = vault.passwordEnabled;
        await _biometricState();
        setState(() => startupError = null);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => startupError = 'Local storage is unavailable or invalid. Keep your backup and retry after checking storage.',
        );
      }
    }
  }

  Future<void> _biometricState() async {
    try {
      deviceSecurity = await integrations.deviceSecurityStatus();
      biometricReady =
          vault.vaultId != null &&
          await integrations.biometricEnabled(vault.vaultId!);
      deviceUnlockReady =
          vault.vaultId != null &&
          await integrations.deviceUnlockEnabled(vault.vaultId!);
      integrationError = null;
    } catch (_) {
      biometricReady = false;
      deviceUnlockReady = false;
      if (integrations.isAndroid) integrationError = 'Android integration is unavailable. Stop and rebuild the app after installing this update.';
    }
  }

  Future<void> _refreshDeviceSecurity() async {
    await _biometricState();
    if (mounted) setState(() {});
  }

  void _changed() {
    if (!mounted) return;
    if (wasUnlocked && !vault.unlocked) {
      search.clear();
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
    if (!wasUnlocked && vault.unlocked) {
      lastActivity = null;
      _touch();
      passwordInput.clear();
      keyInput.clear();
      confirmInput.clear();
      section = 0;
      page = 0;
    }
    wasUnlocked = vault.unlocked;
    if (vault.unlocked && !vault.busy) {
      _syncIntegrations();
      _automaticBackup();
    }
    setState(() {});
  }

  bool _keyEvent(KeyEvent e) {
    if (e is KeyDownEvent) {
      _touch();
      if (HardwareKeyboard.instance.isControlPressed &&
          e.logicalKey == LogicalKeyboardKey.keyL) {
        _lock();
        return true;
      }
    }
    return false;
  }

  void _touch() {
    if (!active) return;
    if (_expired()) {
      _lock();
      return;
    }
    lastActivity = now;
    idleTimer?.cancel();
    idleTimer = Timer(
      Duration(minutes: vault.unlocked ? vault.preferences.idleMinutes : 5),
      _lock,
    );
    _syncIntegrations();
  }

  bool _expired() =>
      lastActivity != null &&
      (now.isBefore(lastActivity!) || !now.isBefore(deadline));
  void _lock() {
    if (foregroundWait?.isCompleted == false) foregroundWait!.complete(false);
    foregroundWait = null;
    secretEpoch++;
    lastActivity = null;
    idleTimer?.cancel();
    generated?.destroy();
    generated = null;
    staged?.destroy();
    staged = null;
    keyInput.clear();
    passwordInput.clear();
    confirmInput.clear();
    acknowledged = false;
    vault.lock();
    unawaited(integrations.cancelBiometric().catchError((_) {}));
    unawaited(transfer.stop());
    _syncIntegrations();
    Navigator.of(context).popUntil((r) => r.isFirst);
    unawaited(_clearClipboard());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    lifecycle = state;
    if (state == AppLifecycleState.resumed) {
      if (active && _expired()) _lock();
      privacy?.remove();
      privacy?.dispose();
      privacy = null;
      if (foregroundWait?.isCompleted == false) foregroundWait!.complete(true);
      foregroundWait = null;
      unawaited(_refreshDeviceSecurity());
      _syncIntegrations();
      if (copiedAt != null &&
          now.difference(copiedAt!) >= const Duration(seconds: 20)) {
        unawaited(_clearClipboard());
      }
    } else {
      if (privacy == null) {
        privacy = OverlayEntry(
          builder: (_) => const ColoredBox(
            color: ink,
            child: Center(
              child: Icon(Icons.lock_outline, size: 48, color: accent),
            ),
          ),
        );
        Overlay.of(context).insert(privacy!);
      }
      // A system prompt can make this Activity inactive or open Android's PIN
      // activity. Keep the privacy cover and inactivity deadline during it.
      if (vault.unlocked &&
          vault.preferences.lockOnBackground &&
          !authenticationPending) {
        _lock();
      }
      if (state == AppLifecycleState.detached) _lock();
      _syncIntegrations();
    }
  }

  void _syncIntegrations() {
    final epoch = secretEpoch;
    integrationQueue = integrationQueue
        .catchError((_) {})
        .then((_) async {
          if (!mounted || epoch != secretEpoch) return;
          if (!vault.unlocked ||
              (vault.preferences.lockOnBackground &&
                  lifecycle != AppLifecycleState.resumed)) {
            await integrations.clearAutofill();
            await bridge.stop();
            return;
          }
          await integrations.updateAutofill(
            vault.entries,
            vault.preferences,
            deadline,
          );
          if (vault.preferences.autofillEnabled) {
            await bridge.update(
              vault.preferences.desktopExtensionId,
              deadline,
              _chooseFill,
            );
          } else {
            await bridge.stop();
          }
        })
        .catchError((_) {
          if (mounted &&
              integrations.isAndroid &&
              vault.unlocked &&
              vault.preferences.autofillEnabled) {
            setState(
              () => integrationError = 'Android autofill could not be updated. Check the service selection below and retry.',
            );
          }
        });
  }

  Future<void> backupQueue = Future.value();
  void _automaticBackup() {
    if (!vault.unlocked ||
        !vault.preferences.backupEnabled ||
        lastAutoSnapshot == vault.encryptedBackup) {
      return;
    }
    final snapshot = vault.encryptedBackup!,
        prefs = vault.preferences,
        id = vault.vaultId!;
    lastAutoSnapshot = snapshot;
    backupQueue = backupQueue.catchError((_) {}).then((_) async {
      try {
        if (!mounted ||
            !vault.unlocked ||
            !vault.preferences.backupEnabled ||
            vault.vaultId != id) {
          return;
        }
        await integrations.writeBackup(prefs.backupDirectory, snapshot, id);
        if (mounted) {
          setState(() {
            lastAutomaticBackup = now;
            backupError = null;
          });
        }
      } catch (_) {
        if (mounted) {
          setState(
            () => backupError = 'Automatic backup failed. Select the folder again or export a backup now.',
          );
        }
      }
    });
  }

  Future<void> _act(Future<void> Function() task) async {
    try {
      await task();
    } on SessionExpired {
      _message('Session expired. Unlock again.');
    } on ConcurrentVaultChange {
      _message(
        'Another process changed this vault. Lock and reopen before trying again.',
      );
    } on VaultOpenFailure {
      _message(
        'Cannot open: wrong credentials, damaged backup, or unsupported format. Your current vault was kept.',
      );
    } on FormatException catch (e) {
      _message(e.message);
    } on PlatformException catch (e) {
      _message(
        e.message ?? 'Android integration is unavailable. Rebuild the app or review device settings.',
      );
    } on MissingPluginException {
      _message(
        'Stop and rebuild the Android app to install the native integration update.',
      );
    } catch (_) {
      _message(
        'Operation failed. Check permissions, storage and the selected file.',
      );
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<T?> _dialog<T>(Widget child) async {
    final route = DialogRoute<T>(
      context: context,
      builder: (_) => Listener(
        onPointerDown: (_) => _touch(),
        onPointerSignal: (_) => _touch(),
        child: child,
      ),
    );
    final result = await Navigator.of(context).push<T>(route);
    // Text controllers used by callers must outlive the closing animation.
    await route.completed;
    return result;
  }

  Future<bool> _confirm(String title, String text) async =>
      await _dialog<bool>(
        AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ) ==
      true;
  Future<void> _clearClipboard() async {
    clipboardTimer?.cancel();
    final value = copiedValue;
    if (value == null) return;
    try {
      if ((await Clipboard.getData(Clipboard.kTextPlain))?.text == value) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
      if (copiedValue == value) {
        copiedValue = null;
        copiedAt = null;
      }
    } catch (_) {}
  }

  Future<void> _copy(String text, {MasterKey? enrollment}) async {
    if (text.isEmpty ||
        !(enrollment == null
            ? vault.unlocked
            : identical(enrollment, generated))) {
      return;
    }
    final epoch = secretEpoch;
    await Clipboard.setData(ClipboardData(text: text));
    copiedValue = text;
    copiedAt = now;
    if (epoch != secretEpoch) {
      await _clearClipboard();
      return;
    }
    clipboardTimer?.cancel();
    clipboardTimer = Timer(
      const Duration(seconds: 20),
      () => unawaited(_clearClipboard()),
    );
    _message('Copied. Clipboard clearing is attempted after 20 seconds.');
  }

  Future<bool> _save(
    String name,
    Uint8List bytes,
    List<String> extensions, {
    String mime = 'application/octet-stream',
  }) async {
    final result = await FilePicker.saveFile(
      dialogTitle: 'Save $name',
      fileName: name,
      type: FileType.custom,
      allowedExtensions: extensions,
      mimeType: mime,
      bytes: bytes,
    );
    return kIsWeb || result != null;
  }

  Future<void> _saveKey(MasterKey key) async {
    if (!await _confirm(
      'Save an unencrypted key file?',
      'Anyone with this key and your encrypted backup can open the vault. Store the key privately, separate from backups.',
    )) {
      return;
    }
    if (!identical(generated, key)) return;
    final bytes = Uint8List.fromList(utf8.encode('${key.display()}\n'));
    try {
      if (await _save('spar-vault-master-key.txt', bytes, [
        'txt',
      ], mime: 'text/plain')) {
        _message('Key file saved or download requested. Keep it private.');
      }
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  void _enroll() {
    setState(() {
      generated?.destroy();
      generated = MasterKey.generate();
      acknowledged = false;
      confirmInput.clear();
      passwordInput.clear();
    });
    _touch();
  }

  bool _matches(MasterKey key, String text) {
    MasterKey? other;
    try {
      other = MasterKey.parse(text);
      return key.matches(other);
    } on FormatException {
      return false;
    } finally {
      other?.destroy();
    }
  }

  Future<void> _create() async {
    final key = generated;
    if (key == null || !acknowledged) {
      throw const FormatException('Confirm that you saved the key.');
    }
    if (!_matches(key, confirmInput.text)) {
      throw const FormatException('Re-enter the complete key exactly.');
    }
    if (enrollPassword) validateUnlockPassword(passwordInput.text);
    generated = null;
    await vault.create(
      key,
      password: enrollPassword ? passwordInput.text : null,
    );
    passwordMode = vault.passwordEnabled;
  }

  Future<void> _unlock() async {
    if (passwordMode) {
      await vault.unlockWithPassword(passwordInput.text);
    } else {
      await vault.unlock(MasterKey.parse(keyInput.text));
    }
    passwordInput.clear();
    keyInput.clear();
  }

  Future<void> _importKey({bool unlock = true}) async {
    final key = await pickMasterKey();
    if (key == null) return;
    if (unlock) {
      await vault.unlock(key);
    } else {
      keyInput.text = key.display();
      key.destroy();
    }
    _touch();
  }

  Future<T> _systemAuthentication<T>(Future<T> Function() operation) async {
    if (authenticationPending) {
      throw const FormatException(
        'An Android authentication prompt is already open.',
      );
    }
    final epoch = secretEpoch;
    T? result;
    setState(() => authenticationPending = true);
    try {
      result = await operation();
      if (lifecycle != AppLifecycleState.resumed &&
          epoch == secretEpoch &&
          mounted) {
        foregroundWait ??= Completer<bool>();
        final resumed = await foregroundWait!.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => false,
        );
        if (!resumed) throw const SessionExpired();
      }
      if (!mounted || epoch != secretEpoch || (active && _expired())) {
        throw const SessionExpired();
      }
      return result as T;
    } catch (_) {
      if (result is Uint8List) result.fillRange(0, result.length, 0);
      rethrow;
    } finally {
      authenticationPending = false;
      if (mounted) {
        if (active &&
            (_expired() ||
                (vault.preferences.lockOnBackground &&
                    lifecycle != AppLifecycleState.resumed))) {
          _lock();
        }
        setState(() {});
      }
    }
  }

  Future<void> _biometricUnlock({bool deviceLock = false}) async {
    if (!await _prepareAuthentication(deviceLock)) return;
    final epoch = secretEpoch;
    final bytes = await _systemAuthentication(
      () => deviceLock
          ? integrations.unlockDevice(vault.vaultId!)
          : integrations.unlockBiometric(vault.vaultId!),
    );
    if (bytes == null) return;
    try {
      if (epoch != secretEpoch) return;
      await vault.unlock(MasterKey.fromBytes(bytes));
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<void> _exportBackup() async {
    _requireSession();
    final snapshot = vault.encryptedBackup;
    if (snapshot == null) return;
    final bytes = Uint8List.fromList(utf8.encode(snapshot));
    final epoch = secretEpoch;
    try {
      if (await _save('spar-vault-${vault.revision}.svlt', bytes, [
        'svlt',
      ], mime: 'application/json')) {
        _message('Encrypted backup saved or download requested.');
        if (vault.unlocked && epoch == secretEpoch) {
          await vault.updatePreferences(
            vault.preferences.copyWith(lastBackupAt: now.toUtc()),
          );
        }
      }
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<void> _restore({String? snapshot, bool verifyOnly = false}) async {
    snapshot ??= await pickBackup();
    if (snapshot == null || !mounted) return;
    final bundle = VaultBundle.parse(snapshot), epoch = secretEpoch;
    final credentials = await _dialog<UnlockChoice>(
      BackupCredentials(bundle: bundle, touch: _touch),
    );
    if (credentials == null || epoch != secretEpoch) return;
    final key = credentials.usePassword
        ? null
        : MasterKey.parse(credentials.value);
    final checked = await vault.verifyBackup(
      snapshot,
      key: key,
      password: credentials.usePassword ? credentials.value : null,
    );
    if (epoch != secretEpoch) {
      checked.destroy();
      return;
    }
    staged = checked;
    _touch();
    try {
      final summary =
          'Authenticated backup: ${checked.data.entries.length} items, revision ${checked.bundle.header.revision}.\n\n${verifyOnly ? 'The current vault will stay in place.' : 'Restoring replaces the current local vault. Export it first if you need it. No account reset is available.'}';
      if (!await _confirm(
            verifyOnly ? 'Backup verified' : 'Restore verified backup?',
            summary,
          ) ||
          epoch != secretEpoch) {
        return;
      }
      if (verifyOnly) {
        _message('Backup authenticated successfully.');
        return;
      }
      await vault.restoreVerified(checked);
      await _clearDeviceBindings();
      passwordMode = vault.passwordEnabled;
      await _biometricState();
    } finally {
      checked.destroy();
      if (identical(staged, checked)) staged = null;
    }
  }

  void _requireSession() {
    if (!vault.unlocked || _expired()) {
      if (vault.unlocked) _lock();
      throw const SessionExpired();
    }
  }

  Future<void> _edit([VaultEntry? entry]) async {
    _requireSession();
    final epoch = secretEpoch;
    final value = await _dialog<VaultEntry>(
      EntryEditor(entry: entry, touch: _touch, integrations: integrations),
    );
    if (value != null && epoch == secretEpoch && vault.unlocked) {
      await vault.upsert(value);
    }
  }

  Future<void> _details(VaultEntry entry) async {
    _requireSession();
    final epoch = secretEpoch;
    await _dialog<void>(
      EntryDetails(
        entry: entry,
        touch: _touch,
        copy: (s) => _copy(s),
        save: (a) async {
          if (epoch != secretEpoch || !vault.unlocked) return;
          final b = base64Decode(a.base64Bytes);
          try {
            await _save(a.name, b, [
              a.name.contains('.') ? a.name.split('.').last : 'bin',
            ]);
          } finally {
            b.fillRange(0, b.length, 0);
          }
        },
        edit: () {
          Navigator.pop(context);
          unawaited(_act(() => _edit(entry)));
        },
        remove: () async {
          if (await _confirm(
                'Delete item?',
                'A deletion record is retained for merge previews. Old backups still contain this item.',
              ) &&
              epoch == secretEpoch) {
            await vault.delete(entry.id);
            if (mounted) Navigator.pop(context);
          }
        },
      ),
    );
  }

  Future<void> _passwordSettings() async {
    _requireSession();
    final epoch = secretEpoch;
    final input = TextEditingController(), confirm = TextEditingController();
    try {
      final accept = await _dialog<bool>(
        AlertDialog(
          title: Text(
            vault.passwordEnabled
                ? 'Change unlock password'
                : 'Enable password unlock',
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Use a unique passphrase of at least 15 characters. Password and secure key can each unlock this vault. There is no provider reset.',
                ),
                const SizedBox(height: 16),
                VField(
                  controller: input,
                  label: 'New unlock password',
                  secret: true,
                  touch: _touch,
                ),
                const SizedBox(height: 12),
                VField(
                  controller: confirm,
                  label: 'Confirm new password',
                  secret: true,
                  touch: _touch,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (accept == true && epoch == secretEpoch) {
        if (input.text != confirm.text) {
          throw const FormatException('Passwords do not match.');
        }
        await vault.setPassword(input.text);
        passwordMode = true;
        _message('Password unlock enabled. Your secure key still works.');
      }
    } finally {
      input.clear();
      confirm.clear();
      input.dispose();
      confirm.dispose();
    }
  }

  Future<void> _rotate() async {
    _requireSession();
    if (!await _confirm(
      'Rotate the secure key?',
      'This re-encrypts the current vault. Old backups still require their old credentials. Save the new key and export a fresh backup after rotation.',
    )) {
      return;
    }
    var committed = false;
    final next = MasterKey.generate(), epoch = secretEpoch;
    generated = next;
    _touch();
    final typed = TextEditingController(), password = TextEditingController();
    try {
      final accepted = await _dialog<bool>(
        AlertDialog(
          title: const Text('Save your new secure key'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    next.display(),
                    style: const TextStyle(fontFamily: 'LocalMono'),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: () =>
                            _copy(next.display(), enrollment: next),
                        child: const Text('Copy master key'),
                      ),
                      TextButton(
                        onPressed: () => _act(() => _saveKey(next)),
                        child: const Text('Save key file'),
                      ),
                    ],
                  ),
                  VField(
                    controller: typed,
                    label: 'Re-enter new key',
                    secret: true,
                    touch: _touch,
                  ),
                  if (vault.passwordEnabled) ...[
                    const SizedBox(height: 12),
                    VField(
                      controller: password,
                      label: 'New unlock password (15+ characters)',
                      secret: true,
                      touch: _touch,
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Rotate'),
            ),
          ],
        ),
      );
      if (accepted != true || epoch != secretEpoch) return;
      if (!_matches(next, typed.text)) {
        throw const FormatException('New key confirmation does not match.');
      }
      generated = null;
      await vault.rotateKey(
        next,
        password: vault.passwordEnabled ? password.text : null,
      );
      committed = true;
      await _clearDeviceBindings();
      await _biometricState();
      _message(
        'Key rotated. Export a fresh backup and re-enable biometrics if needed.',
      );
    } finally {
      if (identical(generated, next)) generated = null;
      if (!committed) next.destroy();
      typed.clear();
      password.clear();
      typed.dispose();
      password.dispose();
    }
  }

  Future<bool> _prepareAuthentication(bool deviceLock) async {
    await _refreshDeviceSecurity();
    if (integrationError != null) throw FormatException(integrationError!);
    if (deviceSecurity.authentication(deviceLock) == 'ready') return true;
    if (!deviceSecurity.needsSetup(deviceLock)) {
      throw FormatException(deviceSecurity.explanation(deviceLock));
    }
    if (!await _confirm(
      'Set up Android authentication',
      '${deviceSecurity.explanation(deviceLock)} Open Android settings now?',
    )) {
      return false;
    }
    await integrations.requestAuthenticationSetup(deviceLock);
    await _refreshDeviceSecurity();
    if (deviceSecurity.authentication(deviceLock) != 'ready') {
      _message(deviceSecurity.explanation(deviceLock));
      return false;
    }
    return true;
  }

  Future<void> _enableBiometrics({bool deviceLock = false}) async {
    _requireSession();
    if (!await _prepareAuthentication(deviceLock)) return;
    if (!await _confirm(
      deviceLock
          ? 'Enable Phone screen lock?'
          : 'Enable fingerprint / face unlock?',
      deviceLock
          ? 'Your strong fingerprint OR anyone who knows your phone PIN, pattern or password can unlock this vault on this device. Android protects a wrapped key in hardware. This is a local unlock method, not an online passkey or backup recovery.'
          : 'This device will retain a hardware-wrapped copy of the secure key. Losing the key file alone will no longer remove access on this device. Biometrics do not recover a deleted vault.',
    )) {
      return;
    }
    final epoch = secretEpoch, bytes = vault.copyKeyForBiometrics();
    try {
      await _systemAuthentication(
        () => deviceLock
            ? integrations.enableDeviceUnlock(vault.vaultId!, bytes)
            : integrations.enableBiometric(vault.vaultId!, bytes),
      );
      if (epoch != secretEpoch) {
        return;
      }
      await _biometricState();
      setState(() {});
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      if (epoch != secretEpoch) {
        if (deviceLock) {
          await integrations.clearDeviceUnlock();
        } else {
          await integrations.clearBiometric();
        }
      }
    }
  }

  Future<void> _clearDeviceBindings() async {
    await integrations.clearBiometric();
    await integrations.clearDeviceUnlock();
  }

  Future<void> _setAutofill(bool enabled) async {
    _requireSession();
    if (enabled && integrations.isAndroid) {
      await _refreshDeviceSecurity();
      if (integrationError != null) throw FormatException(integrationError!);
      if (!deviceSecurity.autofillSupported) {
        throw const FormatException(
          'Android autofill is unavailable or disabled by device policy.',
        );
      }
      if (!deviceSecurity.autofillSelected) {
        final selected = await integrations.requestAutofill();
        await _refreshDeviceSecurity();
        if (!selected || !deviceSecurity.autofillSelected) {
          _message(
            'Autofill was not enabled. Select Spar Vault in Android autofill settings to use it.',
          );
          return;
        }
      }
    }
    _requireSession();
    await vault.updatePreferences(
      vault.preferences.copyWith(autofillEnabled: enabled),
    );
  }

  Future<void> _autofillSettings() async {
    final selected = await integrations.requestAutofill();
    await _refreshDeviceSecurity();
    _message(
      selected ? 'Spar Vault is selected as the Android autofill service.' : 'Spar Vault is not selected. Autofill stays inactive until you select it in Android settings.',
    );
  }

  Future<void> _localBackupCopies() async {
    final names = await integrations.backupCopies(vault.vaultId!);
    if (names.isEmpty) {
      _message('No browser copies saved. Export an independent backup.');
      return;
    }
    final name = await _dialog<String>(
      SimpleDialog(
        title: const Text('Browser backup copies'),
        children: names
            .map(
              (n) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, n),
                child: Text(n, style: const TextStyle(fontSize: 12)),
              ),
            )
            .toList(),
      ),
    );
    if (name != null) {
      await _restore(snapshot: await integrations.readBackupCopy(name));
    }
  }

  Future<void> _chooseAutomaticBackup() async {
    _requireSession();
    final epoch = secretEpoch, dir = await integrations.chooseBackupDirectory();
    if (dir == null || epoch != secretEpoch) return;
    if (dir == 'browser-storage' &&
        !await _confirm(
          'Browser backup copies',
          'Your browser cannot write to a selected folder. These five encrypted copies live in the same browser storage and will also disappear if site data is cleared. Export independent backups regularly.',
        )) {
      return;
    }
    if (epoch != secretEpoch) return;
    lastAutoSnapshot = null;
    await vault.updatePreferences(
      vault.preferences.copyWith(backupEnabled: true, backupDirectory: dir),
    );
  }

  Future<VaultEntry?> _chooseFill(String origin) async {
    final waitingEpoch = secretEpoch;
    if (privacy != null) {
      foregroundWait ??= Completer<bool>();
      final resumed = await foregroundWait!.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => false,
      );
      if (!resumed || waitingEpoch != secretEpoch) return null;
    }
    if (!vault.unlocked || _expired()) return null;
    final epoch = secretEpoch,
        matches = vault.entries
            .where(
              (e) =>
                  e.kind == EntryKind.login &&
                  webOrigin(e.url) == origin &&
                  e.password.isNotEmpty,
            )
            .toList();
    if (matches.isEmpty) {
      _message('No saved login matches $origin.');
      return null;
    }
    final selected = await _dialog<VaultEntry>(
      AlertDialog(
        title: const Text('Approve autofill'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(origin),
              const Text(
                'Only this exact HTTPS origin receives the selected login.',
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: matches
                      .map(
                        (e) => ListTile(
                          title: Text(e.title),
                          subtitle: Text(e.username),
                          onTap: () => Navigator.pop(context, e),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (epoch != secretEpoch || !vault.unlocked || _expired()) return null;
    return selected;
  }

  Future<void> _sendTransfer({bool lan = false}) async {
    _requireSession();
    final snapshot = vault.encryptedBackup;
    if (snapshot == null) return;
    final epoch = secretEpoch;
    TransferTicket? ticket;
    var senderName = 'This device';
    try {
      if (lan) {
        senderName = await integrations.deviceName();
        final networks = await transfer.networks();
        if (networks.isEmpty) {
          throw const FormatException(
            'No private network address found. Connect both devices to the same trusted network.',
          );
        }
        final address = await _dialog<String>(
          SimpleDialog(
            title: Text('Send from $senderName'),
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Text(
                  'Choose this device’s network. This list is not a scan of nearby devices.',
                ),
              ),
              ...networks.map(
                (n) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, n.address),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$senderName • ${n.label}'),
                      Text(
                        n.address,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
        if (address == null || epoch != secretEpoch) return;
        ticket = await transfer.host(address, snapshot);
      } else {
        ticket = TransferTicket.create();
        final package = await TransferPackage.seal(snapshot, ticket),
            bytes = Uint8List.fromList(utf8.encode(package));
        try {
          if (!await _save('spar-vault-transfer.svx', bytes, [
            'svx',
          ], mime: 'application/json')) {
            return;
          }
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      }
      if (epoch != secretEpoch) return;
      final code = ticket.encode();
      await _dialog<void>(
        AlertDialog(
          title: const Text('Private transfer code'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    lan
                        ? 'Sending from $senderName. The receiver fetches once using this private code, which includes the network address.'
                        : 'Send the encrypted .svx file to the receiver too.',
                  ),
                  const Text(
                    'The code expires in five minutes. Share it privately. It protects transport and does not contain your master key.',
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    code,
                    style: const TextStyle(
                      fontFamily: 'LocalMono',
                      fontSize: 12,
                    ),
                  ),
                  TextButton(
                    onPressed: () => _copy(code),
                    child: const Text('Copy transfer code'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Finish transfer'),
            ),
          ],
        ),
      );
    } finally {
      await transfer.stop();
      ticket?.destroy();
    }
  }

  Future<void> _receiveTransfer({bool lan = false}) async {
    final epoch = secretEpoch;
    final code = await _dialog<String>(TransferCodeDialog(touch: _touch));
    if (code == null || epoch != secretEpoch) return;
    final ticket = TransferTicket.parse(code);
    try {
      String snapshot;
      if (lan) {
        snapshot = await transfer.receive(ticket);
      } else {
        final bytes = await pickBytes(
          limit: maxTransferBytes,
          extension: 'svx',
          title: 'Select encrypted transfer .svx',
        );
        if (bytes == null) return;
        try {
          snapshot = await TransferPackage.open(utf8.decode(bytes), ticket);
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      }
      if (epoch != secretEpoch) return;
      if (!vault.unlocked ||
          VaultBundle.parse(snapshot).header.vaultId != vault.vaultId) {
        await _restore(snapshot: snapshot);
        return;
      }
      final preview = await vault.previewMerge(snapshot);
      if (epoch != secretEpoch) return;
      final choice = await _dialog<MergeChoice>(MergeDialog(preview: preview));
      if (choice != null && epoch == secretEpoch) {
        await vault.mergeSnapshot(
          snapshot,
          useIncomingConflicts: choice.conflicts,
          applyDeletions: choice.deletions,
        );
        _message('Transfer merged. Local unlock settings were kept.');
      }
    } finally {
      ticket.destroy();
    }
  }

  @override
  void dispose() {
    if (foregroundWait?.isCompleted == false) foregroundWait!.complete(false);
    foregroundWait = null;
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_keyEvent);
    idleTimer?.cancel();
    clipboardTimer?.cancel();
    privacy?.remove();
    privacy?.dispose();
    generated?.destroy();
    staged?.destroy();
    vault.removeListener(_changed);
    vault.dispose();
    unawaited(integrations.cancelBiometric().catchError((_) {}));
    unawaited(integrations.clearAutofill());
    unawaited(bridge.stop());
    unawaited(transfer.stop());
    unawaited(_clearClipboard());
    for (final c in [keyInput, passwordInput, confirmInput, search]) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => _touch(),
    onPointerSignal: (_) => _touch(),
    child: Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.shield_outlined, color: accent),
            const SizedBox(width: 10),
            const Flexible(
              child: Text('Spar Vault', overflow: TextOverflow.ellipsis),
            ),
            if (vault.unlocked && MediaQuery.sizeOf(context).width > 600) ...[
              const SizedBox(width: 12),
              Text(
                'Local • encrypted',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ],
        ),
        actions: [
          if (vault.unlocked)
            IconButton(
              tooltip: 'Lock vault (Ctrl+L)',
              onPressed: _lock,
              icon: const Icon(Icons.lock_outline),
            ),
        ],
      ),
      body: !vault.initialized
          ? Center(
              child: startupError == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(startupError!),
                        TextButton(
                          onPressed: _initialize,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
            )
          : vault.unlocked
          ? _workspace()
          : _locked(),
      bottomNavigationBar:
          vault.unlocked && MediaQuery.sizeOf(context).width < 850
          ? NavigationBar(
              selectedIndex: section,
              onDestinationSelected: (s) {
                _touch();
                setState(() => section = s);
              },
              destinations: destinations,
            )
          : null,
    ),
  );
  static const destinations = [
    NavigationDestination(icon: Icon(Icons.key_outlined), label: 'Vault'),
    NavigationDestination(icon: Icon(Icons.timer_outlined), label: 'Codes'),
    NavigationDestination(
      icon: Icon(Icons.health_and_safety_outlined),
      label: 'Security',
    ),
    NavigationDestination(icon: Icon(Icons.backup_outlined), label: 'Backups'),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      label: 'Settings',
    ),
  ];
  Widget _locked() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: ListView(
        padding: const EdgeInsets.all(24),
        shrinkWrap: true,
        children: [
          const Icon(Icons.shield_outlined, size: 60, color: accent),
          const SizedBox(height: 16),
          Text(
            generated != null
                ? 'Keep your secure key safe'
                : vault.hasVault
                ? 'Welcome back.'
                : 'Your passwords. Your device.',
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          if (generated != null) ...[
            const Text(
              'This random key unlocks your vault. Save it privately. Losing all enabled unlock methods means losing access. The app cannot reset them.',
            ),
            const SizedBox(height: 16),
            Text(
              generated!.display(),
              style: const TextStyle(fontFamily: 'LocalMono', fontSize: 17),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => _act(
                    () => _copy(generated!.display(), enrollment: generated),
                  ),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy master key'),
                ),
                TextButton.icon(
                  onPressed: () => _act(() => _saveKey(generated!)),
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Save key file'),
                ),
              ],
            ),
            VField(
              controller: confirmInput,
              label: 'Re-enter the full master key',
              secret: true,
              touch: _touch,
            ),
            CheckboxListTile(
              value: acknowledged,
              onChanged: (v) => setState(() => acknowledged = v ?? false),
              title: const Text(
                'I saved my key privately and understand there is no provider reset.',
              ),
              contentPadding: EdgeInsets.zero,
            ),
            SwitchListTile(
              value: enrollPassword,
              onChanged: (v) => setState(() => enrollPassword = v),
              title: const Text('Also enable password unlock'),
              subtitle: const Text(
                'An additional unlock method; use a unique passphrase.',
              ),
            ),
            if (enrollPassword)
              VField(
                controller: passwordInput,
                label: 'Unlock password (15+ characters)',
                secret: true,
                touch: _touch,
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: vault.busy ? null : () => _act(_create),
              child: const Text('Create encrypted vault'),
            ),
            TextButton(onPressed: _lock, child: const Text('Cancel')),
          ] else if (vault.hasVault) ...[
            const Text(
              'Unlock locally. Neither your credentials nor your vault are sent to a server.',
            ),
            const SizedBox(height: 20),
            if (vault.passwordEnabled)
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Password')),
                  ButtonSegment(value: false, label: Text('Secure key')),
                ],
                selected: {passwordMode},
                onSelectionChanged: (s) {
                  keyInput.clear();
                  passwordInput.clear();
                  setState(() => passwordMode = s.first);
                },
              ),
            const SizedBox(height: 16),
            VField(
              controller: passwordMode ? passwordInput : keyInput,
              label: passwordMode ? 'Unlock password' : 'Secure key',
              secret: true,
              touch: _touch,
              onSubmitted: (_) => _act(_unlock),
            ),
            if (!passwordMode)
              TextButton.icon(
                onPressed: vault.busy ? null : () => _act(() => _importKey()),
                icon: const Icon(Icons.upload_file),
                label: const Text('Import master-key .txt file'),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: vault.busy ? null : () => _act(_unlock),
              child: Text(vault.busy ? 'Opening…' : 'Unlock vault'),
            ),
            if (biometricReady)
              TextButton.icon(
                onPressed: vault.busy || authenticationPending
                    ? null
                    : () => _act(_biometricUnlock),
                icon: const Icon(Icons.fingerprint),
                label: const Text('Unlock with biometrics'),
              ),
            if (deviceUnlockReady)
              TextButton.icon(
                onPressed: vault.busy || authenticationPending
                    ? null
                    : () => _act(() => _biometricUnlock(deviceLock: true)),
                icon: const Icon(Icons.phonelink_lock),
                label: const Text('Unlock with Phone screen lock'),
              ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: vault.busy ? null : () => _act(() => _restore()),
              child: const Text('Restore encrypted backup'),
            ),
          ] else ...[
            const Text(
              'An offline-first vault with no account, no recovery service and no telemetry.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _enroll,
              child: const Text('Create a new vault'),
            ),
            TextButton(
              onPressed: () => _act(() => _restore()),
              child: const Text('Restore encrypted backup'),
            ),
            TextButton(
              onPressed: () => _act(() => _receiveTransfer()),
              child: const Text('Receive encrypted transfer file'),
            ),
          ],
          if (vault.busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 24),
          const Text(
            'Encryption cannot protect an unlocked device from malware. This release needs independent security review before use for high-value secrets.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    ),
  );
  Widget _workspace() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (MediaQuery.sizeOf(context).width >= 850)
        NavigationRail(
          selectedIndex: section,
          onDestinationSelected: (s) => setState(() => section = s),
          labelType: NavigationRailLabelType.all,
          destinations: destinations
              .map(
                (d) => NavigationRailDestination(
                  icon: d.icon,
                  label: Text(d.label),
                ),
              )
              .toList(),
        ),
      Expanded(
        child: Stack(
          children: [
            Positioned.fill(
              child: switch (section) {
                0 => _vaultPage(),
                1 => _codesPage(),
                2 => _securityPage(),
                3 => _backupPage(),
                _ => _settingsPage(),
              },
            ),
            if (vault.busy)
              const Align(
                alignment: Alignment.topCenter,
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
    ],
  );
  Widget _page(String title, List<Widget> children, {String? subtitle}) =>
      ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(subtitle, style: const TextStyle(color: Colors.grey)),
          ],
          const SizedBox(height: 24),
          ...children,
        ],
      );
  Widget _vaultPage() {
    final query = search.text.toLowerCase();
    final entries =
        vault.entries
            .where(
              (e) =>
                  (filter != 1 || e.kind == EntryKind.login) &&
                  (filter != 2 || e.kind == EntryKind.note) &&
                  (filter != 3 || e.favorite) &&
                  [
                    e.title,
                    e.username,
                    e.url,
                    e.notes,
                  ].any((s) => s.toLowerCase().contains(query)),
            )
            .toList()
          ..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
    final size = vault.preferences.pageSize,
        pages = (entries.length / size).ceil().clamp(1, 2000);
    page = page.clamp(0, pages - 1);
    return _page('Your vault', [
      Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: MediaQuery.sizeOf(context).width < 500 ? 240 : 360,
            child: VField(
              controller: search,
              label: 'Search items',
              touch: _touch,
              onChanged: (_) => setState(() => page = 0),
            ),
          ),
          FilledButton.icon(
            onPressed: vault.busy ? null : () => _act(() => _edit()),
            icon: const Icon(Icons.add),
            label: const Text('Add item'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        children: List.generate(
          4,
          (i) => ChoiceChip(
            label: Text(['All', 'Logins', 'Notes', 'Favorites'][i]),
            selected: filter == i,
            onSelected: (_) => setState(() {
              filter = i;
              page = 0;
            }),
          ),
        ),
      ),
      const SizedBox(height: 16),
      if (entries.isEmpty)
        const Card(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Text('No matching items. Add a login or secure note.'),
          ),
        ),
      ...entries
          .skip(page * size)
          .take(size)
          .map(
            (e) => Card(
              child: ListTile(
                leading: Icon(
                  e.kind == EntryKind.note
                      ? Icons.notes_outlined
                      : Icons.key_outlined,
                  color: accent,
                ),
                title: Text(
                  e.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  e.username.isNotEmpty ? e.username : e.kind.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Icon(e.favorite ? Icons.star : Icons.chevron_right),
                onTap: () => _act(() => _details(e)),
              ),
            ),
          ),
      const SizedBox(height: 12),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Previous page',
            onPressed: page > 0 ? () => setState(() => page--) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Flexible(
            child: Text(
              'Page ${page + 1} / $pages • ${entries.length} items',
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            tooltip: 'Next page',
            onPressed: page + 1 < pages ? () => setState(() => page++) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    ]);
  }

  Widget _codesPage() => _page('Authenticator codes', [
    const Text(
      'Codes are generated offline. Your device clock must be correct. Saving TOTP beside its password reduces separation between authentication factors.',
    ),
    const SizedBox(height: 16),
    if (!vault.entries.any((e) => e.totp.isNotEmpty))
      const Text(
        'Add a Base32 secret or otpauth URI in an item’s Authenticator section.',
      ),
    ...vault.entries
        .where((e) => e.totp.isNotEmpty)
        .map((e) => OtpCard(entry: e, copy: _copy)),
  ]);
  Widget _securityPage() {
    final h = HealthReport(vault.entries);
    Widget group(String title, List<VaultEntry> entries) => SectionCard(
      title: title,
      children: [
        if (entries.isEmpty) const Text('No matches.'),
        ...entries.map(
          (e) => ListTile(
            title: Text(e.title),
            subtitle: Text(e.username),
            onTap: () => _act(() => _edit(e)),
          ),
        ),
      ],
    );
    return _page('Security overview', [
      const Text(
        'These checks run entirely on this device. They are limited heuristics, not a breach check or a guarantee of password strength.',
      ),
      const SizedBox(height: 16),
      group('Short passwords (${h.short.length})', h.short),
      group('Reused passwords (${h.reused.length})', h.reused),
      group('Letters-only passwords (${h.wordOnly.length})', h.wordOnly),
      const Text(
        'Long random passphrases can be strong even if they contain only letters. Use a unique password for each account.',
      ),
      const SizedBox(height: 20),
      SectionCard(
        title: 'Backup status',
        children: [
          Text(
            backupError ??
                (lastAutomaticBackup != null
                    ? 'Automatic encrypted copy saved this session.'
                    : vault.preferences.lastBackupAt == null
                    ? 'No manual export recorded. Export and verify a backup.'
                    : 'Last manual export: ${vault.preferences.lastBackupAt!.toLocal()}'),
          ),
          if (vault.preferences.lastBackupAt == null ||
              now.difference(vault.preferences.lastBackupAt!).inDays >=
                  vault.preferences.backupReminderDays)
            const Text(
              'Backup reminder: export an independent copy and verify it.',
            ),
        ],
      ),
    ]);
  }

  Widget _backupPage() => _page('Backups & transfers', [
    SectionCard(
      title: 'Encrypted backups',
      children: [
        const Text(
          'A backup is the .svlt file containing encrypted entries. A master-key .txt file alone has no passwords to restore.',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () => _act(_exportBackup),
              icon: const Icon(Icons.download),
              label: const Text('Export backup'),
            ),
            OutlinedButton(
              onPressed: () => _act(() => _restore(verifyOnly: true)),
              child: const Text('Verify backup'),
            ),
            OutlinedButton(
              onPressed: () => _act(() => _restore()),
              child: const Text('Restore backup'),
            ),
          ],
        ),
      ],
    ),
    SectionCard(
      title: 'Automatic encrypted copies',
      children: [
        if (vault.preferences.backupDirectory == 'browser-storage')
          TextButton(
            onPressed: () => _act(_localBackupCopies),
            child: const Text('Review browser backup copies'),
          ),
        Text(
          vault.preferences.backupEnabled
              ? 'Enabled • keeps the latest five copies for this vault.'
              : 'Disabled. Choose a private folder to enable.',
        ),
        if (backupError != null)
          Text(backupError!, style: const TextStyle(color: Colors.orange)),
        if (vault.preferences.backupDirectory == 'browser-storage')
          const Text(
            'Browser copies share the same storage failure risk. Export independent backups.',
          ),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: () => _act(_chooseAutomaticBackup),
              child: const Text('Choose backup folder'),
            ),
            if (vault.preferences.backupEnabled)
              TextButton(
                onPressed: () => _act(
                  () => vault.updatePreferences(
                    vault.preferences.copyWith(backupEnabled: false),
                  ),
                ),
                child: const Text('Disable automatic copies'),
              ),
          ],
        ),
        DropdownButtonFormField<int>(
          initialValue: vault.preferences.backupReminderDays,
          decoration: const InputDecoration(
            labelText: 'Independent backup reminder',
          ),
          items: [1, 3, 7, 14, 30]
              .map(
                (n) => DropdownMenuItem(value: n, child: Text('Every $n days')),
              )
              .toList(),
          onChanged: (v) => _act(
            () => vault.updatePreferences(
              vault.preferences.copyWith(backupReminderDays: v),
            ),
          ),
        ),
      ],
    ),
    SectionCard(
      title: 'Paired device transfer',
      children: [
        const Text(
          'Transfers are authenticated and encrypted with a five-minute private code. They move an encrypted vault snapshot, never your secure key. Receiving a matching vault shows additions, conflicts and deletions before merging.',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: () => _act(() => _sendTransfer()),
              child: const Text('Send transfer file'),
            ),
            OutlinedButton(
              onPressed: () => _act(() => _receiveTransfer()),
              child: const Text('Receive transfer file'),
            ),
            if (transfer.canHost) ...[
              OutlinedButton(
                onPressed: () => _act(() => _sendTransfer(lan: true)),
                child: const Text('Send over local network'),
              ),
              OutlinedButton(
                onPressed: () => _act(() => _receiveTransfer(lan: true)),
                child: const Text('Receive over local network'),
              ),
            ],
          ],
        ),
      ],
    ),
  ]);
  Widget _settingsPage() => _page('Settings', [
    SectionCard(
      title: 'Session & layout',
      children: [
        DropdownButtonFormField<int>(
          key: ValueKey('idle-${vault.preferences.idleMinutes}'),
          initialValue: vault.preferences.idleMinutes,
          decoration: const InputDecoration(labelText: 'Lock after inactivity'),
          items: [1, 2, 5, 10, 15, 30]
              .map((n) => DropdownMenuItem(value: n, child: Text('$n minutes')))
              .toList(),
          onChanged: (v) => _act(() async {
            await vault.updatePreferences(
              vault.preferences.copyWith(idleMinutes: v),
            );
            _touch();
          }),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Lock immediately when minimized'),
          subtitle: const Text(
            'Off: switching apps keeps the session until its inactivity deadline.',
          ),
          value: vault.preferences.lockOnBackground,
          onChanged: (v) => _act(
            () => vault.updatePreferences(
              vault.preferences.copyWith(lockOnBackground: v),
            ),
          ),
        ),
        DropdownButtonFormField<int>(
          initialValue: vault.preferences.pageSize,
          decoration: const InputDecoration(labelText: 'Items per page'),
          items: [10, 20, 50]
              .map((n) => DropdownMenuItem(value: n, child: Text('$n items')))
              .toList(),
          onChanged: (v) => _act(
            () => vault.updatePreferences(
              vault.preferences.copyWith(pageSize: v),
            ),
          ),
        ),
      ],
    ),
    SectionCard(
      title: 'Unlock methods',
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            vault.passwordEnabled
                ? 'Password unlock enabled'
                : 'Secure key unlock',
          ),
          subtitle: const Text(
            'The random secure key always remains an unlock method. No server reset exists.',
          ),
          trailing: const Icon(Icons.password),
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: () => _act(_passwordSettings),
              child: Text(
                vault.passwordEnabled
                    ? 'Change password'
                    : 'Enable password unlock',
              ),
            ),
            if (vault.passwordEnabled)
              TextButton(
                onPressed: () => _act(() async {
                  if (await _confirm(
                    'Remove password unlock?',
                    'Make sure you still have your secure key before removing this unlock method.',
                  )) {
                    await vault.setPassword(null);
                    passwordMode = false;
                  }
                }),
                child: const Text('Remove password unlock'),
              ),
            TextButton(
              onPressed: () => _act(_rotate),
              child: const Text('Rotate secure key'),
            ),
          ],
        ),
        if (integrations.isAndroid)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(deviceSecurity.explanation(false)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: authenticationPending
                        ? null
                        : () => _act(_enableBiometrics),
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('Enable biometric unlock'),
                  ),
                  if (biometricReady)
                    TextButton(
                      onPressed: authenticationPending
                          ? null
                          : () => _act(() async {
                              await integrations.clearBiometric();
                              await _biometricState();
                              setState(() {});
                            }),
                      child: const Text('Remove biometric unlock'),
                    ),
                  TextButton.icon(
                    onPressed: authenticationPending
                        ? null
                        : () => _act(() => _enableBiometrics(deviceLock: true)),
                    icon: const Icon(Icons.phonelink_lock),
                    label: Text(
                      deviceUnlockReady
                          ? 'Replace Phone screen lock binding'
                          : 'Enable Phone screen lock',
                    ),
                  ),
                  if (deviceUnlockReady)
                    TextButton(
                      onPressed: authenticationPending
                          ? null
                          : () => _act(() async {
                              await integrations.clearDeviceUnlock();
                              await _refreshDeviceSecurity();
                            }),
                      child: const Text('Remove Phone screen lock'),
                    ),
                ],
              ),
              const Text(
                'Phone screen lock uses Android’s fingerprint or PIN/pattern/password prompt. It is local to this phone and is not a synced passkey.',
              ),
              if (integrationError != null) Text(integrationError!),
              TextButton(
                onPressed: () => _act(_refreshDeviceSecurity),
                child: const Text('Refresh Android status'),
              ),
            ],
          ),
      ],
    ),
    SectionCard(
      title: 'Autofill integration',
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: vault.preferences.autofillEnabled,
          title: const Text('Allow confirmed autofill while unlocked'),
          subtitle: const Text(
            'Never fills while the vault is locked. Each request requires approval.',
          ),
          onChanged: (v) => _act(() => _setAutofill(v)),
        ),
        if (integrations.isAndroid) ...[
          Text(
            deviceSecurity.autofillSelected
                ? 'Android service: Spar Vault selected'
                : 'Android service: Spar Vault not selected — setup required',
          ),
          if (vault.preferences.autofillEnabled &&
              !deviceSecurity.autofillSelected)
            const Text(
              'Autofill is paused. Tap the settings button below to enable Spar Vault again.',
            ),
          const Text(
            'Bind native apps to their installed signing certificates in each item. Android website autofill is refused because its form API omits the port. Use native app bindings; desktop/web website fill uses the bundled extension.',
          ),
          TextButton(
            onPressed: () => _act(_autofillSettings),
            child: const Text('Select Spar Vault in Android autofill settings'),
          ),
        ],
        if (!integrations.isAndroid) ...[
          const Text(
            'Install the bundled Chrome/Edge extension. Configure its 32-letter extension ID here. Native desktop also needs the bundled native messaging host; web mode needs this vault tab open.',
          ),
          TextButton(
            onPressed: () => _act(() async {
              final c = TextEditingController(
                text: vault.preferences.desktopExtensionId,
              );
              try {
                final ok = await _dialog<bool>(
                  AlertDialog(
                    title: const Text('Browser extension ID'),
                    content: VField(
                      controller: c,
                      label: '32-letter extension ID',
                      touch: _touch,
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  await vault.updatePreferences(
                    vault.preferences.copyWith(
                      desktopExtensionId: c.text.trim(),
                    ),
                  );
                }
              } finally {
                c.dispose();
              }
            }),
            child: const Text('Configure extension ID'),
          ),
          if (bridge.statePath != null)
            SelectableText(
              'Native host state file: ${bridge.statePath}',
              style: const TextStyle(fontSize: 12),
            ),
        ],
      ],
    ),
    const Text(
      'Spar Vault 0.2 • No telemetry • No provider recovery\nAttachments, old passwords, codes and settings are encrypted inside the vault. Managed runtimes cannot guarantee erasure of immutable strings or copies made by the OS.',
      style: TextStyle(fontSize: 12, color: Colors.grey),
    ),
  ]);
}
