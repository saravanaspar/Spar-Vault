import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vault_core/vault_core.dart';

import 'device_security.dart';

class DesktopSystemLock {
  DesktopSystemLock({this.supportDirectory, this.systemProvider});
  final Future<Directory> Function()? supportDirectory;
  final String? systemProvider;
  static const channel = MethodChannel('spar/system_lock');
  int _epoch = 0;
  Completer<void>? _pending;
  String get provider =>
      systemProvider ??
      (Platform.isWindows
          ? 'windows'
          : Platform.isMacOS
          ? 'macos'
          : 'fido2');

  Future<DeviceSecurityStatus> status() async => DeviceSecurityStatus.fromMap(
    await channel.invokeMapMethod<dynamic, dynamic>('status'),
  );
  Future<bool> setup() async =>
      await channel.invokeMethod<bool>('setup') ?? false;
  Future<File> _file() async {
    final base = await (supportDirectory ?? getApplicationSupportDirectory)();
    final dir = Directory('${base.path}/sable_vault');
    if (await FileSystemEntity.type(dir.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException(
        'System lock folder cannot be a symbolic link.',
      );
    }
    await dir.create(recursive: true);
    if (!Platform.isWindows) await _private(dir.path, '700');
    final file = File('${dir.path}/system-lock.json');
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException(
        'System lock binding cannot be a symbolic link.',
      );
    }
    return file;
  }

  Future<void> _private(String path, String mode) async {
    if ((await Process.run('chmod', [mode, path])).exitCode != 0) {
      throw const FileSystemException(
        'Cannot restrict System lock permissions.',
      );
    }
  }

  Future<Map<String, dynamic>?> _read(String id) async {
    checkId(id);
    final file = await _file();
    if (!await file.exists()) return null;
    if (await file.length() > 16384) {
      throw const FormatException('Invalid System lock binding.');
    }
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['provider'] != provider) {
      throw const FormatException('Invalid System lock binding.');
    }
    if (value['vaultId'] != id) return null;
    if (provider == 'windows') {
      if (value['keyName'] is! String ||
          (value['keyName'] as String).length > 512) {
        throw const FormatException('Invalid System lock binding.');
      }
      systemBytes(value['ciphertext'], 256);
    } else {
      systemBytes(value['publicKey'], 64);
      systemBytes(value['salt'], 32);
      systemBytes(value['nonce'], 12);
      systemBytes(value['ciphertext'], 32);
      systemBytes(value['tag'], 16);
      final credential = value['credential'];
      if (credential is! String || credential.length > 2732) {
        throw const FormatException('Invalid System lock binding.');
      }
      final bytes = base64Decode(credential);
      if (bytes.isEmpty ||
          bytes.length > 2048 ||
          base64Encode(bytes) != credential) {
        throw const FormatException('Invalid System lock binding.');
      }
    }
    return value;
  }

  Future<bool> enabled(String id) async => provider == 'macos'
      ? await channel.invokeMethod<bool>('enabled', {'vaultId': id}) ?? false
      : await _read(id) != null;
  Uint8List _owned(Uint8List original) {
    final copy = Uint8List.fromList(original);
    try {
      original.fillRange(0, original.length, 0);
    } on UnsupportedError {
      /* Platform-owned read-only buffer. */
    }
    return copy;
  }

  Future<T> _operation<T>(Future<T> Function(int epoch) work) async {
    if (_pending != null) {
      throw const FormatException('System authentication is already running.');
    }
    final done = Completer<void>();
    _pending = done;
    final epoch = _epoch;
    try {
      final result = await work(epoch);
      if (epoch != _epoch) {
        if (result is Uint8List) result.fillRange(0, result.length, 0);
        throw const FormatException('System authentication was cancelled.');
      }
      return result;
    } finally {
      _pending = null;
      done.complete();
    }
  }

  Future<void> enable(String id, Uint8List root) => _operation((epoch) async {
    checkId(id);
    if (root.length != 32) {
      throw const FormatException('Invalid System lock key.');
    }
    if (provider == 'macos') {
      await channel.invokeMethod<void>('enable', {'vaultId': id, 'key': root});
      return;
    }
    final oldFile = await _file();
    Map? old;
    if (await oldFile.exists() && await oldFile.length() <= 16384) {
      old = jsonDecode(await oldFile.readAsString()) as Map;
    }
    final result = Map<String, dynamic>.from(
      await channel.invokeMapMethod<String, dynamic>('enable', {
            'vaultId': id,
            'key': provider == 'windows' ? root : null,
          }) ??
          {},
    );
    File? temp;
    bool committed = false;
    try {
      if (provider == 'fido2') {
        final secret = _owned(result.remove('secret') as Uint8List);
        try {
          result.addAll(await wrapSystemKey(id, root, secret));
        } finally {
          secret.fillRange(0, secret.length, 0);
        }
      }
      result.addAll({'version': 1, 'provider': provider, 'vaultId': id});
      if (epoch != _epoch) {
        throw const FormatException('System authentication was cancelled.');
      }
      temp = File('${oldFile.path}.${randomId()}.tmp');
      await temp.create(exclusive: true);
      if (!Platform.isWindows) await _private(temp.path, '600');
      await temp.writeAsString(jsonEncode(result), flush: true);
      if (epoch != _epoch) {
        throw const FormatException('System authentication was cancelled.');
      }
      await temp.rename(oldFile.path);
      committed = true;
      if (provider == 'windows' && old?['keyName'] != null) {
        await channel.invokeMethod<void>('delete', {
          'keyName': old!['keyName'],
          'vaultId': old['vaultId'],
        });
      }
    } finally {
      if (temp != null && await temp.exists()) await temp.delete();
      if (!committed && provider == 'windows' && result['keyName'] != null) {
        await channel.invokeMethod<void>('delete', {
          'keyName': result['keyName'],
          'vaultId': id,
        });
      }
    }
  });
  Future<Uint8List?> unlock(String id) => _operation((epoch) async {
    checkId(id);
    if (provider == 'macos') {
      final result = await channel.invokeMethod<Uint8List>('unlock', {
        'vaultId': id,
      });
      if (result == null) return null;
      final bytes = _owned(result);
      if (bytes.length != 32) {
        bytes.fillRange(0, bytes.length, 0);
        throw const FormatException('Invalid System lock key.');
      }
      return bytes;
    }
    final binding = await _read(id);
    if (binding == null) return null;
    final result = await channel.invokeMethod<Uint8List>('unlock', binding);
    if (result == null) return null;
    final bytes = _owned(result);
    if (bytes.length != 32) {
      bytes.fillRange(0, bytes.length, 0);
      throw const FormatException('Invalid System lock key.');
    }
    if (provider == 'windows') return bytes;
    try {
      return await unwrapSystemKey(id, binding, bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  });
  Future<void> cancel() async {
    _epoch++;
    await channel.invokeMethod<void>('cancel');
  }

  Future<void> clear() async {
    await cancel();
    await _pending?.future;
    if (provider == 'macos') {
      await channel.invokeMethod<void>('clear');
      return;
    }
    final file = await _file();
    if (!await file.exists()) return;
    if (provider == 'windows' && await file.length() <= 16384) {
      final value = jsonDecode(await file.readAsString()) as Map;
      await channel.invokeMethod<void>('delete', {
        'keyName': value['keyName'],
        'vaultId': value['vaultId'],
      });
    }
    await file.delete();
  }
}
