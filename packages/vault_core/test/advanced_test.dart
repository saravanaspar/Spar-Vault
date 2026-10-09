import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:vault_core/vault_core.dart';

String base32(String value) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  var buffer = 0, bits = 0;
  final out = StringBuffer();
  for (final b in utf8.encode(value)) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(chars[(buffer >> bits) & 31]);
      buffer &= (1 << bits) - 1;
    }
  }
  if (bits > 0) out.write(chars[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

void main() {
  test('Argon2id matches an independent libargon2 reference vector', () async {
    final f = jsonDecode(await File('test/fixtures/python_argon2_vector.json')
        .readAsString()) as Map<String, dynamic>;
    final hex = f['saltHex'] as String,
        salt = List.generate(hex.length ~/ 2,
            (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16));
    final derived = await PasswordSlot.derive(f['password'] as String, salt);
    try {
      expect(
          (await derived.extractBytes())
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(),
          f['hashHex']);
    } finally {
      derived.destroy();
    }
  });
  test(
      'Argon2id root wrapping: password, binding, tamper and bounded parameters',
      () async {
    final root = MasterKey.generate(), id = randomId();
    const password = 'river amber telescope walnut 593';
    final slot = await PasswordSlot.wrap(root, password, id);
    try {
      final opened = await slot.unwrap(password, id);
      try {
        expect(opened.matches(root), isTrue);
      } finally {
        opened.destroy();
      }
      await expectLater(slot.unwrap('incorrect password here', id),
          throwsA(isA<VaultOpenFailure>()));
      await expectLater(
          slot.unwrap(password, randomId()), throwsA(isA<VaultOpenFailure>()));
      final changed = slot.toJson()..['memoryKiB'] = 999999999;
      expect(() => PasswordSlot.fromJson(changed),
          throwsA(isA<VaultOpenFailure>()));
      final tampered = slot.toJson(),
          tag = base64Decode(slot.toJson()['tag'] as String)..[0] ^= 1;
      tampered['tag'] = base64Encode(tag);
      await expectLater(PasswordSlot.fromJson(tampered).unwrap(password, id),
          throwsA(isA<VaultOpenFailure>()));
    } finally {
      root.destroy();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
  test('password wrapping rejects short/common passphrases', () {
    for (final p in ['short', '123456789012345', ' ' * 25]) {
      expect(() => validateUnlockPassword(p), throwsFormatException);
    }
    validateUnlockPassword('river amber telescope walnut 593');
  });
  const times = [
    59,
    1111111109,
    1111111111,
    1234567890,
    2000000000,
    20000000000
  ];
  const vectors = {
    'SHA1': [
      '94287082',
      '07081804',
      '14050471',
      '89005924',
      '69279037',
      '65353130'
    ],
    'SHA256': [
      '46119246',
      '68084774',
      '67062674',
      '91819424',
      '90698825',
      '77737706'
    ],
    'SHA512': [
      '90693936',
      '25091201',
      '99943326',
      '93441116',
      '38618901',
      '47863826'
    ]
  };
  for (final alg in vectors.keys) {
    test('RFC 6238 all six $alg vectors', () async {
      final secret = alg == 'SHA1'
          ? '12345678901234567890'
          : alg == 'SHA256'
              ? '12345678901234567890123456789012'
              : '1234567890123456789012345678901234567890123456789012345678901234';
      final c = TotpConfig.parse(
          'otpauth://totp/test?secret=${base32(secret)}&algorithm=$alg&digits=8');
      try {
        for (var i = 0; i < times.length; i++) {
          expect(
              await c.code(DateTime.fromMillisecondsSinceEpoch(times[i] * 1000,
                  isUtc: true)),
              vectors[alg]![i]);
        }
      } finally {
        c.destroy();
      }
    });
  }
  test('TOTP malformed configurations fail closed', () {
    for (final v in [
      'otpauth://hotp/test?secret=JBSWY3DPEHPK3PXP',
      'not base32',
      'otpauth://totp/test?secret=JBSWY3DPEHPK3PXP&digits=9',
      'otpauth://totp/test?secret=JBSWY3DPEHPK3PXP&period=0'
    ]) {
      expect(() => TotpConfig.parse(v), throwsFormatException);
    }
  });
  test('transfer authenticates secret, ciphertext, expiry and client nonce',
      () async {
    final root = MasterKey.generate(), ticket = TransferTicket.create();
    try {
      final vault = await VaultCodec().seal(
          VaultData(createdAt: DateTime.utc(2026), entries: []), root,
          vaultId: randomId(), revision: 1);
      final snapshot = VaultBundle(vault).serialize(), nonce = randomId();
      final encoded =
          await TransferPackage.seal(snapshot, ticket, requestNonce: nonce);
      expect(await TransferPackage.open(encoded, ticket, requestNonce: nonce),
          snapshot);
      final parsed = TransferTicket.parse(ticket.encode());
      expect(parsed.id, ticket.id);
      parsed.destroy();
      await expectLater(
          TransferPackage.open(encoded, ticket, requestNonce: randomId()),
          throwsA(isA<VaultOpenFailure>()));
      final changed = jsonDecode(encoded) as Map<String, dynamic>;
      final bytes = base64Decode(changed['ciphertext'])..[0] ^= 1;
      changed['ciphertext'] = base64Encode(bytes);
      await expectLater(
          TransferPackage.open(jsonEncode(changed), ticket,
              requestNonce: nonce),
          throwsA(isA<VaultOpenFailure>()));
      final wrong = TransferTicket(
          id: ticket.id, secret: randomBytes(32), expiresAt: ticket.expiresAt);
      try {
        await expectLater(
            TransferPackage.open(encoded, wrong, requestNonce: nonce),
            throwsA(isA<VaultOpenFailure>()));
      } finally {
        wrong.destroy();
      }
      expect(() => ticket.checkExpiry(ticket.expiresAt), throwsFormatException);
    } finally {
      root.destroy();
      ticket.destroy();
    }
  });
  test('private addresses reject DNS/public/noncanonical literals', () {
    for (final h in ['10.1.2.3', '192.168.1.2', '172.31.1.1', '127.0.0.1']) {
      expect(privateIpv4(h), isTrue);
    }
    for (final h in [
      '8.8.8.8',
      'example.com',
      '192.168.001.1',
      '172.32.1.1',
      '::1',
      '10.1.2.999'
    ]) {
      expect(privateIpv4(h), isFalse);
    }
  });
  test('attachment bounds, unsafe names and deletion overlap are rejected', () {
    final a = VaultAttachment(
        id: randomId(),
        name: 'private.pdf',
        base64Bytes: base64Encode([1, 2, 3]));
    final e = VaultEntry(
        id: randomId(),
        title: 'Entry',
        updatedAt: DateTime.utc(2026),
        attachments: [a],
        history: [PasswordVersion('old', DateTime.utc(2025))]);
    final data = VaultData(
        createdAt: DateTime.utc(2026),
        entries: [e],
        tombstones: {randomId(): DateTime.utc(2026)});
    expect(VaultData.fromJson(data.toJson()).toJson(), data.toJson());
    expect(
        () =>
            VaultAttachment(id: randomId(), name: '../secret', base64Bytes: ''),
        throwsFormatException);
    expect(
        () => VaultAttachment(
            id: randomId(),
            name: 'huge',
            base64Bytes: base64Encode(Uint8List(maxAttachmentBytes + 1))),
        throwsFormatException);
    expect(
        () => VaultData(
            createdAt: DateTime.utc(2026),
            entries: [e],
            tombstones: {e.id: DateTime.utc(2026)}),
        throwsFormatException);
  });
}
