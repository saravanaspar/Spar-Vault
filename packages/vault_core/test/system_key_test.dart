import 'dart:typed_data';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:vault_core/vault_core.dart';

void main() {
  test('System lock wraps and authenticates both root and vault identity',
      () async {
    final id = randomId(), other = randomId();
    final root = randomBytes(32), secret = randomBytes(32);
    final box = await wrapSystemKey(id, root, secret);
    expect(await unwrapSystemKey(id, box, secret), root);
    await expectLater(
        unwrapSystemKey(other, box, secret), throwsA(isA<Exception>()));
    await expectLater(
        unwrapSystemKey(id, box, randomBytes(32)), throwsA(isA<Exception>()));
    final tag = systemBytes(box['tag'], 16)..[0] ^= 1;
    box['tag'] = base64Encode(tag);
    await expectLater(
        unwrapSystemKey(id, box, secret), throwsA(isA<Exception>()));
  });
  test('System lock rejects malformed keys and binding lengths', () async {
    await expectLater(wrapSystemKey(randomId(), Uint8List(31), Uint8List(32)),
        throwsFormatException);
    expect(() => systemBytes('AAAA', 32), throwsFormatException);
    await expectLater(
        unwrapSystemKey('invalid', {}, Uint8List(32)), throwsFormatException);
  });
}
