import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spar_vault/app/vault_controller.dart';
import 'package:vault_core/vault_core.dart';

class Store implements VaultStore {
  String? value;
  Completer<void>? gate;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String s, {required String? expected}) async {
    await gate?.future;
    if (value != expected) throw const ConcurrentVaultChange();
    value = s;
  }
}

void main() {
  const password = 'walnut comet amber bridge 835';
  test(
    'password and secure key independently unlock; locked KDF cannot reopen',
    () async {
      final store = Store(), v = VaultController(Store());
      await v.initialize();
      final root = MasterKey.generate(), text = root.display();
      try {
        await v.create(root, password: password);
        expect(v.passwordEnabled, isTrue);
        v.lock();
        await expectLater(
          v.unlockWithPassword('wrong password 123'),
          throwsA(isA<VaultOpenFailure>()),
        );
        expect(v.unlocked, isFalse);
        await v.unlockWithPassword(password);
        v.lock();
        await v.unlock(MasterKey.parse(text));
        v.lock();
        final pending = v.unlockWithPassword(password);
        final assertion = expectLater(pending, throwsA(isA<SessionExpired>()));
        v.lock();
        await assertion;
        expect(v.unlocked, isFalse);
        expect(store.value, isNull);
      } finally {
        v.dispose();
      }
    },
  );
  test(
    'rotation changes root, rewraps password, and old backups keep old key',
    () async {
      final s = Store(), v = VaultController(Store());
      await v.initialize();
      final old = MasterKey.generate(), oldText = old.display();
      final next = MasterKey.generate(), newText = next.display();
      try {
        await v.create(old, password: password);
        s.value = v.encryptedBackup;
        await v.rotateKey(next, password: 'new telescope walnut amber 437');
        final fresh = v.encryptedBackup!;
        v.lock();
        await expectLater(
          v.unlock(MasterKey.parse(oldText)),
          throwsA(isA<VaultOpenFailure>()),
        );
        await v.unlock(MasterKey.parse(newText));
        v.lock();
        await v.unlockWithPassword('new telescope walnut amber 437');
        final oldKey = MasterKey.parse(oldText);
        try {
          await VaultCodec().open(VaultBundle.parse(s.value!).vault, oldKey);
        } finally {
          oldKey.destroy();
        }
        expect(fresh, isNot(s.value));
      } finally {
        v.dispose();
      }
    },
  );
  test('merge previews conflicts/deletions and preserves local settings by default', () async {
    final s = Store(), v = VaultController(s);
    await v.initialize();
    final root = MasterKey.generate(), text = root.display();
    try {
      await v.create(root);
      final id = randomId();
      final e = VaultEntry(
        id: id,
        title: 'Login',
        password: 'old',
        updatedAt: DateTime.utc(2026),
      );
      await v.upsert(e);
      await v.upsert(e.copyWith(password: 'new'));
      expect(v.entries.single.history.single.password, 'old');
      final data = VaultData(createdAt: DateTime.utc(2026), entries: [e]);
      final k = MasterKey.parse(text);
      String incoming;
      try {
        incoming = VaultBundle(
          await VaultCodec().seal(data, k, vaultId: v.vaultId!, revision: 99),
        ).serialize();
      } finally {
        k.destroy();
      }
      expect((await v.previewMerge(incoming)).conflicts, ['Login']);
      await v.mergeSnapshot(incoming);
      expect(v.entries.single.password, 'new');
      await v.mergeSnapshot(incoming, useIncomingConflicts: true);
      expect(v.entries.single.password, 'old');
      await v.delete(id);
      expect((await v.previewMerge(incoming)).conflicts, ['Login']);
      await v.mergeSnapshot(incoming);
      expect(v.entries, isEmpty);
      await v.mergeSnapshot(incoming, useIncomingConflicts: true);
      expect(v.entries.length, 1);
    } finally {
      v.dispose();
    }
  });
  test('a verified replacement is invalidated by locking', () async {
    final s = Store(), v = VaultController(s);
    await v.initialize();
    final root = MasterKey.generate(), text = root.display();
    try {
      await v.create(root);
      final before = s.value;
      final verified = await v.verifyBackup(
        before!,
        key: MasterKey.parse(text),
      );
      v.lock();
      await expectLater(
        v.restoreVerified(verified),
        throwsA(isA<SessionExpired>()),
      );
      expect(verified.key, isNull);
      expect(s.value, before);
      expect(v.unlocked, isFalse);
    } finally {
      v.dispose();
    }
  });
  test('restore resets imported integration and backup permissions', () async {
    final v = VaultController(Store());
    await v.initialize();
    final root = MasterKey.generate(), text = root.display();
    try {
      await v.create(root);
      await v.updatePreferences(
        const VaultPreferences(
          autofillEnabled: true,
          desktopExtensionId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          backupEnabled: true,
          backupDirectory: '/foreign/device/path',
          idleMinutes: 10,
        ),
      );
      final snapshot = v.encryptedBackup!;
      await v.restore(snapshot, MasterKey.parse(text));
      expect(v.preferences.backupEnabled, isFalse);
      expect(v.preferences.autofillEnabled, isFalse);
      expect(v.preferences.backupDirectory, isEmpty);
      expect(v.preferences.desktopExtensionId, isEmpty);
      expect(v.preferences.idleMinutes, 10);
      v.lock();
      await v.unlock(MasterKey.parse(text));
      expect(v.preferences.backupEnabled, isFalse);
      expect(v.preferences.autofillEnabled, isFalse);
    } finally {
      v.dispose();
    }
  });
}
