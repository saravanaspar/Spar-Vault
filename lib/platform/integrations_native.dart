import 'dart:io';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:vault_core/vault_core.dart';

import '../features/files.dart';
import 'device_security.dart';
import 'system_lock_native.dart';
import 'installed_app.dart';
import 'picker_options.dart';
import 'key_file_io.dart';
import 'key_file_result.dart';

class PlatformIntegrations {
  final _systemLock = DesktopSystemLock();
  Future<String?> chooseKeyDirectory() async {
    if (isAndroid) return channel.invokeMethod<String>('chooseKeyDirectory');
    const title = 'Choose private secure-key folder';
    final linuxOpts = await pickerLinuxOptions(title: title);
    ensureDialogForeground(title);
    return FilePicker.getDirectoryPath(
      dialogTitle: title,
      linuxOptions: linuxOpts,
    );
  }

  Future<KeyFileSaveResult?> saveMasterKey(
    Uint8List bytes, {
    required bool Function() canSave,
  }) async {
    final key = MasterKey.parse(utf8.decode(bytes));
    key.destroy();
    if (!canSave()) return null;
    final directory = await chooseKeyDirectory();
    if (directory == null || !canSave()) return null;
    if (isAndroid) {
      await channel.invokeMethod<void>('writeMasterKey', {
        'directory': directory,
        'bytes': bytes,
      });
    } else {
      await writeMasterKeyFile(directory, bytes);
    }
    return KeyFileSaveResult.saved;
  }

  Future<void> nearbyPermission() async {
    if (isAndroid &&
        await channel.invokeMethod<bool>('localNetworkPermission') != true) {
      throw const FormatException(
        'Allow local network access to find and transfer to nearby devices.',
      );
    }
  }

  Future<void> nearbyAdvertise(Map<String, Object> metadata) async {
    await channel.invokeMethod<void>('nearbyAdvertise', metadata);
  }

  Future<List<Map>> nearbyScan() async =>
      (await channel.invokeListMethod<dynamic>('nearbyScan') ?? []).cast<Map>();
  Future<void> nearbyStop() async {
    await channel.invokeMethod<void>('nearbyStop');
  }

  Future<List<InstalledApp>> installedApps() async => !isAndroid
      ? []
      : (await channel.invokeListMethod<dynamic>('installedApps') ?? [])
            .map((value) => InstalledApp.fromMap(value as Map))
            .toList();
  Future<List<String>?> scanTotpQr({bool image = false}) async {
    if (!isAndroid) {
      throw const FormatException(
        'Camera QR scanning currently requires Android. Paste an authenticator URI instead.',
      );
    }
    final result = await channel.invokeListMethod<String>(
      image ? 'readTotpQrImage' : 'scanTotpQr',
    );
    return result;
  }

  Future<List<String>> backupCopies(String id) async => [];
  Future<String> readBackupCopy(String name) async =>
      throw const FormatException('Select the backup using the file picker.');
  static const channel = MethodChannel('spar/integrations');
  bool get isAndroid => Platform.isAndroid;
  bool get isDesktop =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;
  Future<DeviceSecurityStatus> deviceSecurityStatus() async => isAndroid
      ? DeviceSecurityStatus.fromMap(
          await channel.invokeMapMethod<dynamic, dynamic>(
            'deviceSecurityStatus',
          ),
        )
      : isDesktop
      ? await _systemLock.status()
      : const DeviceSecurityStatus();
  Future<bool> requestAuthenticationSetup(bool deviceLock) async => isAndroid
      ? await channel.invokeMethod<bool>('requestAuthenticationSetup', {
              'deviceLock': deviceLock,
            }) ??
            false
      : isDesktop && deviceLock
      ? await _systemLock.setup()
      : false;
  Future<String> deviceName() async => isAndroid
      ? await channel.invokeMethod<String>('deviceName') ?? 'Android phone'
      : Platform.localHostname;
  Future<bool> deviceUnlockEnabled(String id) async => isAndroid
      ? await channel.invokeMethod<bool>('deviceUnlockEnabled', {
              'vaultId': id,
            }) ??
            false
      : isDesktop
      ? await _systemLock.enabled(id)
      : false;
  Future<void> enableDeviceUnlock(String id, Uint8List key) async {
    if (isDesktop) return _systemLock.enable(id, key);
    if (!isAndroid) {
      throw const FormatException(
        'System lock is unavailable on this platform.',
      );
    }
    await channel.invokeMethod<void>('enableDeviceUnlock', {
      'vaultId': id,
      'key': key,
    });
  }

