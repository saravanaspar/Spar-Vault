import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'models.dart';
import 'secrets.dart';
import 'transfer.dart';

class NearbyIdentity {
  NearbyIdentity._(this.id, this._pair);
  final String id;
  final SimpleKeyPairData _pair;
  String get publicKey => base64UrlEncode(_pair.publicKey.bytes);
  static Future<NearbyIdentity> create() async => NearbyIdentity._(
      randomId(), await (await X25519().newKeyPair()).extract());
  Future<NearbyCipher> pair(NearbyOffer offer) async {
    final receiver = id == offer.receiverId;
    if (!receiver && id != offer.senderId ||
        publicKey != (receiver ? offer.receiverPublic : offer.senderPublic)) {
      throw const FormatException('Wrong transfer identity.');
    }
    final peer =
        base64Url.decode(receiver ? offer.senderPublic : offer.receiverPublic);
    final shared = await X25519().sharedSecretKey(
        keyPair: _pair,
        remotePublicKey: SimplePublicKey(peer, type: KeyPairType.x25519));
    final material = SecretKeyData(await shared.extractBytes(),
        overwriteWhenDestroyed: true);
    try {
      final bytes = material.bytes;
      if (bytes.every((value) => value == 0)) {
        throw const FormatException('Invalid transfer public key.');
      }
      final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: material,
        nonce: (await Sha256().hash(utf8.encode(offer.context))).bytes,
        info: utf8.encode('SparVault/nearby/v2/session'),
      );
      return NearbyCipher._(offer, key);
    } finally {
      material.destroy();
      if (shared is SecretKeyData) shared.destroy();
    }
  }

  void destroy() => _pair.destroy();
  @override
  String toString() => 'NearbyIdentity(<redacted>)';
}

class NearbyOffer {
  NearbyOffer(
      {required this.receiverId,
      required this.receiverPublic,
      required this.senderId,
      required this.senderPublic,
      required this.senderName,
      required this.count}) {
    checkId(receiverId);
    checkId(senderId);
    if (senderId == receiverId) {
      throw const FormatException('Invalid transfer identities.');
    }
    checkedString(senderName, 80, nonEmpty: true);
    for (final value in [receiverPublic, senderPublic]) {
      if (value.length > 44 ||
          base64Url.decode(value).length != 32 ||
          base64UrlEncode(base64Url.decode(value)) != value) {
        throw const FormatException('Invalid transfer public key.');
      }
    }
    if (count < 1 || count > maxItems) {
      throw const FormatException('Select at least one item to send.');
    }
  }
  final String receiverId, receiverPublic, senderId, senderPublic, senderName;
  final int count;
  String get context => jsonEncode([
        'SparVault/nearby/v2',
        receiverId,
        receiverPublic,
        senderId,
        senderPublic,
        senderName,
        count
      ]);
  Map<String, Object> toJson() => {
        'version': 2,
        'receiverId': receiverId,
        'receiverPublic': receiverPublic,
        'senderId': senderId,
        'senderPublic': senderPublic,
        'senderName': senderName,
        'count': count
      };
  factory NearbyOffer.fromJson(Map<String, dynamic> value) {
    checkFields(value, {
      'version',
      'receiverId',
      'receiverPublic',
      'senderId',
      'senderPublic',
      'senderName',
      'count'
    });
    if (value['version'] != 2 || value['count'] is! int) {
      throw const FormatException('Unsupported transfer request.');
    }
    return NearbyOffer(
        receiverId: checkedString(value['receiverId'], 32),
        receiverPublic: checkedString(value['receiverPublic'], 44),
        senderId: checkedString(value['senderId'], 32),
        senderPublic: checkedString(value['senderPublic'], 44),
        senderName: checkedString(value['senderName'], 80),
        count: value['count'] as int);
  }
}

class NearbyCipher {
  NearbyCipher._(this.offer, this._key);
  final NearbyOffer offer;
  final SecretKeyData _key;
  Future<String> verification() async {
    final digest = (await Hmac.sha256().calculateMac(
            utf8.encode('${offer.context}|verify'),
            secretKey: _key))
        .bytes;
    final number =
        ((digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3]) &
            0xffffffff;
    return (number % 1000000).toString().padLeft(6, '0');
  }

  Future<String> seal(String purpose, Map<String, Object?> payload) async {
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    try {
      if (plain.length > maxPlaintextBytes) {
        throw const FormatException('Transfer is too large.');
      }
      final box = await AesGcm.with256bits().encrypt(plain,
          secretKey: _key,
          nonce: randomBytes(12),
          aad: utf8.encode('${offer.context}|$purpose'));
      return jsonEncode({
        'version': 2,
        'id': offer.senderId,
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'tag': base64Encode(box.mac.bytes)
      });
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  Future<Map<String, dynamic>> open(String purpose, String text) async {
    if (text.length > maxTransferBytes) {
      throw const FormatException('Transfer is too large.');
    }
    Uint8List? plain;
    try {
      final value = jsonDecode(text);
      if (value is! Map<String, dynamic>) throw const FormatException();
      checkFields(value, {'version', 'id', 'nonce', 'ciphertext', 'tag'});
      if (value['version'] != 2 || value['id'] != offer.senderId) {
        throw const FormatException();
      }
      List<int> decode(String field, int? length) {
        final text = checkedString(value[field], maxTransferBytes),
            bytes = base64Decode(text);
        if (base64Encode(bytes) != text ||
            length != null && bytes.length != length) {
          throw const FormatException();
        }
        return bytes;
      }

      final encrypted = decode('ciphertext', null);
      if (encrypted.length > maxPlaintextBytes) throw const FormatException();
      plain = Uint8List.fromList(await AesGcm.with256bits().decrypt(
          SecretBox(encrypted,
              nonce: decode('nonce', 12), mac: Mac(decode('tag', 16))),
          secretKey: _key,
          aad: utf8.encode('${offer.context}|$purpose')));
      final result = jsonDecode(utf8.decode(plain));
      if (result is! Map<String, dynamic>) throw const FormatException();
      return result;
    } catch (_) {
      throw const FormatException(
          'Transfer could not be authenticated. Start again.');
    } finally {
      plain?.fillRange(0, plain.length, 0);
    }
  }

  void destroy() => _key.destroy();
}
