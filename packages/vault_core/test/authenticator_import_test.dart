import 'dart:convert';
import 'package:test/test.dart';
import 'package:vault_core/vault_core.dart';

List<int> number(int value) {
  final bytes = <int>[];
  do {
    bytes.add((value & 127) | (value > 127 ? 128 : 0));
    value >>= 7;
  } while (value > 0);
  return bytes;
}

List<int> data(int field, List<int> value) =>
    [...number(field << 3 | 2), ...number(value.length), ...value];
List<int> scalar(int field, int value) =>
    [...number(field << 3), ...number(value)];
String migration(
    {int type = 2,
    int algorithm = 1,
    int digits = 1,
    int index = 0,
    List<int>? suffix}) {
  final account = [
    ...data(1, utf8.encode('12345678901234567890')),
    ...data(2, utf8.encode('Example:alice@example.test')),
    ...data(3, utf8.encode('Example')),
    ...scalar(4, algorithm),
    ...scalar(5, digits),
    ...scalar(6, type)
  ];
  final payload = [
    ...data(1, account),
    ...scalar(2, 1),
    ...scalar(3, 2),
    ...scalar(4, index),
    ...scalar(5, 42),
    ...?suffix
  ];
  return Uri(
      scheme: 'otpauth-migration',
      host: 'offline',
      queryParameters: {'data': base64Encode(payload)}).toString();
}

void main() {
  test(
      'Google export preserves RFC secret, labels, algorithms and batch metadata',
      () async {
    final imported = AuthenticatorImport.parse(migration());
    expect(imported.batchId, 42);
    expect(imported.batchSize, 2);
    expect(imported.batchIndex, 0);
    final account = imported.accounts.single;
    expect(account.title, 'Example');
    expect(account.username, 'alice@example.test');
    final config = TotpConfig.parse(account.uri);
    try {
      expect(config.secret, utf8.encode('12345678901234567890'));
      expect(
          await config
              .code(DateTime.fromMillisecondsSinceEpoch(59000, isUtc: true)),
          '287082');
    } finally {
      config.destroy();
    }
  });
  test('SHA256/SHA512 and eight-digit migration are preserved', () {
    for (final algorithm in [2, 3]) {
      final config = TotpConfig.parse(AuthenticatorImport.parse(
              migration(algorithm: algorithm, digits: 2, index: 1))
          .accounts
          .single
          .uri);
      try {
        expect(config.algorithm, algorithm == 2 ? 'SHA256' : 'SHA512');
        expect(config.digits, 8);
      } finally {
        config.destroy();
      }
    }
  });
  test('standard TOTP QR preserves period and deduplicates equivalent secrets',
      () {
    final account = AuthenticatorImport.parse(
            'otpauth://totp/Test:alice?secret=JBSWY3DPEHPK3PXP&issuer=Test&period=60')
        .accounts
        .single;
    final config = TotpConfig.parse(account.uri);
    try {
      expect(config.period, 60);
      expect(account.title, 'Test');
      expect(account.username, 'alice');
    } finally {
      config.destroy();
    }
    expect(totpIdentity(account.uri),
        totpIdentity('otpauth://totp/Other?secret=JBSWY3DPEHPK3PXP&period=60'));
  });
  test('HOTP and unsupported algorithms are rejected without changing type',
      () {
    expect(() => AuthenticatorImport.parse(migration(type: 1)),
        throwsA(isA<FormatException>()));
    expect(() => AuthenticatorImport.parse(migration(algorithm: 4)),
        throwsA(isA<FormatException>()));
    expect(
        () => AuthenticatorImport.parse(
            'otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=1'),
        throwsA(isA<FormatException>()));
  });
  test(
      'invalid page bounds, duplicate scalar fields, truncated bytes and oversize fail',
      () {
    for (final value in [
      migration(index: 2),
      migration(suffix: scalar(2, 1)),
      migration(suffix: [10, 127, 1]),
      'otpauth-migration://offline?data=AA==',
      'x' * 65537
    ]) {
      expect(() => AuthenticatorImport.parse(value),
          throwsA(isA<FormatException>()));
    }
  });
  test('unknown protobuf fields are skipped safely', () {
    expect(
        AuthenticatorImport.parse(migration(suffix: data(100, [1, 2, 3])))
            .accounts,
        hasLength(1));
  });
}