  Future<Uint8List?> unlockDevice(String id) async => isAndroid
      ? await channel.invokeMethod<Uint8List>('unlockDevice', {'vaultId': id})
      : isDesktop
      ? await _systemLock.unlock(id)
      : null;
  Future<void> clearDeviceUnlock() async {
    if (isDesktop) return _systemLock.clear();
    if (isAndroid) await channel.invokeMethod<void>('clearDeviceUnlock');
  }

  Future<bool> biometricAvailable() async => isAndroid
      ? (await channel.invokeMethod<bool>('biometricAvailable') ?? false)
      : false;
  Future<bool> biometricEnabled(String id) async => isAndroid
      ? (await channel.invokeMethod<bool>('biometricEnabled', {
              'vaultId': id,
            }) ??
            false)
      : false;
  Future<void> enableBiometric(String id, Uint8List key) async {
    if (!isAndroid) {
      throw const FormatException(
        'Hardware-bound biometrics are available on supported Android devices.',
      );
    }
    await channel.invokeMethod<void>('enableBiometric', {
      'vaultId': id,
      'key': key,
    });
  }

  Future<Uint8List?> unlockBiometric(String id) async => isAndroid
      ? await channel.invokeMethod<Uint8List>('unlockBiometric', {
          'vaultId': id,
        })
      : null;
  Future<void> cancelBiometric() async {
    if (isDesktop) await _systemLock.cancel();
    if (isAndroid) await channel.invokeMethod<void>('cancelBiometric');
  }

  Future<void> clearBiometric() async {
    if (isAndroid) await channel.invokeMethod<void>('clearBiometric');
  }

  Future<List<String>> certificates(String package) async => isAndroid
      ? List<String>.from(
          await channel.invokeMethod<List<dynamic>>('packageCertificates', {
                'package': package,
              }) ??
              [],
        )
      : [];
  Future<bool> requestAutofill() async => isAndroid
      ? await channel.invokeMethod<bool>('requestAutofill') ?? false
      : false;

  Future<void> updateAutofill(
    List<VaultEntry> entries,
    VaultPreferences prefs,
    DateTime deadline,
  ) async {
    if (!isAndroid) return;
    await channel.invokeMethod<void>('updateAutofill', {
      'expiresAt': deadline.millisecondsSinceEpoch,
      'chromeCertificates': prefs.chromeCertificates,
      'entries': prefs.autofillEnabled
          ? entries
                .where(
                  (e) => e.kind == EntryKind.login && e.password.isNotEmpty,
                )
                .map(
                  (e) => {
                    'id': e.id,
                    'title': e.title,
                    'username': e.username,
                    'password': e.password,
                    'origin': webOrigin(e.url) ?? '',
                    'package': e.androidPackage,
                    'certificates': e.androidCertificates,
                  },
                )
                .toList()
          : [],
    });
  }

  Future<void> clearAutofill() async {
    if (isAndroid) await channel.invokeMethod<void>('clearAutofill');
  }

  Future<String?> chooseBackupDirectory() async {
    if (isAndroid) {
      return await channel.invokeMethod<String>('chooseBackupDirectory');
    }
    const title = 'Choose private encrypted-backup folder';
    final linuxOpts = await pickerLinuxOptions(title: title);
    ensureDialogForeground(title);
    return FilePicker.getDirectoryPath(
      dialogTitle: title,
      linuxOptions: linuxOpts,
    );
  }

  Future<void> writeBackup(String directory, String snapshot, String id) async {
    VaultBundle.parse(snapshot);
    checkId(id);
    if (isAndroid) {
      await channel.invokeMethod<void>('writeBackup', {
        'directory': directory,
        'snapshot': snapshot,
        'vaultId': id,
      });
      return;
    }
    final dir = Directory(directory);
    if (!await dir.exists()) {
      throw const FileSystemException('Backup folder unavailable.');
    }
    final name =
        'spar-auto-$id-${DateTime.now().toUtc().microsecondsSinceEpoch}-${randomId().substring(0, 8)}.svlt';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.create(exclusive: true);
    if (Platform.isLinux || Platform.isMacOS) {
      final r = await Process.run('chmod', ['600', file.path]);
      if (r.exitCode != 0) {
        await file.delete();
        throw const FileSystemException('Cannot restrict backup permissions.');
      }
    }
    try {
      await file.writeAsString(snapshot, flush: true);
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
    final pattern = RegExp('^spar-auto-$id-[0-9]+-[a-f0-9]{8}\\.svlt\$');
    final files = await dir
        .list(followLinks: false)
        .where(
          (e) =>
              e is File &&
              pattern.hasMatch(e.path.split(Platform.pathSeparator).last),
        )
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    for (final old in files.skip(5)) {
      await old.delete();
    }
  }
}
