import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_core/vault_core.dart';
import 'package:spar_vault/platform/system_lock_native.dart';
import 'package:spar_vault/platform/device_security.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DesktopSystemLock lock;
  final id = randomId();
  final root = randomBytes(32), secret = randomBytes(32);
  Map<String, dynamic> enrollment() => {
    'secret': Uint8List.fromList(secret).asUnmodifiableView(),
    'credential': base64Encode(randomBytes(32)),
    'publicKey': base64Encode(randomBytes(64)),
    'salt': base64Encode(randomBytes(32)),
  };
  Future<File> binding() async =>
      File('${directory.path}/sable_vault/system-lock.json');
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('spar-system-lock-test-');
    lock = DesktopSystemLock(
      supportDirectory: () async => directory,
      systemProvider: 'fido2',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          DesktopSystemLock.channel,
          (call) async => switch (call.method) {
            'enable' => enrollment(),
            'unlock' => Uint8List.fromList(secret).asUnmodifiableView(),
            'status' => {'systemProvider': 'fido2', 'screenLock': 'ready'},
            _ => null,
          },
        );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DesktopSystemLock.channel, null);
    await directory.delete(recursive: true);
  });
  test(
    'desktop enrollment stores ciphertext and public metadata only',
    () async {
      await lock.enable(id, root);
      final text = await (await binding()).readAsString();
      final saved = jsonDecode(text) as Map;
      expect(saved.containsKey('secret'), isFalse);
      expect(saved.containsKey('key'), isFalse);
      expect(text.contains(base64Encode(root)), isFalse);
      expect(text.contains(base64Encode(secret)), isFalse);
      expect(await lock.enabled(id), isTrue);
      expect(await lock.unlock(id), root);
    },
  );
  test('another vault cannot use an existing System lock binding', () async {
    await lock.enable(id, root);
    expect(await lock.enabled(randomId()), isFalse);
    expect(await lock.unlock(randomId()), isNull);
  });
  test(
    'corrupt metadata is rejected before contacting the security key',
    () async {
      await lock.enable(id, root);
      final file = await binding(),
          value = jsonDecode(await (await binding()).readAsString()) as Map;
      value['publicKey'] = 'AAAA';
      await file.writeAsString(jsonEncode(value));
      await expectLater(lock.unlock(id), throwsFormatException);
    },
  );
  test(
    'cancelled enrollment never commits the late protected secret',
    () async {
      final started = Completer<void>(),
          response = Completer<Map<String, dynamic>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopSystemLock.channel, (call) async {
            if (call.method == 'enable') {
              started.complete();
              return response.future;
            }
            return null;
          });
      final future = lock.enable(id, root);
      final failure = expectLater(future, throwsFormatException);
      await started.future;
      await lock.cancel();
      response.complete(enrollment());
      await failure;
      expect(await (await binding()).exists(), isFalse);
    },
  );
  test('one native authentication runs at a time', () async {
    final started = Completer<void>(),
        response = Completer<Map<String, dynamic>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DesktopSystemLock.channel, (call) async {
          if (call.method == 'enable') {
            started.complete();
            return response.future;
          }
          return null;
        });
    final first = lock.enable(id, root);
    await started.future;
    await expectLater(lock.enable(id, root), throwsFormatException);
    response.complete(enrollment());
    await first;
  });
  test('clear removes a saved binding and disables quick unlock', () async {
    await lock.enable(id, root);
    await lock.clear();
    expect(await lock.enabled(id), isFalse);
    expect(await lock.unlock(id), isNull);
  });
  test('a symbolic-link binding is never followed', () async {
    await lock.enabled(id);
    final outside = File('${directory.path}/outside')
      ..writeAsStringSync('untouched');
    final file = await binding();
    await Link(file.path).create(outside.path);
    await expectLater(lock.enable(id, root), throwsFormatException);
    expect(await outside.readAsString(), 'untouched');
  }, skip: Platform.isWindows);
  test('System lock explains each actual desktop authentication provider', () {
    expect(
      const DeviceSecurityStatus(
        systemProvider: 'windows',
        screenLock: 'ready',
      ).explanation(true),
      contains('Windows Hello'),
    );
    expect(
      const DeviceSecurityStatus(
        systemProvider: 'macos',
        screenLock: 'signing_required',
      ).explanation(true),
      contains('signed'),
    );
    expect(
      const DeviceSecurityStatus(
        systemProvider: 'fido2',
        screenLock: 'ready',
      ).explanation(true),
      contains('FIDO2'),
    );
  });
}
