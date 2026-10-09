import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vault_core/vault_core.dart';

VaultStore createLocalStore() => NativeVaultStore();

class NativeVaultStore implements VaultStore {
  NativeVaultStore({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _supportDirectory;
  static final _queues = <String, Future<void>>{};

  Future<Directory> _directory() async {
    final support = await _supportDirectory();
    final dir = Directory(
      '${support.path}${Platform.pathSeparator}sable_vault',
    );
    await dir.create(recursive: true);
    await _restrict(dir.path, '700');
    if (Platform.isIOS) {
      await const MethodChannel('sable/privacy')
          .invokeMethod<void>('protectVaultDirectory', {'path': dir.path});
    }
    return dir;
  }

  Future<void> _restrict(String path, String mode) async {
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('chmod', [mode, path]);
      if (result.exitCode != 0) {
        throw const FileSystemException('Cannot restrict vault permissions.');
      }
    }
    // Android/iOS use the OS app sandbox. Windows uses the user's AppData ACL.
  }

  Future<String?> _read(File file) async {
    if (!await file.exists()) return null;
    if (await file.length() > maxEnvelopeBytes) {
      throw const FormatException('Stored vault exceeds the size limit.');
    }
    return file.readAsString(encoding: utf8);
  }

  Future<T> _locked<T>(Future<T> Function(File) action) async {
    final dir = await _directory();
    // POSIX advisory locks protect separate processes. This queue also protects
    // separate store instances in the same Dart isolate.
    final previous = _queues[dir.path] ?? Future<void>.value();
    final completion = Completer<void>();
    _queues[dir.path] = completion.future;
    await previous;
    final guard = File('${dir.path}${Platform.pathSeparator}vault.lock');
    RandomAccessFile? handle;
    var locked = false;
    try {
      handle = await guard.open(mode: FileMode.append);
      await _restrict(guard.path, '600');
      await handle.lock(FileLock.blockingExclusive);
      locked = true;
      return await action(
        File('${dir.path}${Platform.pathSeparator}vault.svlt'),
      );
    } finally {
      try {
        if (locked) await handle?.unlock();
        await handle?.close();
      } finally {
        completion.complete();
        if (identical(_queues[dir.path], completion.future)) {
          _queues.remove(dir.path);
        }
      }
    }
  }

  @override
  Future<String?> read() => _locked(_read);

  @override
  Future<void> write(String encrypted, {required String? expected}) =>
      _locked((target) async {
        VaultBundle.parse(encrypted);
        if (await _read(target) != expected) {
          throw const ConcurrentVaultChange();
        }
        final temp = File('${target.path}.${randomId()}.tmp');
        try {
          await temp.create(exclusive: true);
          await _restrict(temp.path, '600');
          await temp.writeAsString(encrypted, encoding: utf8, flush: true);
          await temp.rename(target.path);
        } finally {
          if (await temp.exists()) await temp.delete();
        }
      });
}
