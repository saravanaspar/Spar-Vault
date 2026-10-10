import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spar_vault/main.dart';
import 'package:spar_vault/platform/integrations.dart';
import 'package:spar_vault/platform/key_file_io.dart';
import 'package:vault_core/vault_core.dart';

class KeyDirectoryIntegrations extends PlatformIntegrations {
  KeyDirectoryIntegrations(this.selection, {this.android = false});
  final Future<String?> selection;
  final bool android;
  @override
  bool get isAndroid => android;
  @override
  Future<String?> chooseKeyDirectory() => selection;
}

class ExportTestStore implements VaultStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String encrypted, {required String? expected}) async {}
}

class ExportUiIntegrations extends PlatformIntegrations {
  Uint8List? received;
  String? exported;
  @override
  bool get isAndroid => true;
  @override
  bool get isDesktop => false;
  @override
  Future<DeviceSecurityStatus> deviceSecurityStatus() async =>
      const DeviceSecurityStatus();
  @override
  Future<KeyFileSaveResult?> saveMasterKey(
    Uint8List bytes, {
    required bool Function() canSave,
  }) async {
    expect(canSave(), isTrue);
    received = bytes;
    exported = utf8.decode(bytes);
    return KeyFileSaveResult.saved;
  }
}

Uint8List syntheticKey(int value) {
  final key = MasterKey.fromBytes(List.filled(32, value));
  try {
    return Uint8List.fromList(utf8.encode('${key.display()}\n'));
  } finally {
    key.destroy();
  }
}

void main() {
  testWidgets(
    'Android Dev key export confirms replacement and cleans its temporary bytes',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final integrations = ExportUiIntegrations();
      await tester.pumpWidget(
        SparVaultApp(store: ExportTestStore(), integrations: integrations),
      );
      await tester.pumpAndSettle();
      expect(find.text('Spar Vault Dev'), findsOneWidget);
      await tester.tap(find.text('Create a new vault'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save key file'));
      await tester.tap(find.text('Save key file'));
      await tester.pumpAndSettle();
      expect(integrations.received, isNull);
      expect(
        find.textContaining('Saving there replaces spar-vault-master-key.txt'),
        findsOneWidget,
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      final parsed = MasterKey.parse(integrations.exported!);
      parsed.destroy();
      expect(integrations.received, everyElement(0));
      expect(
        find.text(
          'Key file saved. The selected folder now has the current key.',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  test(
    'saving a key twice replaces the exact file; another folder is independent',
    () async {
      final dir = await Directory.systemTemp.createTemp('spar-key-export-');
      final first = syntheticKey(1), next = syntheticKey(2);
      try {
        final other = await Directory('${dir.path}/other').create();
        await writeMasterKeyFile(dir.path, first);
        await writeMasterKeyFile(other.path, first);
        await writeMasterKeyFile(dir.path, next);
        final saved = File('${dir.path}/$masterKeyFileName');
        expect(await saved.readAsBytes(), next);
        expect(
          await File('${other.path}/$masterKeyFileName').readAsBytes(),
          first,
        );
        expect((await dir.list().toList()).whereType<File>().length, 1);
        expect((await other.list().toList()).length, 1);
        if (Platform.isLinux || Platform.isMacOS) {
          expect((await saved.stat()).mode & 0x1ff, 0x180); // 0600.
        }
      } finally {
        first.fillRange(0, first.length, 0);
        next.fillRange(0, next.length, 0);
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'invalid key or blocked filename leaves previous contents unchanged',
    () async {
      final dir = await Directory.systemTemp.createTemp('spar-key-export-');
      final bytes = syntheticKey(3);
      try {
        final target = File('${dir.path}/$masterKeyFileName');
        await writeMasterKeyFile(dir.path, bytes);
        await expectLater(
          writeMasterKeyFile(
            dir.path,
            Uint8List.fromList(utf8.encode('not a key')),
          ),
          throwsFormatException,
        );
        expect(await target.readAsBytes(), bytes);
        await target.delete();
        await Directory(target.path).create();
        await expectLater(
          writeMasterKeyFile(dir.path, bytes),
          throwsA(isA<FileSystemException>()),
        );
        expect((await dir.list().toList()).length, 1);
      } finally {
        bytes.fillRange(0, bytes.length, 0);
        await dir.delete(recursive: true);
      }
    },
  );

  test('a link at the key filename does not overwrite another file', () async {
    if (Platform.isWindows) {
      return; // Creating links requires extra Windows privileges.
    }
    final dir = await Directory.systemTemp.createTemp('spar-key-export-');
    final bytes = syntheticKey(4);
    try {
      final original = File('${dir.path}/original.txt');
      await original.writeAsString('keep this file');
      await Link('${dir.path}/$masterKeyFileName').create(original.path);
      await expectLater(
        writeMasterKeyFile(dir.path, bytes),
        throwsA(isA<FileSystemException>()),
      );
      expect(await original.readAsString(), 'keep this file');
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      await dir.delete(recursive: true);
    }
  });

  test('cancelled or late folder selection never writes the key', () async {
    final dir = await Directory.systemTemp.createTemp('spar-key-export-');
    final bytes = syntheticKey(5), selection = Completer<String?>();
    var current = true;
    try {
      expect(
        await KeyDirectoryIntegrations(Future.value(null))
            .saveMasterKey(bytes, canSave: () => true),
        isNull,
      );
      final pending = KeyDirectoryIntegrations(selection.future)
          .saveMasterKey(bytes, canSave: () => current);
      current = false;
      selection.complete(dir.path);
      expect(await pending, isNull);
      expect(await dir.list().toList(), isEmpty);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      await dir.delete(recursive: true);
    }
  });

  test(
    'Android sends the granted folder and complete key to the native writer',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const folder = 'content://synthetic/tree/keys';
      final bytes = syntheticKey(6);
      MethodCall? received;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PlatformIntegrations.channel, (call) async {
            received = call;
            return null;
          });
      try {
        final result = await KeyDirectoryIntegrations(
          Future.value(folder),
          android: true,
        ).saveMasterKey(bytes, canSave: () => true);
        expect(result, KeyFileSaveResult.saved);
        expect(received!.method, 'writeMasterKey');
        expect(received!.arguments['directory'], folder);
        expect(received!.arguments['bytes'], bytes);
      } finally {
        bytes.fillRange(0, bytes.length, 0);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(PlatformIntegrations.channel, null);
      }
    },
  );
}
