import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'models.dart';

/// Authenticator hmac-secret is used only in memory, never saved beside the box.
Future<Map<String, String>> wrapSystemKey(
    String id, List<int> root, List<int> secret) async {
  checkId(id);
  if (root.length != 32 || secret.length != 32) {
    throw const FormatException('Invalid System lock key.');
  }
  final key =
      SecretKeyData(Uint8List.fromList(secret), overwriteWhenDestroyed: true);
  try {
    final box = await AesGcm.with256bits().encrypt(root,
        secretKey: key, aad: utf8.encode('SparVault/system-lock/fido2/v1|$id'));
    return {
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'tag': base64Encode(box.mac.bytes)
    };
  } finally {
    key.destroy();
  }
}

Uint8List systemBytes(Object? value, int size) {
  if (value is! String || value.length > ((size + 2) ~/ 3) * 4) {
    throw const FormatException('Invalid System lock binding.');
  }
  final bytes = base64Decode(value);
  if (bytes.length != size || base64Encode(bytes) != value) {
    throw const FormatException('Invalid System lock binding.');
  }
  return bytes;
}

Future<Uint8List> unwrapSystemKey(
    String id, Map binding, List<int> secret) async {
  checkId(id);
  if (secret.length != 32) {
    throw const FormatException('Invalid System lock key.');
  }
  final box = SecretBox(systemBytes(binding['ciphertext'], 32),
      nonce: systemBytes(binding['nonce'], 12),
      mac: Mac(systemBytes(binding['tag'], 16)));
  final key =
      SecretKeyData(Uint8List.fromList(secret), overwriteWhenDestroyed: true);
  try {
    return Uint8List.fromList(await AesGcm.with256bits().decrypt(box,
        secretKey: key,
        aad: utf8.encode('SparVault/system-lock/fido2/v1|$id')));
  } finally {
    key.destroy();
  }
}
