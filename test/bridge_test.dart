import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spar_vault/platform/bridge_native.dart';
import 'package:vault_core/vault_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native broker rejects origin/token and returns only an approved exact-origin login', () async {
    final dir = await Directory.systemTemp.createTemp('spar-bridge-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    final bridge = AutofillBridge(),
        client = HttpOverrides.runWithHttpOverrides(
          () => HttpClient(),
          _RealHttp(),
        );
    var approvals = 0;
    final entry = VaultEntry(
      id: randomId(),
      title: 'Test',
      username: 'synthetic',
      password: 'synthetic-secret',
      url: 'https://example.test',
      updatedAt: DateTime.utc(2026),
    );
    try {
      await bridge.update(
        'a' * 32,
        DateTime.now().add(const Duration(minutes: 5)),
        (origin) async {
          approvals++;
          expect(origin, 'https://example.test');
          return entry;
        },
      );
      final state =
          jsonDecode(await File(bridge.statePath!).readAsString()) as Map;
      Future<HttpClientResponse> request(
        String token, {
        String? originHeader,
      }) async {
        final r = await client.post('127.0.0.1', state['port'] as int, '/fill');
        r.headers.set('authorization', 'Bearer $token');
        r.headers.set('x-extension-id', 'a' * 32);
        if (originHeader != null) r.headers.set('origin', originHeader);
        r.write(
          jsonEncode({'nonce': 'b' * 32, 'origin': 'https://example.test'}),
        );
        return r.close();
      }

      final denied = await request('incorrect');
      expect(denied.statusCode, 403);
      await denied.drain<void>();
      expect(approvals, 0);
      final cross = await request(
        state['token'] as String,
        originHeader: 'https://evil.test',
      );
      expect(cross.statusCode, 403);
      await cross.drain<void>();
      expect(approvals, 0);
      final good = await request(state['token'] as String);
      expect(good.statusCode, 200);
      final reply = jsonDecode(await utf8.decoder.bind(good).join());
      expect(reply['password'], entry.password);
      expect(reply.keys.toSet(), {'nonce', 'origin', 'username', 'password'});
      expect(approvals, 1);
      final path = bridge.statePath!;
      await bridge.stop();
      expect(await File(path).exists(), isFalse);
    } finally {
      client.close(force: true);
      await bridge.stop();
      await dir.delete(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
}

class _RealHttp extends HttpOverrides {}
