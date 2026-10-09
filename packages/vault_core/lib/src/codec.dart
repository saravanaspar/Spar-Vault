import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'models.dart';
import 'secrets.dart';

class VaultOpenFailure implements Exception {
  const VaultOpenFailure();
  @override
  String toString() => 'Wrong master key, damaged vault, or unsupported file.';
}

class VaultEnvelope {
  VaultEnvelope._(
      {required this.vaultId,
      required this.revision,
      required this.salt,
      required this.nonce,
      required this.ciphertext,
      required this.tag});

  final String vaultId;
  final int revision;
  final List<int> salt, nonce, ciphertext, tag;

  List<int> get aad => utf8.encode(
      'SableVault|1|AES-256-GCM|HKDF-SHA256|$vaultId|$revision|${base64Encode(salt)}');

  String serialize() => jsonEncode({
        'format': 'sable-vault',
        'version': 1,
        'cipher': 'AES-256-GCM',
        'kdf': 'HKDF-SHA256',
        'vaultId': vaultId,
        'revision': revision,
        'salt': base64Encode(salt),
        'nonce': base64Encode(nonce),
        'ciphertext': base64Encode(ciphertext),
        'tag': base64Encode(tag),
      });

  factory VaultEnvelope.parse(String text) {
    if (text.length > maxEnvelopeBytes) throw const VaultOpenFailure();
    try {
      final data = jsonDecode(text);
      const fields = {
        'format',
        'version',
        'cipher',
        'kdf',
        'vaultId',
        'revision',
        'salt',
        'nonce',
        'ciphertext',
        'tag'
      };
      if (data is! Map<String, dynamic> ||
          data.length != fields.length ||
          data.keys.toSet().difference(fields).isNotEmpty ||
          data['format'] != 'sable-vault' ||
          data['version'] != 1 ||
          data['cipher'] != 'AES-256-GCM' ||
          data['kdf'] != 'HKDF-SHA256' ||
          data['revision'] is! int ||
          data['revision'] < 1 ||
          data['revision'] > 0x1fffffffffffff) {
        throw const VaultOpenFailure();
      }
      final id = checkedString(data['vaultId'], 32);
      checkId(id);
      List<int> decode(String field, int? length) {
        final encoded = checkedString(data[field], maxEnvelopeBytes);
        final bytes = base64Decode(encoded);
        if ((length != null && bytes.length != length) ||
            base64Encode(bytes) != encoded) {
          throw const VaultOpenFailure();
        }
        return bytes;
      }

      final ciphertext = decode('ciphertext', null);
      if (ciphertext.isEmpty ||
          ciphertext.length > maxPlaintextBytes ||
          ciphertext.length % 4096 != 0) {
        throw const VaultOpenFailure();
      }
      return VaultEnvelope._(
        vaultId: id,
        revision: data['revision'] as int,
        salt: decode('salt', 32),
        nonce: decode('nonce', 12),
        ciphertext: ciphertext,
        tag: decode('tag', 16),
      );
    } catch (_) {
      throw const VaultOpenFailure();
    }
  }
}

class VaultCodec {
  final _cipher = AesGcm.with256bits();
  final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  Future<SecretKeyData> _derive(
      MasterKey master, String id, List<int> salt) async {
    final derived = await _hkdf.deriveKey(
      secretKey: master.secret,
      nonce: salt,
      info: utf8.encode('SableVault/v1/encryption/$id'),
    );
    final bytes = await derived.extractBytes();
    try {
      return SecretKeyData(Uint8List.fromList(bytes),
          overwriteWhenDestroyed: true);
    } finally {
      // extractBytes may return an unmodifiable list. Destroy the owner too.
      derived.destroy();
      if (bytes is Uint8List) bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<String> seal(
    VaultData data,
    MasterKey key, {
    required String vaultId,
    required int revision,
  }) async {
    checkId(vaultId);
    if (revision < 1 || revision > 0x1fffffffffffff) {
      throw const FormatException('Invalid vault revision.');
    }
    final json = Uint8List.fromList(utf8.encode(jsonEncode(data.toJson())));
    final paddedLength = ((json.length + 4 + 4095) ~/ 4096) * 4096;
    if (paddedLength > maxPlaintextBytes) {
      json.fillRange(0, json.length, 0);
      throw const FormatException('Vault size limit reached.');
    }
    final padded = Uint8List(paddedLength);
    ByteData.sublistView(padded).setUint32(0, json.length, Endian.big);
    padded.setRange(4, 4 + json.length, json);
    json.fillRange(0, json.length, 0);
    final salt =
        randomBytes(32); // New independent encryption key on every save.
    final nonce = randomBytes(12);
    final header = VaultEnvelope._(
        vaultId: vaultId,
        revision: revision,
        salt: salt,
        nonce: nonce,
        ciphertext: const [],
        tag: const []);
    SecretKeyData? derived;
    try {
      derived = await _derive(key, vaultId, salt);
      final box = await _cipher.encrypt(padded,
          secretKey: derived, nonce: nonce, aad: header.aad);
      return VaultEnvelope._(
              vaultId: vaultId,
              revision: revision,
              salt: salt,
              nonce: nonce,
              ciphertext: box.cipherText,
              tag: box.mac.bytes)
          .serialize();
    } finally {
      derived?.destroy();
      padded.fillRange(0, padded.length, 0);
    }
  }

  Future<VaultData> open(String encrypted, MasterKey key) async {
    SecretKeyData? derived;
    List<int>? plaintext;
    try {
      final envelope = VaultEnvelope.parse(encrypted);
      derived = await _derive(key, envelope.vaultId, envelope.salt);
      plaintext = await _cipher.decrypt(
        SecretBox(envelope.ciphertext,
            nonce: envelope.nonce, mac: Mac(envelope.tag)),
        secretKey: derived,
        aad: envelope.aad,
      );
      final buffer = Uint8List.fromList(plaintext);
      try {
        final size = ByteData.sublistView(buffer).getUint32(0, Endian.big);
        if (size < 2 || size > buffer.length - 4) {
          throw const VaultOpenFailure();
        }
        for (var i = size + 4; i < buffer.length; i++) {
          if (buffer[i] != 0) throw const VaultOpenFailure();
        }
        final parsed =
            jsonDecode(utf8.decode(Uint8List.sublistView(buffer, 4, size + 4)));
        if (parsed is! Map<String, dynamic>) throw const VaultOpenFailure();
        return VaultData.fromJson(parsed);
      } finally {
        buffer.fillRange(0, buffer.length, 0);
      }
    } catch (_) {
      throw const VaultOpenFailure();
    } finally {
      derived?.destroy();
      if (plaintext is Uint8List) plaintext.fillRange(0, plaintext.length, 0);
    }
  }
}
