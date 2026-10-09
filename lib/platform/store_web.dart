import 'dart:async';
import 'dart:js_interop';

import 'package:vault_core/vault_core.dart';
import 'package:web/web.dart' as web;

VaultStore createLocalStore() => WebVaultStore();

class WebVaultStore implements VaultStore {
  Future<web.IDBDatabase>? _database;

  Future<web.IDBDatabase> _open() => _database ??= _connect();

  Future<web.IDBDatabase> _connect() async {
    if (!web.window.isSecureContext) {
      throw StateError('Use HTTPS or localhost to open the web vault.');
    }
    final factory = web.window.indexedDB;
    final request = factory.open('sable-vault-v1', 1);
    final ready = Completer<web.IDBDatabase>();
    request.onupgradeneeded = ((web.Event event) {
      final database = request.result as web.IDBDatabase;
      database.createObjectStore('vault');
    }).toJS;
    request.onsuccess = ((web.Event event) {
      final database = request.result as web.IDBDatabase;
      database.onversionchange = ((web.Event e) => database.close()).toJS;
      if (!ready.isCompleted) ready.complete(database);
    }).toJS;
    request.onerror = ((web.Event event) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('Browser storage unavailable.'));
      }
    }).toJS;
    request.onblocked = ((web.Event event) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('Close other vault tabs and reload.'));
      }
    }).toJS;
    return ready.future;
  }

  @override
  Future<String?> read() async {
    final database = await _open();
    final transaction = database.transaction('vault'.toJS);
    final request = transaction.objectStore('vault').get('snapshot'.toJS);
    final done = Completer<String?>();
    String? value;
    request.onsuccess = ((web.Event event) {
      final raw = request.result;
      if (raw != null && !raw.isUndefinedOrNull) {
        value = (raw as JSString).toDart;
      }
    }).toJS;
    transaction.oncomplete = ((web.Event event) {
      if (!done.isCompleted) done.complete(value);
    }).toJS;
    transaction.onabort = ((web.Event event) {
      if (!done.isCompleted) {
        done.completeError(StateError('Cannot read browser vault.'));
      }
    }).toJS;
    transaction.onerror = ((web.Event event) {
      if (!done.isCompleted) {
        done.completeError(StateError('Cannot read browser vault.'));
      }
    }).toJS;
    return done.future;
  }

  @override
  Future<void> write(String encrypted, {required String? expected}) async {
    VaultBundle.parse(encrypted);
    final database = await _open();
    final transaction = database.transaction('vault'.toJS, 'readwrite');
    final store = transaction.objectStore('vault');
    final request = store.get('snapshot'.toJS);
    final done = Completer<void>();
    var conflict = false;
    request.onsuccess = ((web.Event event) {
      final raw = request.result;
      final current = (raw == null || raw.isUndefinedOrNull)
          ? null
          : (raw as JSString).toDart;
      if (current != expected) {
        conflict = true;
        transaction.abort();
      } else {
        // No await inside the transaction callback: IDB transactions auto-close.
        store.put(encrypted.toJS, 'snapshot'.toJS);
      }
    }).toJS;
    transaction.oncomplete = ((web.Event event) {
      if (!done.isCompleted) done.complete();
    }).toJS;
    void failed() {
      if (!done.isCompleted) {
        done.completeError(
          conflict
              ? const ConcurrentVaultChange()
              : StateError('Vault save failed. Check browser storage space.'),
        );
      }
    }

    transaction.onabort = ((web.Event event) => failed()).toJS;
    transaction.onerror = ((web.Event event) => failed()).toJS;
    return done.future;
  }
}
