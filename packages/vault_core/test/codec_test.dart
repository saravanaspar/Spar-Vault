import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vault_core/vault_core.dart';

void main() {
  final codec = VaultCodec();
  late MasterKey key;
  late VaultData data;
  late String encrypted;
  const id = '0123456789abcdef0123456789abcdef';
  setUp(() async {
    key = MasterKey.generate();
    data = VaultData(createdAt: DateTime.utc(2026, 10, 8), entries: [
      VaultEntry(
          id: id,
          title: 'Private banking title',
          username: 'private@example.test',
          password: 'SECRET-to-keep-off-disk',
          notes: 'Top secret note',
          url: 'https://example.test',
          updatedAt: DateTime.utc(2026, 10, 8)),
    ]);
    encrypted = await codec.seal(data, key, vaultId: id, revision: 1);
  });
  tearDown(() => key.destroy());

  test('round trip encrypts every user field, including metadata', () async {
    for (final field in [
      'Private banking title',
      'private@example.test',
      'SECRET-to-keep-off-disk',
      'Top secret note',
      'example.test',
      key.display()
    ]) {
      expect(encrypted.contains(field), isFalse);
    }
    final opened = await codec.open(encrypted, key);
    expect(opened.toJson(), data.toJson());
    expect(VaultEnvelope.parse(encrypted).ciphertext.length % 4096, 0);
  });
  test('wrong key is rejected', () async {
    final wrong = MasterKey.generate();
    try {
      await expectLater(
          codec.open(encrypted, wrong), throwsA(isA<VaultOpenFailure>()));
    } finally {
      wrong.destroy();
    }
  });
  for (final field in ['ciphertext', 'tag', 'nonce', 'salt']) {
    test('tampered $field is rejected', () async {
      final map = jsonDecode(encrypted) as Map<String, dynamic>;
      final bytes = base64Decode(map[field]);
      bytes[0] ^= 1;
      map[field] = base64Encode(bytes);
      await expectLater(
          codec.open(jsonEncode(map), key), throwsA(isA<VaultOpenFailure>()));
    });
  }
  for (final field in [
    'revision',
    'vaultId',
    'version',
    'cipher',
    'kdf',
    'format'
  ]) {
    test('tampered authenticated header $field is rejected', () async {
      final map = jsonDecode(encrypted) as Map<String, dynamic>;
      map[field] = switch (field) {
        'revision' => 2,
        'version' => 2,
        'vaultId' => 'f' * 32,
        _ => 'unexpected',
      };
      await expectLater(
          codec.open(jsonEncode(map), key), throwsA(isA<VaultOpenFailure>()));
    });
  }
  test('every save uses a fresh salt, nonce and ciphertext', () async {
    final next = VaultEnvelope.parse(
        await codec.seal(data, key, vaultId: id, revision: 2));
    final old = VaultEnvelope.parse(encrypted);
    expect(next.salt, isNot(equals(old.salt)));
    expect(next.nonce, isNot(equals(old.nonce)));
    expect(next.ciphertext, isNot(equals(old.ciphertext)));
  });
  test('malformed, oversized, unknown and truncated envelopes are rejected',
      () {
    for (final input in [
      '{}',
      '[]',
      'not JSON',
      encrypted.substring(0, encrypted.length - 2),
      'x' * (maxEnvelopeBytes + 1)
    ]) {
      expect(
          () => VaultEnvelope.parse(input), throwsA(isA<VaultOpenFailure>()));
    }
    final map = jsonDecode(encrypted) as Map<String, dynamic>;
    map['extra'] = true;
    expect(() => VaultEnvelope.parse(jsonEncode(map)),
        throwsA(isA<VaultOpenFailure>()));
  });
  test('duplicate IDs and oversized fields are rejected before encryption', () {
    expect(
        () => VaultData(
            createdAt: DateTime.utc(2026),
            entries: [data.entries.first, data.entries.first]),
        throwsFormatException);
    expect(
        () =>
            VaultEntry(id: id, title: 'x' * 201, updatedAt: DateTime.utc(2026)),
        throwsFormatException);
  });
  test('key parser accepts groups, rejects passwords, and destroys secrets',
      () {
    final parsed = MasterKey.parse(key.display());
    expect(key.matches(parsed), isTrue);
    parsed.destroy();
    expect(parsed.isDestroyed, isTrue);
    expect(() => parsed.display(), throwsStateError);
    expect(() => MasterKey.parse('my-master-password'), throwsFormatException);
    expect(key.toString(), isNot(contains(key.display())));
  });
  test('generator meets length and character group requirements', () {
    for (var i = 0; i < 50; i++) {
      final password = generatePassword();
      expect(password.length, 24);
      for (final pattern in [r'[a-z]', r'[A-Z]', r'[0-9]', r'[^a-zA-Z0-9]']) {
        expect(RegExp(pattern).hasMatch(password), isTrue);
      }
    }
    expect(() => generatePassword(length: 8), throwsArgumentError);
    expect(RegExp(r'^[a-zA-Z0-9]+$').hasMatch(generatePassword(symbols: false)),
        isTrue);
  });
  test('opens an independently generated Python AES-GCM/HKDF fixture',
      () async {
    final fixture = jsonDecode(
            await File('test/fixtures/python_vector.json').readAsString())
        as Map<String, dynamic>;
    final fixtureKey = MasterKey.parse(fixture['key'] as String);
    try {
      final opened =
          await codec.open(jsonEncode(fixture['envelope']), fixtureKey);
      expect(
          opened.toJson(),
          VaultData.fromJson(
                  Map<String, dynamic>.from(fixture['plaintext'] as Map))
              .toJson());
    } finally {
      fixtureKey.destroy();
    }
  });
}
