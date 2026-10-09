import 'dart:js_interop';
import 'dart:convert';
import 'dart:typed_data';

import 'package:vault_core/vault_core.dart';

import 'device_security.dart';

@JS('sparBackupChoose')
external JSPromise<JSString> _choose();
@JS('sparBackupWrite')
external JSPromise<JSAny?> _write(
  JSString directory,
  JSString snapshot,
  JSString id,
);

@JS('sparBackupList')
external JSPromise<JSString> _list(JSString id);
@JS('sparBackupRead')
external JSPromise<JSString> _read(JSString name);

class PlatformIntegrations {
  Future<List<String>> backupCopies(String id) async => List<String>.from(
    jsonDecode((await _list(id.toJS).toDart).toDart) as List,
  );
  Future<String> readBackupCopy(String name) async =>
      (await _read(name.toJS).toDart).toDart;
  bool get isAndroid => false;
  bool get isDesktop => false;
  Future<DeviceSecurityStatus> deviceSecurityStatus() async =>
      const DeviceSecurityStatus();
  Future<bool> requestAuthenticationSetup(bool deviceLock) async => false;
  Future<String> deviceName() async => 'This browser';
  Future<bool> deviceUnlockEnabled(String id) async => false;
  Future<void> enableDeviceUnlock(String id, Uint8List key) async =>
      throw const FormatException(
        'Phone screen lock is available on Android only.',
      );
  Future<Uint8List?> unlockDevice(String id) async => null;
  Future<void> clearDeviceUnlock() async {}
  Future<bool> biometricAvailable() async => false;
  Future<bool> biometricEnabled(String id) async => false;
  Future<void> enableBiometric(String id, Uint8List key) async =>
      throw const FormatException(
        'Hardware-bound quick unlock is currently supported on Android only.',
      );
  Future<Uint8List?> unlockBiometric(String id) async => null;
  Future<void> cancelBiometric() async {}
  Future<void> clearBiometric() async {}
  Future<List<String>> certificates(String package) async => [];
  Future<bool> requestAutofill() async => false;
  Future<void> updateAutofill(
    List<VaultEntry> entries,
    VaultPreferences prefs,
    DateTime deadline,
  ) async {}
  Future<void> clearAutofill() async {}
  Future<String?> chooseBackupDirectory() async =>
      (await _choose().toDart).toDart;
  Future<void> writeBackup(String directory, String snapshot, String id) async {
    VaultBundle.parse(snapshot);
    checkId(id);
    await _write(directory.toJS, snapshot.toJS, id.toJS).toDart;
  }
}
