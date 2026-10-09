import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:vault_core/vault_core.dart';

import '../features/files.dart';

class AutofillBridge {
  HttpServer? _server;
  File? _state;
  String? _token, _extension;
  DateTime? _deadline;
  bool _pending = false;
  final _requests = <DateTime>[];
  String? get statePath => _state?.path;
  Future<void> update(
    String extension,
    DateTime deadline,
    Future<VaultEntry?> Function(String) choose,
  ) async {
    if (!Platform.isLinux && !Platform.isWindows) return;
    _deadline = deadline;
    if (_server != null && extension == _extension) {
      await _save();
      return;
    }
    await stop();
    if (!RegExp(r'^[a-p]{32}$').hasMatch(extension)) return;
    _extension = extension;
    _deadline = deadline;
    _token = base64UrlEncode(randomBytes(32));
    final dir = Directory(
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}sable_vault',
    );
    await dir.create(recursive: true);
    if (Platform.isLinux) {
      if ((await Process.run('chmod', ['700', dir.path])).exitCode != 0) {
        throw const FileSystemException('Cannot secure bridge folder.');
      }
    }
    _state = File('${dir.path}${Platform.pathSeparator}bridge.json');
    _server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    _server!.listen((r) async {
      try {
        final now = DateTime.now();
        _requests.removeWhere(
          (d) => now.difference(d) > const Duration(minutes: 1),
        );
        if (r.method != 'POST' ||
            r.uri.path != '/fill' ||
            r.headers.value('origin') != null ||
            r.headers.value('authorization') != 'Bearer $_token' ||
            r.headers.value('x-extension-id') != _extension ||
            _deadline == null ||
            !now.isBefore(_deadline!) ||
            _requests.length >= 12 ||
            _pending) {
          r.response.statusCode = 403;
          return;
        }
        _requests.add(now);
        final bytes = <int>[];
        await for (final chunk in r.timeout(const Duration(seconds: 5))) {
          bytes.addAll(chunk);
          if (bytes.length > 4096) throw const FormatException();
        }
        final m = jsonDecode(utf8.decode(bytes));
        if (m is! Map ||
            m.length != 2 ||
            m['nonce'] is! String ||
            !RegExp(r'^[0-9a-f]{32}$').hasMatch(m['nonce'] as String) ||
            m['origin'] is! String) {
          throw const FormatException();
        }
        final origin = webOrigin(m['origin'] as String);
        if (origin == null || origin != m['origin']) {
          throw const FormatException();
        }
        final sessionToken = _token;
        _pending = true;
        try {
          final entry = await choose(origin)
              .timeout(const Duration(seconds: 45));
          if (entry == null ||
              _token != sessionToken ||
              _deadline == null ||
              !DateTime.now().isBefore(_deadline!) ||
              webOrigin(entry.url) != origin) {
            r.response.statusCode = 403;
            return;
          }
          r.response.headers.contentType = ContentType.json;
          r.response.headers.set('cache-control', 'no-store');
          r.response.write(
            jsonEncode({
              'nonce': m['nonce'],
              'origin': origin,
              'username': entry.username,
              'password': entry.password,
            }),
          );
        } finally {
          _pending = false;
        }
      } catch (_) {
        r.response.statusCode = 403;
      } finally {
        await r.response.close();
      }
    });
    await _save();
  }

  Future<void> _save() async {
    final f = _state;
    if (f == null || _server == null || _deadline == null) return;
    final temp = File('${f.path}.${randomId()}.tmp');
    try {
      await temp.create(exclusive: true);
      if (Platform.isLinux &&
          (await Process.run('chmod', ['600', temp.path])).exitCode != 0) {
        throw const FileSystemException('Cannot secure bridge file.');
      }
      await temp.writeAsString(
        jsonEncode({
          'port': _server!.port,
          'token': _token,
          'extensionId': _extension,
          'expiresAt': _deadline!.millisecondsSinceEpoch,
        }),
        flush: true,
      );
      await temp.rename(f.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _token = null;
    _deadline = null;
    _extension = null;
    await server?.close(force: true);
    final file = _state;
    _state = null;
    if (file != null && await file.exists()) await file.delete();
  }
}
