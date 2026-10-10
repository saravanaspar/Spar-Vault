import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:vault_core/vault_core.dart';

class SessionExpired implements Exception {
  const SessionExpired();
  @override
  String toString() => 'Vault locked. Open it again to continue.';
}

Future<Map<String, Object>> _wrapPasswordWorker(Map<String, Object> m) async {
  final bytes = m['key'] as Uint8List;
  final key = MasterKey.fromBytes(bytes);
  try {
    return (await PasswordSlot.wrap(
      key,
      m['password'] as String,
      m['vaultId'] as String,
    )).toJson();
  } finally {
    key.destroy();
    bytes.fillRange(0, bytes.length, 0);
  }
}

Future<Uint8List> _unwrapPasswordWorker(Map<String, Object> m) async {
  final slot = PasswordSlot.fromJson(
    Map<String, dynamic>.from(m['slot'] as Map),
  );
  final key = await slot.unwrap(
    m['password'] as String,
    m['vaultId'] as String,
  );
  try {
    return key.copyBytes();
  } finally {
    key.destroy();
  }
}

Future<PasswordSlot> wrapPassword(
  MasterKey key,
  String password,
  String vaultId,
) async {
  final bytes = key.copyBytes();
  try {
    return PasswordSlot.fromJson(
      Map<String, dynamic>.from(
        await compute(_wrapPasswordWorker, {
          'key': bytes,
          'password': password,
          'vaultId': vaultId,
        }),
      ),
    );
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

Future<MasterKey> unwrapPassword(
  PasswordSlot slot,
  String password,
  String vaultId,
) async {
  final bytes = await compute(_unwrapPasswordWorker, {
    'slot': slot.toJson(),
    'password': password,
    'vaultId': vaultId,
  });
  try {
    return MasterKey.fromBytes(bytes);
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

class VerifiedBackup {
  VerifiedBackup._(this.bundle, this.data, this.key, this.epoch);
  final VaultBundle bundle;
  final VaultData data;
  MasterKey? key;
  final int epoch;
  void destroy() {
    key?.destroy();
    key = null;
  }
}

class MergePreview {
  const MergePreview(this.additions, this.conflicts, this.deletions);
  final List<String> additions, conflicts, deletions;
}

class VaultController extends ChangeNotifier {
  VaultController(this.store);
  final VaultStore store;
  final _codec = VaultCodec();
  MasterKey? _key, _pendingKey;
  VaultData? _data;
  String? _encrypted;
  VaultBundle? _cachedBundle;
  VaultBundle? get _bundle => _encrypted == null
      ? null
      : (_cachedBundle ??= VaultBundle.parse(_encrypted!));
  void _setSnapshot(String? value) {
    _encrypted = value;
    _cachedBundle = null;
  }

  var _epoch = 0;
  bool _disposed = false, busy = false, initialized = false;
  bool get hasVault => _encrypted != null;
  bool get unlocked => _data != null && _key != null;
  bool get passwordEnabled => _bundle?.passwordSlot != null;
  List<VaultEntry> get entries => _data?.entries ?? const [];
  VaultPreferences get preferences =>
      _data?.preferences ?? const VaultPreferences();
  String? get encryptedBackup => _encrypted;
  String? get vaultId => _bundle?.header.vaultId;
  int get revision => _bundle?.header.revision ?? 0;
  int get sessionEpoch => _epoch;
  Uint8List copyKeyForBiometrics() {
    if (!unlocked) throw const SessionExpired();
    return _key!.copyBytes();
  }

  Future<void> initialize() async {
    final snapshot = await store.read();
    if (_disposed) return;
    // Retain the exact unreadable snapshot for compare-and-swap recovery.
    // Never pretend corrupt storage is an empty vault.
    _setSnapshot(snapshot);
    if (snapshot != null) VaultBundle.parse(snapshot);
    initialized = true;
    notifyListeners();
  }

  void _check(int epoch) {
    if (_disposed || _epoch != epoch) throw const SessionExpired();
  }

  Future<T> _operation<T>(Future<T> Function(int) action) async {
    if (_disposed) throw const SessionExpired();
    if (busy) throw StateError('Another vault operation is in progress.');
    busy = true;
    final epoch = _epoch;
    notifyListeners();
    try {
      return await action(epoch);
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<T> _keyOperation<T>(MasterKey key, Future<T> Function(int) action) {
    if (busy || _disposed) {
      key.destroy();
      return Future.error(const SessionExpired());
    }
    return _operation(action);
  }

  Future<void> unlock(MasterKey key) => _keyOperation(key, (epoch) async {
    _pendingKey = key;
    try {
      final snapshot = await store.read();
      _check(epoch);
      if (snapshot == null) throw const VaultOpenFailure();
      final opened = await _codec.open(VaultBundle.parse(snapshot).vault, key);
      _check(epoch);
      _key?.destroy();
      _key = key;
      _pendingKey = null;
      _data = opened;
      _setSnapshot(snapshot);
    } catch (_) {
      key.destroy();
      _pendingKey = null;
      rethrow;
    }
  });
  Future<void> unlockWithPassword(String password) => _operation((epoch) async {
    MasterKey? key;
    try {
      final snapshot = await store.read();
      _check(epoch);
      if (snapshot == null) throw const VaultOpenFailure();
      final bundle = VaultBundle.parse(snapshot),
          slot = VaultBundle.parse(snapshot).passwordSlot;
      if (slot == null) throw const VaultOpenFailure();
      key = await unwrapPassword(slot, password, bundle.header.vaultId);
      _pendingKey = key;
      _check(epoch);
      final opened = await _codec.open(bundle.vault, key);
      _check(epoch);
      _key?.destroy();
      _key = key;
      _pendingKey = null;
      _data = opened;
      _setSnapshot(snapshot);
    } catch (_) {
      key?.destroy();
      _pendingKey = null;
      rethrow;
    }
  });
  Future<void> create(MasterKey key, {String? password}) => _keyOperation(key, (
    epoch,
  ) async {
    _pendingKey = key;
    try {
      if (await store.read() != null) throw const ConcurrentVaultChange();
      _check(epoch);
      final data = VaultData(createdAt: DateTime.now().toUtc(), entries: []),
          id = randomId();
      final slot = password == null
          ? null
          : await wrapPassword(key, password, id);
      _check(epoch);
      final vault = await _codec.seal(data, key, vaultId: id, revision: 1);
      final snapshot = VaultBundle(vault, passwordSlot: slot).serialize();
      _check(epoch);
      await store.write(snapshot, expected: null);
      _setSnapshot(snapshot);
      _check(epoch);
      _key = key;
      _pendingKey = null;
      _data = data;
    } catch (_) {
      key.destroy();
      _pendingKey = null;
      rethrow;
    }
  });
  Future<VerifiedBackup> verifyBackup(
    String backup, {
    MasterKey? key,
    String? password,
  }) {
    if (busy || _disposed) {
      key?.destroy();
      return Future.error(const SessionExpired());
    }
    return _operation((epoch) async {
      var owned = key;
      try {
        final bundle = VaultBundle.parse(backup);
        if (owned == null) {
          final slot = bundle.passwordSlot;
          if (slot == null || password == null) throw const VaultOpenFailure();
          owned = await unwrapPassword(slot, password, bundle.header.vaultId);
        }
        _pendingKey = owned;
        _check(epoch);
        final opened = await _codec.open(bundle.vault, owned);
        _check(epoch);
        _pendingKey = null;
        return VerifiedBackup._(bundle, opened, owned, epoch);
      } catch (_) {
        owned?.destroy();
        _pendingKey = null;
        rethrow;
      }
    });
  }

  Future<void> restoreVerified(VerifiedBackup verified) =>
      _operation((epoch) async {
        final key = verified.key;
        if (key == null || verified.epoch != epoch) {
          verified.destroy();
          throw const SessionExpired();
        }
        _pendingKey = key;
        try {
          // Do not inherit device permissions/integration opt-ins from an
          // imported vault. Portable layout/session settings can be retained.
          final prefs = verified.data.preferences;
          final restored = VaultData(
            createdAt: verified.data.createdAt,
            entries: verified.data.entries,
            tombstones: verified.data.tombstones,
            preferences: VaultPreferences(
              idleMinutes: prefs.idleMinutes,
              lockOnBackground: prefs.lockOnBackground,
              pageSize: prefs.pageSize,
              backupReminderDays: prefs.backupReminderDays,
            ),
          );
          final header = verified.bundle.header;
          final inner = await _codec.seal(
            restored,
            key,
            vaultId: header.vaultId,
            revision: header.revision + 1,
          );
          final snapshot = VaultBundle(
            inner,
            passwordSlot: verified.bundle.passwordSlot,
          ).serialize();
          _check(epoch);
          await store.write(snapshot, expected: _encrypted);
          _setSnapshot(snapshot);
          _check(epoch);
          _key?.destroy();
          _key = key;
          verified.key = null;
          _pendingKey = null;
          _data = restored;
          initialized = true;
        } catch (_) {
          verified.destroy();
          _pendingKey = null;
          rethrow;
        }
      });
  Future<void> restore(String backup, MasterKey key) async {
    if (busy || _disposed) {
      key.destroy();
      throw const SessionExpired();
    }
    final verified = await verifyBackup(backup, key: key);
    try {
      await restoreVerified(verified);
    } finally {
      verified.destroy();
    }
  }

  Future<void> _commit(
    VaultData data,
    int epoch, {
    PasswordSlot? slot,
    bool replaceSlot = false,
    MasterKey? newKey,
  }) async {
    if (!unlocked) throw const SessionExpired();
    final previous = _encrypted!,
        bundle = VaultBundle.parse(previous),
        header = bundle.header;
    final vault = await _codec.seal(
      data,
      newKey ?? _key!,
      vaultId: header.vaultId,
      revision: header.revision + 1,
    );
    _check(epoch);
    final snapshot = VaultBundle(
      vault,
      passwordSlot: replaceSlot ? slot : bundle.passwordSlot,
    ).serialize();
    await store.write(snapshot, expected: previous);
    _setSnapshot(snapshot);
    _check(epoch);
    _data = data;
  }

  Future<void> upsert(VaultEntry entry) => _operation((epoch) async {
    if (!unlocked) throw const SessionExpired();
    final old = entries.where((e) => e.id == entry.id).firstOrNull;
    if (entry.totp.isNotEmpty) {
      final config = TotpConfig.parse(entry.totp);
      config.destroy();
    }
    if (old != null) {
      final history = old.password != entry.password && old.password.isNotEmpty
          ? [
              PasswordVersion(old.password, DateTime.now().toUtc()),
              ...old.history,
            ].take(10).toList()
          : old.history;
      entry = entry.copyWith(history: history);
    }
    final tombstones = Map<String, DateTime>.from(_data!.tombstones)
      ..remove(entry.id);
    await _commit(
      VaultData(
        createdAt: _data!.createdAt,
        entries: [...entries.where((e) => e.id != entry.id), entry],
        preferences: preferences,
        tombstones: tombstones,
      ),
      epoch,
    );
  });
  Future<void> delete(String id) => _operation((epoch) async {
    if (!unlocked) throw const SessionExpired();
    final tombstones = Map<String, DateTime>.from(_data!.tombstones)
      ..[id] = DateTime.now().toUtc();
    // Bound deletion metadata; old backups are never treated as proof of absence.
    if (tombstones.length > maxItems) {
      throw const FormatException(
        'Deletion record limit reached. Export a backup before starting a new vault; existing records are retained to prevent old transfers resurrecting deleted items.',
      );
    }
    await _commit(
      VaultData(
        createdAt: _data!.createdAt,
        entries: entries.where((e) => e.id != id).toList(),
        preferences: preferences,
        tombstones: tombstones,
      ),
      epoch,
    );
  });
  Future<int> importEntries(List<VaultEntry> incoming) => _operation((
    epoch,
  ) async {
    if (!unlocked) throw const SessionExpired();
    if (incoming.length > maxItems) {
      throw const FormatException('Too many incoming items.');
    }
    final local = {for (final entry in entries) entry.id: entry};
    var count = 0;
    for (final entry in incoming) {
      final old = local[entry.id];
      if (old != null && jsonEncode(old.toJson()) == jsonEncode(entry.toJson())) {
        continue;
      }
      final value = old != null || _data!.tombstones.containsKey(entry.id)
          ? VaultEntry.fromJson({...entry.toJson(), 'id': randomId()})
          : entry;
      local[value.id] = value;
      count++;
    }
    if (count == 0) return 0;
    await _commit(
      VaultData(
        createdAt: _data!.createdAt,
        entries: local.values.toList(),
        preferences: preferences,
        tombstones: _data!.tombstones,
      ),
      epoch,
    );
    return count;
  });
  Future<void> updatePreferences(VaultPreferences prefs) =>
      _operation((epoch) async {
        if (!unlocked) throw const SessionExpired();
        await _commit(
          VaultData(
            createdAt: _data!.createdAt,
            entries: entries,
            preferences: prefs,
            tombstones: _data!.tombstones,
          ),
          epoch,
        );
      });
  Future<void> setPassword(String? password) => _operation((epoch) async {
    if (!unlocked) throw const SessionExpired();
    final slot = password == null
        ? null
        : await wrapPassword(_key!, password, vaultId!);
    _check(epoch);
    await _commit(_data!, epoch, slot: slot, replaceSlot: true);
  });
  Future<void> rotateKey(MasterKey newKey, {String? password}) =>
      _keyOperation(newKey, (epoch) async {
        if (!unlocked) {
          newKey.destroy();
          throw const SessionExpired();
        }
        _pendingKey = newKey;
        try {
          if (passwordEnabled && password == null) {
            throw const FormatException(
              'Enter a new unlock password, or explicitly remove password unlock before rotating.',
            );
          }
          final slot = password == null
              ? null
              : await wrapPassword(newKey, password, vaultId!);
          _check(epoch);
          await _commit(
            _data!,
            epoch,
            slot: slot,
            replaceSlot: true,
            newKey: newKey,
          );
          _key?.destroy();
          _key = newKey;
          _pendingKey = null;
        } catch (_) {
          newKey.destroy();
          _pendingKey = null;
          rethrow;
        }
      });
  Future<VaultData> _incoming(String snapshot, int epoch) async {
    if (!unlocked) throw const SessionExpired();
    final bundle = VaultBundle.parse(snapshot);
    if (bundle.header.vaultId != vaultId) {
      throw const FormatException(
        'This belongs to another vault. Use Restore instead.',
      );
    }
    final data = await _codec.open(bundle.vault, _key!);
    _check(epoch);
    return data;
  }

  Future<MergePreview> previewMerge(String snapshot) =>
      _operation((epoch) async {
        final incoming = await _incoming(snapshot, epoch),
            local = {for (final e in entries) e.id: e};
        final additions = <String>[],
            conflicts = <String>[],
            deletions = <String>[];
        for (final e in incoming.entries) {
          final old = local[e.id];
          if (old == null && !_data!.tombstones.containsKey(e.id)) {
            additions.add(e.title);
          } else if (old == null ||
              jsonEncode(old.toJson()) != jsonEncode(e.toJson())) {
            conflicts.add(e.title);
          }
        }
        for (final id in incoming.tombstones.keys) {
          if (local.containsKey(id)) deletions.add(local[id]!.title);
        }
        return MergePreview(additions, conflicts, deletions);
      });
  Future<void> mergeSnapshot(
    String snapshot, {
    bool useIncomingConflicts = false,
    bool applyDeletions = false,
  }) => _operation((epoch) async {
    final incoming = await _incoming(snapshot, epoch),
        local = {for (final e in entries) e.id: e},
        tombstones = Map<String, DateTime>.from(_data!.tombstones);
    for (final e in incoming.entries) {
      if (!local.containsKey(e.id) && !tombstones.containsKey(e.id) ||
          useIncomingConflicts) {
        local[e.id] = e;
        tombstones.remove(e.id);
      }
    }
    if (applyDeletions) {
      for (final item in incoming.tombstones.entries) {
        local.remove(item.key);
        tombstones[item.key] = item.value;
      }
    }
    if (tombstones.length > maxItems) {
      throw const FormatException('Deletion record limit reached.');
    }
    await _commit(
      VaultData(
        createdAt: _data!.createdAt,
        entries: local.values.toList(),
        preferences: preferences,
        tombstones: tombstones,
      ),
      epoch,
    );
  });
  void lock() {
    _epoch++;
    _pendingKey?.destroy();
    _pendingKey = null;
    _key?.destroy();
    _key = null;
    _data = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _pendingKey?.destroy();
    _key?.destroy();
    _key = null;
    _data = null;
    super.dispose();
  }
}
