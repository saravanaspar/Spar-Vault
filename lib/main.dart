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
import 'platform/nearby.dart';
import 'ui/nearby_transfer.dart';
import 'platform/bridge.dart';
import 'platform/picker_options.dart';
import 'ui/entry_editor.dart';
import 'ui/widgets.dart';
import 'ui/authenticator_import.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final entry in <String, String>{
      'Spar Vault': 'LICENSE',
      'DejaVu fonts': 'assets/fonts/LICENSE.txt',
      'Flutter': 'third_party/licenses/Flutter.txt',
      'ZXing': 'third_party/licenses/ZXing-Apache-2.0.txt',
      'libfido2': 'third_party/licenses/libfido2.txt',
    }.entries) {
      yield LicenseEntryWithLineBreaks([
        entry.key,
      ], await rootBundle.loadString(entry.value));
    }
  });
  warmupLinuxWindowId();
  FlutterError.onError = (_) =>
      debugPrint('Spar Vault: UI error (details redacted).');
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Spar Vault: runtime error (details redacted).');
    return true;
  };
  runApp(const SparVaultApp());
}

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
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
        labelStyle: const TextStyle(color: dimText),
      ),
      cardTheme: CardThemeData(
        color: panel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: borderSubtle),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: panel,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: surface,
        contentTextStyle: const TextStyle(color: Color(0xFFF5F7FF)),
        actionTextColor: accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: const DividerThemeData(color: borderSubtle),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        selectedColor: accentDim,
        side: const BorderSide(color: borderSubtle),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        labelStyle: const TextStyle(color: dimText, fontSize: 13),
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: panel,
        indicatorColor: accentDim,
        selectedIconTheme: IconThemeData(color: accent),
        unselectedIconTheme: IconThemeData(color: dimText),
        selectedLabelTextStyle: TextStyle(
          color: accent,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
        unselectedLabelTextStyle: TextStyle(color: dimText, fontSize: 12),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: panel,
        indicatorColor: accentDim,
        surfaceTintColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: accent);
          }
          return const IconThemeData(color: dimText);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              color: accent,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            );
          }
          return const TextStyle(color: dimText, fontSize: 12);
        }),
      ),
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
  final bridge = AutofillBridge();
  late final nearby = NearbyTransfer(
    permission: integrations.nearbyPermission,
    advertise: integrations.isAndroid ? integrations.nearbyAdvertise : null,
    nativeScan: integrations.isAndroid ? integrations.nearbyScan : null,
    nativeStop: integrations.isAndroid ? integrations.nearbyStop : null,
  );
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
  bool backupRetryBlocked = false;
  Timer? backupRetryTimer;
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
      if (integrations.isAndroid || integrations.isDesktop) integrationError = 'System authentication integration is unavailable. Rebuild the app after installing this update.';
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
      backupError = null;
      lastAutomaticBackup = null;
      lastAutoSnapshot = null;
      backupRetryBlocked = false;
      backupRetryTimer?.cancel();
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
    unawaited(nearby.stop());
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
          builder: (_) => ColoredBox(
            color: ink,
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.asset(
                  'assets/branding/app_icon.png',
                  width: 64,
                  height: 64,
                ),
              ),
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
        lastAutoSnapshot == vault.encryptedBackup ||
        backupRetryBlocked) {
      return;
    }
    final snapshot = vault.encryptedBackup!,
        prefs = vault.preferences,
        id = vault.vaultId!,
        epoch = secretEpoch;
    lastAutoSnapshot = snapshot;
    backupQueue = backupQueue.catchError((_) {}).then((_) async {
      try {
        if (!mounted ||
            epoch != secretEpoch ||
            !vault.unlocked ||
            !vault.preferences.backupEnabled ||
            vault.vaultId != id) {
          return;
        }
        await integrations.writeBackup(prefs.backupDirectory, snapshot, id);
        if (!mounted || epoch != secretEpoch || vault.vaultId != id) return;
        backupRetryBlocked = false;
        backupRetryTimer?.cancel();
        if (mounted) {
          setState(() {
            lastAutomaticBackup = now;
            backupError = null;
          });
        }
      } catch (_) {
        if (!mounted || epoch != secretEpoch || vault.vaultId != id) return;
        if (lastAutoSnapshot == snapshot) lastAutoSnapshot = null;
        backupRetryBlocked = true;
        backupRetryTimer?.cancel();
        backupRetryTimer = Timer(const Duration(seconds: 30), () {
          backupRetryBlocked = false;
          if (mounted) _automaticBackup();
        });
        if (mounted) {
          setState(
            () => backupError = 'Automatic backup failed. Select the folder again or export a backup now.',
          );
        }
      }
    });
  }

  Future<void> _act(
    Future<void> Function() task, {
    String? failureMessage,
  }) async {
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
    } catch (error) {
      debugPrint('Spar Vault: operation failed (${error.runtimeType}).');
      _message(
        failureMessage ?? 'Operation failed. Check permissions, storage and the selected file.',
      );
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.info_outline, color: accent, size: 18),
              const SizedBox(width: 12),
              Expanded(child: Text(text)),
            ],
          ),
        ),
      );
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
    final title = 'Save $name';
    final linuxOpts = await pickerLinuxOptions(title: title);
    ensureDialogForeground(title);
    final result = await FilePicker.saveFile(
      dialogTitle: title,
      fileName: name,
      type: FileType.custom,
      allowedExtensions: extensions,
      mimeType: mime,
      bytes: bytes,
      linuxOptions: linuxOpts,
    );
    // file_picker_web 4.0.1 returns null after requesting a browser download.
    // Its null result is not proof of cancellation or a completed disk save.
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
    final epoch = secretEpoch;
    final key = await pickMasterKey();
    if (key == null) return;
    if (!mounted || epoch != secretEpoch) {
      key.destroy();
      return;
    }
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
        'A system authentication prompt is already open.',
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
      if (result is Uint8List) {
        try {
          result.fillRange(0, result.length, 0);
        } on UnsupportedError {
          /* Read-only platform buffer. */
        }
      }
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
    final received = await _systemAuthentication(
      () => deviceLock
          ? integrations.unlockDevice(vault.vaultId!)
          : integrations.unlockBiometric(vault.vaultId!),
    );
    if (received == null) return;
    // Platform codecs may return a read-only view. Own the buffer we wipe.
    final bytes = Uint8List.fromList(received);
    try {
      received.fillRange(0, received.length, 0);
    } on UnsupportedError {
      // The native root was erased after encoding this platform response.
    }
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

  Future<void> _edit([
    VaultEntry? entry,
    EntryKind initialKind = EntryKind.login,
  ]) async {
    _requireSession();
    final epoch = secretEpoch;
    final value = await _dialog<VaultEntry>(
      EntryEditor(
        entry: entry,
        initialKind: initialKind,
        touch: _touch,
        integrations: integrations,
        copy: (text) => _act(() => _copy(text)),
      ),
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
        copy: (s) => _act(() => _copy(s)),
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
      integrations.isAndroid
          ? 'Set up Android authentication'
          : 'Set up System lock',
      '${deviceSecurity.explanation(deviceLock)} Open system settings now?',
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
      deviceLock ? 'Enable System lock?' : 'Enable fingerprint / face unlock?',
      deviceLock
          ? '${deviceSecurity.systemDescription} Anyone authorized by this device authentication can unlock this vault. It does not recover a deleted vault or replace your backup key.'
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

  Future<void> _sendNearby() async {
    _requireSession();
    if (vault.entries.isEmpty) {
      throw const FormatException('Add an item before sending.');
    }
    final epoch = secretEpoch;
    final name = await integrations.deviceName();
    if (!mounted || epoch != secretEpoch) return;
    await _dialog<void>(
      NearbySendDialog(
        transfer: nearby,
        name: name,
        entries: vault.entries.toList(),
        touch: _touch,
      ),
    );
  }

  Future<void> _receiveNearby() async {
    _requireSession();
    final epoch = secretEpoch;
    final name = await integrations.deviceName();
    if (!mounted || epoch != secretEpoch) return;
    await _dialog<void>(
      NearbyReceiveDialog(
        transfer: nearby,
        name: name,
        touch: _touch,
        import: (entries) async {
          if (epoch != secretEpoch) throw const SessionExpired();
          _requireSession();
          return vault.importEntries(entries);
        },
      ),
    );
  }

  @override
  void dispose() {
    if (foregroundWait?.isCompleted == false) foregroundWait!.complete(false);
    foregroundWait = null;
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_keyEvent);
    idleTimer?.cancel();
    clipboardTimer?.cancel();
    backupRetryTimer?.cancel();
    privacy?.remove();
    privacy?.dispose();
    generated?.destroy();
    staged?.destroy();
    vault.removeListener(_changed);
    vault.dispose();
    unawaited(integrations.cancelBiometric().catchError((_) {}));
    unawaited(integrations.clearAutofill());
    unawaited(bridge.stop());
    unawaited(nearby.stop());
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
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset(
                'assets/branding/app_icon.png',
                width: 24,
                height: 24,
              ),
            ),
            const SizedBox(width: 10),
            const Flexible(
              child: Text('Spar Vault', overflow: TextOverflow.ellipsis),
            ),
            if (vault.unlocked && MediaQuery.sizeOf(context).width > 600) ...[
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: accentDim,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Local • encrypted',
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: accent),
                ),
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
                        if (vault.hasVault)
                          TextButton(
                            onPressed: () => _act(() => _restore()),
                            child: const Text('Recover from encrypted backup'),
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
  Widget _locked() => Container(
    decoration: BoxDecoration(
      gradient: RadialGradient(
        center: const Alignment(0, -0.3),
        radius: 1.2,
        colors: [accent.withAlpha(10), ink],
      ),
    ),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: ListView(
          padding: const EdgeInsets.all(24),
          shrinkWrap: true,
          children: [
            const Center(child: BreathingShield()),
            const SizedBox(height: 20),
            Text(
              generated != null
                  ? 'Keep your secure key safe'
                  : vault.hasVault
                  ? 'Welcome back.'
                  : 'Your passwords. Your device.',
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.3),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            if (generated != null) ...[
              const InfoBox(
                text: 'This random key unlocks your vault. Save it privately. Losing all enabled unlock methods means losing access. The app cannot reset them.',
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accent.withAlpha(40)),
                ),
                child: Text(
                  generated!.display(),
                  style: const TextStyle(
                    fontFamily: 'LocalMono',
                    fontSize: 17,
                    letterSpacing: 1,
                  ),
                ),
              ),
              const SizedBox(height: 8),
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
              const InfoBox(
                text: 'Unlock locally. Neither your credentials nor your vault are sent to a server.',
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
                      : () => _act(
                          _biometricUnlock,
                          failureMessage: 'Fingerprint unlock did not complete. Use your vault password/key, then re-enable fingerprint unlock in Settings.',
                        ),
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Unlock with biometrics'),
                ),
              if (deviceUnlockReady)
                TextButton.icon(
                  onPressed: vault.busy || authenticationPending
                      ? null
                      : () => _act(
                          () => _biometricUnlock(deviceLock: true),
                          failureMessage: 'System unlock did not complete. Use your vault password/key, then re-enable System lock in Settings.',
                        ),
                  icon: const Icon(Icons.lock_outline),
                  label: const Text('Unlock with System lock'),
                ),
              const SizedBox(height: 24),
              TextButton(
                onPressed: vault.busy ? null : () => _act(() => _restore()),
                child: const Text('Restore encrypted backup'),
              ),
            ] else ...[
              const InfoBox(
                text: 'An offline-first vault with no account, no recovery service and no telemetry.',
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _enroll,
                child: const Text('Create a new vault'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _act(() => _restore()),
                child: const Text('Restore encrypted backup'),
              ),
            ],
            if (vault.busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                'Encryption cannot protect an unlocked device from malware. This release needs independent security review before use for high-value secrets.',
                style: TextStyle(fontSize: 12, color: dimText),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _workspace() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (MediaQuery.sizeOf(context).width >= 850)
        Container(
          decoration: const BoxDecoration(
            border: Border(right: BorderSide(color: borderSubtle, width: 1)),
          ),
          child: NavigationRail(
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
        ),
      Expanded(
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: KeyedSubtree(
                  key: ValueKey(section),
                  child: switch (section) {
                    0 => _vaultPage(),
                    1 => _codesPage(),
                    2 => _securityPage(),
                    3 => _backupPage(),
                    _ => _settingsPage(),
                  },
                ),
              ),
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
          Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.3),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(color: dimText, fontSize: 13),
            ),
          ],
          const SizedBox(height: 24),
          ...children,
        ],
      );

  Widget _filterChip(int index, String label, IconData icon, int count) {
    final selected = filter == index;
    return FilterChip(
      selected: selected,
      showCheckmark: false,
      avatar: Icon(icon, size: 16, color: selected ? accent : dimText),
      label: Text('$label ($count)'),
      labelStyle: TextStyle(
        color: selected ? accent : dimText,
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        fontSize: 13,
      ),
      backgroundColor: surface,
      selectedColor: accentDim,
      side: BorderSide(color: selected ? accent.withAlpha(90) : borderSubtle),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      onSelected: (_) => setState(() {
        filter = index;
        page = 0;
      }),
    );
  }

  Widget _vaultEntryCard(VaultEntry e) {
    final isNote = e.kind == EntryKind.note;
    final itemColor = isNote ? noteColor : accent;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          children: [
            Container(width: 4, color: e.favorite ? Colors.amber : itemColor),
            Expanded(
              child: ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: itemColor.withAlpha(24),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isNote ? Icons.notes_outlined : Icons.key_outlined,
                    color: itemColor,
                    size: 20,
                  ),
                ),
                title: Text(
                  e.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14.5,
                  ),
                ),
                subtitle: Row(
                  children: [
                    Flexible(
                      child: Text(
                        e.username.isNotEmpty
                            ? e.username
                            : (isNote ? 'Secure Note' : 'Login'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: dimText),
                      ),
                    ),
                    if (e.totp.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: accentDim,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.timer_outlined, size: 11, color: accent),
                            SizedBox(width: 3),
                            Text(
                              '2FA',
                              style: TextStyle(
                                fontSize: 10,
                                color: accent,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (e.attachments.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: surface,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.attach_file,
                              size: 11,
                              color: dimText,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '${e.attachments.length}',
                              style: const TextStyle(
                                fontSize: 10,
                                color: dimText,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (e.favorite)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(
                          Icons.star_rounded,
                          color: Colors.amber,
                          size: 20,
                        ),
                      ),
                    if (!isNote && e.password.isNotEmpty)
                      IconButton(
                        tooltip: 'Copy password',
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        style: IconButton.styleFrom(foregroundColor: dimText),
                        onPressed: () => _copy(e.password),
                      ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: dimText,
                      size: 20,
                    ),
                  ],
                ),
                onTap: () => _act(() => _details(e)),
              ),
            ),
          ],
        ),
      ),
    );
  }

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

    final totalCount = vault.entries.length;
    final loginCount = vault.entries
        .where((e) => e.kind == EntryKind.login)
        .length;
    final noteCount = vault.entries
        .where((e) => e.kind == EntryKind.note)
        .length;
    final favCount = vault.entries.where((e) => e.favorite).length;

    return _page(
      'Your vault',
      [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: MediaQuery.sizeOf(context).width < 500 ? 240 : 360,
              child: TextField(
                controller: search,
                decoration: InputDecoration(
                  labelText: 'Search items',
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    size: 20,
                    color: dimText,
                  ),
                  suffixIcon: search.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(
                            Icons.clear_rounded,
                            size: 18,
                            color: dimText,
                          ),
                          tooltip: 'Clear search',
                          onPressed: () {
                            search.clear();
                            _touch();
                            setState(() => page = 0);
                          },
                        )
                      : null,
                ),
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) {
                  _touch();
                  setState(() => page = 0);
                },
              ),
            ),
            FilledButton.icon(
              onPressed: vault.busy ? null : () => _act(() => _edit()),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add login'),
            ),
            OutlinedButton.icon(
              onPressed: vault.busy
                  ? null
                  : () => _act(() => _edit(null, EntryKind.note)),
              icon: const Icon(Icons.note_add_outlined),
              label: const Text('Add secure note'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            _filterChip(0, 'All', Icons.apps_rounded, totalCount),
            _filterChip(1, 'Logins', Icons.key_outlined, loginCount),
            _filterChip(2, 'Notes', Icons.notes_outlined, noteCount),
            _filterChip(3, 'Favorites', Icons.star_rounded, favCount),
          ],
        ),
        const SizedBox(height: 16),
        if (entries.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
            decoration: BoxDecoration(
              color: panel,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderSubtle),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: surface,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    vault.entries.isEmpty
                        ? Icons.lock_open_rounded
                        : Icons.search_off_rounded,
                    size: 36,
                    color: accent,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  vault.entries.isEmpty
                      ? 'Your vault is empty'
                      : 'No matching items found',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  vault.entries.isEmpty
                      ? 'Add your first login credentials or secure note to get started.'
                      : 'Try adjusting your search terms or clearing the selected filter.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: dimText, fontSize: 13),
                ),
                const SizedBox(height: 16),
                if (vault.entries.isEmpty)
                  FilledButton.icon(
                    onPressed: vault.busy ? null : () => _act(() => _edit()),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add your first item'),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: () {
                      search.clear();
                      setState(() {
                        filter = 0;
                        page = 0;
                      });
                    },
                    icon: const Icon(Icons.filter_alt_off_rounded, size: 18),
                    label: const Text('Clear search & filters'),
                  ),
              ],
            ),
          )
        else
          ...entries
              .skip(page * size)
              .take(size)
              .map((e) => _vaultEntryCard(e)),
        if (entries.isNotEmpty) ...[
          const SizedBox(height: 16),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: panel,
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: borderSubtle),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Previous page',
                    iconSize: 20,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    onPressed: page > 0 ? () => setState(() => page--) : null,
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Page ${page + 1} / $pages • ${entries.length} items',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Next page',
                    iconSize: 20,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    onPressed: page + 1 < pages
                        ? () => setState(() => page++)
                        : null,
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
      subtitle:
          '${vault.entries.length} ${vault.entries.length == 1 ? 'item' : 'items'} saved in encrypted storage',
    );
  }

  Future<void> _importAuthenticators() async {
    _requireSession();
    final epoch = secretEpoch;
    final accounts = await _dialog<List<AuthenticatorAccount>>(
      AuthenticatorImportDialog(integrations: integrations, touch: _touch),
    );
    if (accounts == null || !mounted || epoch != secretEpoch) return;
    _requireSession();
    final identities = <String>{};
    for (final entry in vault.entries.where((entry) => entry.totp.isNotEmpty)) {
      try {
        identities.add(totpIdentity(entry.totp));
      } on FormatException {
        /* Old invalid entries do not block import. */
      }
    }
    final entries = <VaultEntry>[];
    for (final account in accounts) {
      if (!identities.add(totpIdentity(account.uri))) continue;
      entries.add(
        VaultEntry(
          id: randomId(),
          title: account.title,
          username: account.username,
          totp: account.uri,
          kind: EntryKind.note,
          updatedAt: now.toUtc(),
        ),
      );
    }
    final count = await vault.importEntries(entries);
    _message(
      'Imported $count authenticator accounts. Existing matching codes were kept.',
    );
  }

  Widget _codesPage() {
    final totpEntries = vault.entries.where((e) => e.totp.isNotEmpty).toList();
    return _page(
      'Authenticator codes',
      [
        const InfoBox(
          text: 'Codes are generated offline using each account’s configured period. Your device clock must be correct. Saving TOTP beside its password reduces separation between authentication factors.',
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: vault.busy ? null : () => _act(_importAuthenticators),
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Import from Google Authenticator'),
        ),
        const SizedBox(height: 16),
        if (totpEntries.isEmpty)
          Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: panel,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderSubtle),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: surface,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.timer_off_outlined,
                    size: 36,
                    color: dimText,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'No authenticator codes yet',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Import your Google Authenticator accounts above, or scan a QR in an item’s 2FA tab.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: dimText, fontSize: 13),
                ),
              ],
            ),
          )
        else
          ...totpEntries.map((e) => OtpCard(entry: e, copy: _copy)),
      ],
      subtitle:
          '${totpEntries.length} ${totpEntries.length == 1 ? 'code' : 'codes'} active',
    );
  }

  Widget _securityPage() {
    final h = HealthReport(vault.entries);
    final totalLogins = vault.entries
        .where((e) => e.kind == EntryKind.login)
        .length;
    final totalIssues = h.short.length + h.reused.length + h.wordOnly.length;
    final isHealthy = totalIssues == 0 && totalLogins > 0;

    Widget group({
      required String title,
      required List<VaultEntry> entries,
      required IconData icon,
      required Color color,
      required String emptyMessage,
    }) => SectionCard(
      title: title,
      icon: icon,
      accentColor: color,
      children: [
        if (entries.isEmpty)
          Row(
            children: [
              const Icon(
                Icons.check_circle_outline_rounded,
                color: successColor,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  emptyMessage,
                  style: const TextStyle(color: successColor, fontSize: 13),
                ),
              ),
            ],
          )
        else
          ...entries.map(
            (e) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              color: surface,
              child: ListTile(
                dense: true,
                leading: Icon(
                  Icons.warning_amber_rounded,
                  color: color,
                  size: 20,
                ),
                title: Text(
                  e.title,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                subtitle: Text(
                  e.username.isNotEmpty ? e.username : 'No username',
                  style: const TextStyle(color: dimText, fontSize: 12),
                ),
                trailing: const Icon(
                  Icons.edit_outlined,
                  size: 18,
                  color: dimText,
                ),
                onTap: () => _act(() => _edit(e)),
              ),
            ),
          ),
      ],
    );

    final backupStatusText =
        backupError ??
        (lastAutomaticBackup != null
            ? 'Automatic encrypted copy saved this session.'
            : vault.preferences.lastBackupAt == null
            ? 'No manual export recorded. Export and verify a backup.'
            : 'Last manual export: ${vault.preferences.lastBackupAt!.toLocal()}');
    final isBackupOverdue =
        vault.preferences.lastBackupAt == null ||
        now.difference(vault.preferences.lastBackupAt!).inDays >=
            vault.preferences.backupReminderDays;

    return _page(
      'Security overview',
      [
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: panel,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isHealthy
                  ? successColor.withAlpha(60)
                  : (totalIssues > 0
                        ? warningColor.withAlpha(60)
                        : borderSubtle),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color:
                      (isHealthy
                              ? successColor
                              : (totalIssues > 0 ? warningColor : accent))
                          .withAlpha(25),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isHealthy
                      ? Icons.verified_user_rounded
                      : (totalIssues > 0
                            ? Icons.security_update_warning_rounded
                            : Icons.shield_outlined),
                  size: 32,
                  color: isHealthy
                      ? successColor
                      : (totalIssues > 0 ? warningColor : accent),
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isHealthy
                          ? 'All logins meet security checks'
                          : totalLogins == 0
                          ? 'No logins evaluated'
                          : '$totalIssues security ${totalIssues == 1 ? 'alert' : 'alerts'} detected',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$totalLogins total accounts • ${h.short.length} short • ${h.reused.length} reused • ${h.wordOnly.length} letters-only',
                      style: const TextStyle(color: dimText, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const InfoBox(
          text: 'These checks run entirely on this device. They are limited heuristics, not a breach check or a guarantee of password strength. Use a unique, long password for each account.',
        ),
        const SizedBox(height: 16),
        group(
          title: 'Short passwords (${h.short.length})',
          entries: h.short,
          icon: Icons.lock_clock,
          color: dangerColor,
          emptyMessage: 'No short passwords found (all >= 16 chars).',
        ),
        group(
          title: 'Reused passwords (${h.reused.length})',
          entries: h.reused,
          icon: Icons.repeat_rounded,
          color: warningColor,
          emptyMessage: 'No reused passwords found.',
        ),
        group(
          title: 'Letters-only passwords (${h.wordOnly.length})',
          entries: h.wordOnly,
          icon: Icons.text_fields_rounded,
          color: warningColor,
          emptyMessage: 'No letters-only passwords found.',
        ),
        SectionCard(
          title: 'Backup status',
          icon: Icons.backup_rounded,
          accentColor: isBackupOverdue ? warningColor : successColor,
          children: [
            Row(
              children: [
                Icon(
                  isBackupOverdue
                      ? Icons.warning_amber_rounded
                      : Icons.check_circle_outline_rounded,
                  color: isBackupOverdue ? warningColor : successColor,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    backupStatusText,
                    style: TextStyle(
                      color: isBackupOverdue ? warningColor : null,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
            if (isBackupOverdue) ...[
              const SizedBox(height: 10),
              const Text(
                'Backup reminder: export an independent copy and verify it.',
                style: TextStyle(fontSize: 12, color: dimText),
              ),
            ],
          ],
        ),
      ],
      subtitle:
          'Offline heuristic checks for password health and backup freshness',
    );
  }

  Widget _backupPage() => _page('Backups & transfers', [
    SectionCard(
      title: 'Encrypted backups',
      icon: Icons.shield_outlined,
      accentColor: accent,
      children: [
        const InfoBox(
          text: 'A backup is the .svlt file containing your encrypted entries. A master-key .txt file alone has no passwords to restore.',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              onPressed: () => _act(_exportBackup),
              icon: const Icon(Icons.download_rounded),
              label: const Text('Export backup'),
            ),
            OutlinedButton.icon(
              onPressed: () => _act(() => _restore(verifyOnly: true)),
              icon: const Icon(Icons.verified_outlined),
              label: const Text('Verify backup'),
            ),
            OutlinedButton.icon(
              onPressed: () => _act(() => _restore()),
              icon: const Icon(Icons.restore_page_outlined),
              label: const Text('Restore backup'),
            ),
          ],
        ),
      ],
    ),
    SectionCard(
      title: 'Automatic encrypted copies',
      icon: Icons.auto_mode_rounded,
      accentColor: successColor,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: vault.preferences.backupEnabled
                  ? successColor.withAlpha(50)
                  : borderSubtle,
            ),
          ),
          child: Row(
            children: [
              Icon(
                vault.preferences.backupEnabled
                    ? Icons.check_circle_rounded
                    : Icons.pause_circle_outline_rounded,
                color: vault.preferences.backupEnabled ? successColor : dimText,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  vault.preferences.backupEnabled
                      ? 'Automatic backups enabled • retains the latest 5 encrypted copies for this vault.'
                      : 'Automatic backups disabled. Select a private folder to enable.',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        if (backupError != null) ...[
          const SizedBox(height: 10),
          Text(
            backupError!,
            style: const TextStyle(color: warningColor, fontSize: 13),
          ),
        ],
        if (vault.preferences.backupDirectory == 'browser-storage') ...[
          const SizedBox(height: 10),
          const InfoBox(
            text: 'Browser copies share the same storage failure risk as the main database. Export independent backups periodically.',
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => _act(_localBackupCopies),
            icon: const Icon(Icons.folder_open_rounded, size: 18),
            label: const Text('Review browser backup copies'),
          ),
        ],
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: () => _act(_chooseAutomaticBackup),
              icon: const Icon(Icons.folder_rounded, size: 18),
              label: const Text('Choose backup folder'),
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
        const SizedBox(height: 14),
        DropdownButtonFormField<int>(
          initialValue: vault.preferences.backupReminderDays,
          decoration: const InputDecoration(
            labelText: 'Independent backup reminder',
            prefixIcon: Icon(
              Icons.notifications_active_outlined,
              size: 20,
              color: dimText,
            ),
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
      title: 'Nearby device transfer',
      icon: Icons.sync_alt_rounded,
      accentColor: noteColor,
      children: [
        InfoBox(
          text: nearby.available
              ? 'Send selected items or all items directly to another device running Spar Vault. Both devices must be unlocked and on the same Wi-Fi or hotspot. Open Receive on the other device, then choose it from Send.'
              : 'Nearby transfer requires the native app. Use Export and Restore encrypted backup in the browser.',
        ),
        if (nearby.available) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: () => _act(_sendNearby),
                icon: const Icon(Icons.send_outlined),
                label: const Text('Send'),
              ),
              OutlinedButton.icon(
                onPressed: () => _act(_receiveNearby),
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('Receive'),
              ),
            ],
          ),
        ],
      ],
    ),
  ], subtitle: 'Manage encrypted archives and device synchronization');

  Widget _settingsPage() => _page('Settings', [
    SectionCard(
      title: 'Session & layout',
      icon: Icons.timer_outlined,
      accentColor: accent,
      children: [
        DropdownButtonFormField<int>(
          key: ValueKey('idle-${vault.preferences.idleMinutes}'),
          initialValue: vault.preferences.idleMinutes,
          decoration: const InputDecoration(
            labelText: 'Lock after inactivity',
            prefixIcon: Icon(
              Icons.hourglass_empty_rounded,
              size: 20,
              color: dimText,
            ),
          ),
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
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Lock immediately when minimized'),
          subtitle: const Text(
            'Off: switching apps keeps the session active until its inactivity deadline.',
            style: TextStyle(fontSize: 12, color: dimText),
          ),
          value: vault.preferences.lockOnBackground,
          onChanged: (v) => _act(
            () => vault.updatePreferences(
              vault.preferences.copyWith(lockOnBackground: v),
            ),
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          initialValue: vault.preferences.pageSize,
          decoration: const InputDecoration(
            labelText: 'Items per page',
            prefixIcon: Icon(
              Icons.format_list_numbered_rounded,
              size: 20,
              color: dimText,
            ),
          ),
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
      icon: Icons.key_rounded,
      accentColor: accent,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: accentDim,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  vault.passwordEnabled
                      ? Icons.password_rounded
                      : Icons.key_rounded,
                  color: accent,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      vault.passwordEnabled
                          ? 'Password & Secure Key active'
                          : 'Secure Key only',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'The random secure key always remains an unlock method. No server reset exists.',
                      style: TextStyle(color: dimText, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonal(
              onPressed: () => _act(_passwordSettings),
              child: Text(
                vault.passwordEnabled
                    ? 'Change password'
                    : 'Enable password unlock',
              ),
            ),
            if (vault.passwordEnabled)
              OutlinedButton(
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
            OutlinedButton(
              onPressed: () => _act(_rotate),
              child: const Text('Rotate secure key'),
            ),
          ],
        ),
        if (integrations.isAndroid || integrations.isDesktop) ...[
          const SizedBox(height: 18),
          const Divider(),
          const SizedBox(height: 12),
          Text(
            deviceSecurity.explanation(true),
            style: const TextStyle(fontSize: 13, color: dimText),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (integrations.isAndroid)
                FilledButton.tonalIcon(
                  onPressed: authenticationPending
                      ? null
                      : () => _act(_enableBiometrics),
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Enable biometric unlock'),
                ),
              if (biometricReady)
                OutlinedButton(
                  onPressed: authenticationPending
                      ? null
                      : () => _act(() async {
                          await integrations.clearBiometric();
                          await _biometricState();
                          setState(() {});
                        }),
                  child: const Text('Remove biometric unlock'),
                ),
              FilledButton.tonalIcon(
                onPressed: authenticationPending
                    ? null
                    : () => _act(() => _enableBiometrics(deviceLock: true)),
                icon: const Icon(Icons.lock_outline),
                label: Text(
                  deviceUnlockReady
                      ? 'Replace System lock binding'
                      : 'Enable System lock',
                ),
              ),
              if (deviceUnlockReady)
                OutlinedButton(
                  onPressed: authenticationPending
                      ? null
                      : () => _act(() async {
                          await integrations.clearDeviceUnlock();
                          await _refreshDeviceSecurity();
                        }),
                  child: const Text('Remove System lock'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            deviceSecurity.systemDescription,
            style: const TextStyle(fontSize: 12, color: dimText),
          ),
          if (integrationError != null) ...[
            const SizedBox(height: 6),
            Text(
              integrationError!,
              style: const TextStyle(color: dangerColor, fontSize: 13),
            ),
          ],
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => _act(_refreshDeviceSecurity),
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Refresh authentication status'),
          ),
        ],
      ],
    ),
    SectionCard(
      title: 'Autofill integration',
      icon: Icons.extension_outlined,
      accentColor: noteColor,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: vault.preferences.autofillEnabled,
          title: const Text('Allow confirmed autofill while unlocked'),
          subtitle: const Text(
            'Never fills while the vault is locked. Each request requires explicit approval.',
            style: TextStyle(fontSize: 12, color: dimText),
          ),
          onChanged: (v) => _act(() => _setAutofill(v)),
        ),
        const SizedBox(height: 12),
        if (integrations.isAndroid) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: deviceSecurity.autofillSelected
                    ? successColor.withAlpha(50)
                    : warningColor.withAlpha(50),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  deviceSecurity.autofillSelected
                      ? Icons.check_circle_rounded
                      : Icons.info_outline_rounded,
                  color: deviceSecurity.autofillSelected
                      ? successColor
                      : warningColor,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    deviceSecurity.autofillSelected
                        ? 'Android service: Spar Vault selected'
                        : 'Android service: Spar Vault not selected — setup required',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          if (vault.preferences.autofillEnabled &&
              !deviceSecurity.autofillSelected) ...[
            const SizedBox(height: 8),
            const Text(
              'Autofill is paused. Tap the settings button below to enable Spar Vault again.',
              style: TextStyle(color: warningColor, fontSize: 13),
            ),
          ],
          const SizedBox(height: 8),
          const InfoBox(
            text: 'Bind native apps to their installed signing certificates in each item. Android website autofill is refused because its form API omits the port. Use native app bindings; desktop/web website fill uses the bundled extension.',
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () => _act(_autofillSettings),
            child: const Text('Select Spar Vault in Android autofill settings'),
          ),
        ],
        if (!integrations.isAndroid) ...[
          const InfoBox(
            text: 'Install the bundled Chrome/Edge extension. Configure its 32-letter extension ID here. Native desktop also needs the bundled native messaging host; web mode needs this vault tab open.',
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.settings_outlined, size: 18),
            label: const Text('Configure browser extension ID'),
            onPressed: () => _act(() async {
              final c = TextEditingController(
                text: vault.preferences.desktopExtensionId,
              );
              try {
                final ok = await _dialog<bool>(
                  AlertDialog(
                    title: dialogTitle(
                      'Browser extension ID',
                      Icons.extension_outlined,
                    ),
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
          ),
          if (bridge.statePath != null) ...[
            const SizedBox(height: 10),
            SelectableText(
              'Native host state file: ${bridge.statePath}',
              style: const TextStyle(fontSize: 12, color: dimText),
            ),
          ],
        ],
      ],
    ),
    const SizedBox(height: 12),
    Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.asset(
              'assets/branding/app_icon.png',
              width: 48,
              height: 48,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Spar Vault 0.2.6+9 • No telemetry • No provider recovery\nAttachments, old passwords, codes and settings are encrypted inside the vault. Managed runtimes cannot guarantee erasure of immutable strings or copies made by the OS.',
            style: TextStyle(fontSize: 12, color: dimText, height: 1.5),
            textAlign: TextAlign.center,
          ),
          TextButton(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'Spar Vault',
              applicationVersion: '0.2.6+9',
            ),
            child: const Text('Open-source licenses'),
          ),
        ],
      ),
    ),
  ], subtitle: 'Application preferences, unlock credentials, and integrations');
}
