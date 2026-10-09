import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spar_vault/app/vault_controller.dart';
import 'package:vault_core/vault_core.dart';

class MemoryStore implements VaultStore {
  String? snapshot;
  bool failWrites = false;
  Completer<void>? writeGate;
  @override
  Future<String?> read() async => snapshot;
  @override
  Future<void> write(String encrypted, {required String? expected}) async {
    if (writeGate != null) await writeGate!.future;
    if (failWrites) throw StateError('Disk full');
    if (snapshot != expected) throw const ConcurrentVaultChange();
    snapshot = encrypted;
  }
}

void main() {
  late MemoryStore store;
  late VaultController vault;
  late String key;
  final entry = VaultEntry(
    id: 'a' * 32,
    title: 'Email',
    password: 'VERY_PRIVATE',
    updatedAt: DateTime.utc(2026),
  );
  setUp(() async {
    store = MemoryStore();
    vault = VaultController(store);
    await vault.initialize();
    final master = MasterKey.generate();
    key = master.display();
    await vault.create(master);
  });
  tearDown(() => vault.dispose());

  test('lock clears entries and destroys the unlock key', () async {
    await vault.upsert(entry);
    vault.lock();
    expect(vault.unlocked, isFalse);
    expect(vault.entries, isEmpty);
    await vault.unlock(MasterKey.parse(key));
    expect(vault.entries.single.password, entry.password);
  });
  test('failed writes retain last saved entries and ciphertext', () async {
    final previous = store.snapshot;
    store.failWrites = true;
    await expectLater(vault.upsert(entry), throwsStateError);
    expect(vault.entries, isEmpty);
    expect(store.snapshot, previous);
    expect(vault.encryptedBackup, previous);
  });
  test('wrong backup key cannot replace the persisted vault', () async {
    final previous = store.snapshot;
    final otherKey = MasterKey.generate();
    final other = await VaultCodec().seal(
      VaultData(createdAt: DateTime.utc(2026), entries: [entry]),
      otherKey,
      vaultId: 'b' * 32,
      revision: 1,
    );
    otherKey.destroy();
    final wrong = MasterKey.generate();
    await expectLater(
      vault.restore(other, wrong),
      throwsA(isA<VaultOpenFailure>()),
    );
    expect(wrong.isDestroyed, isTrue);
    expect(store.snapshot, previous);
    expect(vault.entries, isEmpty);
  });
  test('another writer cannot be overwritten', () async {
    store.snapshot = 'external update';
    await expectLater(
      vault.upsert(entry),
      throwsA(isA<ConcurrentVaultChange>()),
    );
    expect(store.snapshot, 'external update');
    expect(vault.entries, isEmpty);
  });
  test(
    'lock while save is pending never restores decrypted session state',
    () async {
      store.writeGate = Completer<void>();
      final pending = vault.upsert(entry);
      final assertion = expectLater(pending, throwsA(isA<SessionExpired>()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      vault.lock();
      store.writeGate!.complete();
      await assertion;
      expect(vault.unlocked, isFalse);
      expect(vault.entries, isEmpty);
    },
  );
  test('lock during unlock destroys the pending key', () async {
    vault.lock();
    final pendingKey = MasterKey.parse(key);
    final pending = vault.unlock(pendingKey);
    final assertion = expectLater(pending, throwsA(isA<SessionExpired>()));
    vault.lock();
    await assertion;
    expect(vault.unlocked, isFalse);
    expect(pendingKey.isDestroyed, isTrue);
  });

  test('a rejected overlapping unlock destroys the supplied key', () async {
    store.writeGate = Completer<void>();
    final save = vault.upsert(entry);
    final candidate = MasterKey.generate();
    await expectLater(vault.unlock(candidate), throwsA(isA<SessionExpired>()));
    expect(candidate.isDestroyed, isTrue);
    store.writeGate!.complete();
    await save;
  });
  test(
    'encrypted backup can be opened on a new device using only its key',
    () async {
      await vault.upsert(entry);
      final second = VaultController(MemoryStore());
      await second.initialize();
      try {
        await second.restore(vault.encryptedBackup!, MasterKey.parse(key));
        expect(second.entries.single.password, entry.password);
      } finally {
        second.dispose();
      }
    },
  );
}
