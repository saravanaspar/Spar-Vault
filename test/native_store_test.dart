import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spar_vault/platform/store_native.dart';
import 'package:vault_core/vault_core.dart';

void main() {
  test('native encrypted persistence is atomic and refuses concurrent stale writes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sable-store-test-',
    );
    final key = MasterKey.generate();
    final codec = VaultCodec();
    final data = VaultData(createdAt: DateTime.utc(2026), entries: []);
    final first = await codec.seal(data, key, vaultId: 'a' * 32, revision: 1);
    final second = await codec.seal(data, key, vaultId: 'a' * 32, revision: 2);
    final third = await codec.seal(data, key, vaultId: 'a' * 32, revision: 2);
    final store1 = NativeVaultStore(supportDirectory: () async => directory);
    final store2 = NativeVaultStore(supportDirectory: () async => directory);
    try {
      await store1.write(first, expected: null);
      expect(await store2.read(), first);
      final results = await Future.wait([
        store1
            .write(second, expected: first)
            .then((_) => true, onError: (_) => false),
        store2
            .write(third, expected: first)
            .then((_) => true, onError: (_) => false),
      ]);
      expect(results.where((success) => success).length, 1);
      expect(await store1.read(), anyOf(second, third));
      final files = await directory.list(recursive: true).toList();
      expect(files.where((file) => file.path.endsWith('.tmp')), isEmpty);
      if (Platform.isLinux || Platform.isMacOS) {
        final stored = files.whereType<File>().singleWhere(
          (file) => file.path.endsWith('.svlt'),
        );
        expect((await stored.stat()).mode & 0x1ff, 0x180); // 0600
      }
    } finally {
      key.destroy();
      await directory.delete(recursive: true);
    }
  });
}
