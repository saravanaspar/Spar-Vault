import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;
import 'package:vault_core/vault_core.dart';

import '../features/files.dart';

class AutofillBridge {
  JSFunction? _listener;
  String? _extension;
  DateTime? _deadline;
  int _epoch = 0;
  bool _pending = false;
  String? get statePath => null;
  Future<void> update(
    String extension,
    DateTime deadline,
    Future<VaultEntry?> Function(String) choose,
  ) async {
    _deadline = deadline;
    if (_extension == extension && _listener != null) return;
    await stop();
    if (!RegExp(r'^[a-p]{32}$').hasMatch(extension)) return;
    _extension = extension;
    _deadline = deadline;
    _listener = ((web.Event raw) {
      final event = raw as web.MessageEvent;
      if (event.origin != web.window.location.origin ||
          event.source != web.window ||
          _pending) {
        return;
      }
      final data = event.data.dartify();
      if (data is! Map ||
          data.length != 5 ||
          data['source'] != 'spar-vault-extension' ||
          data['extensionId'] != _extension ||
          data['origin'] is! String ||
          data['nonce'] is! String ||
          data['type'] != 'fill' ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(data['nonce'] as String)) {
        return;
      }
      final origin = webOrigin(data['origin'] as String), epoch = _epoch;
      if (origin == null ||
          origin != data['origin'] ||
          _deadline == null ||
          !DateTime.now().isBefore(_deadline!)) {
        return;
      }
      _pending = true;
      unawaited(() async {
        try {
          final entry = await choose(origin)
              .timeout(const Duration(seconds: 45));
          if (epoch != _epoch ||
              _deadline == null ||
              !DateTime.now().isBefore(_deadline!)) {
            return;
          }
          web.window.postMessage(
            {
              'source': 'spar-vault-response',
              'nonce': data['nonce'],
              'origin': origin,
              'username': entry?.username,
              'password': entry?.password,
            }.jsify(),
            web.window.location.origin.toJS,
          );
        } catch (_) {
        } finally {
          _pending = false;
        }
      }());
    }).toJS;
    web.window.addEventListener('message', _listener);
  }

  Future<void> stop() async {
    _epoch++;
    if (_listener != null) web.window.removeEventListener('message', _listener);
    _listener = null;
    _extension = null;
    _deadline = null;
  }
}
