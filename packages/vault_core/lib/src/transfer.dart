import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'bundle.dart';
import 'codec.dart';
import 'models.dart';
import 'secrets.dart';

const maxTransferBytes = 48 * 1024 * 1024;
bool privateIpv4(String host) {
  final p = host.split('.').map(int.tryParse).toList();
  if (p.length != 4 || p.any((n) => n == null || n < 0 || n > 255)) {
    return false;
  }
  if (p.map((n) => n.toString()).join('.') != host) return false;
  return p[0] == 10 ||
      p[0] == 127 ||
      p[0] == 192 && p[1] == 168 ||
      p[0] == 172 && p[1]! >= 16 && p[1]! <= 31;
}

class TransferTicket {
  TransferTicket(
      {required this.id,
      required this.secret,
      required this.expiresAt,
      this.host = '',
      this.port = 0}) {
    checkId(id);
    if (secret.length != 32 ||
        !expiresAt.isUtc ||
        (host.isNotEmpty &&
            (!privateIpv4(host) || port < 1024 || port > 65535))) {
      throw const FormatException('Invalid transfer ticket.');
    }
  }
  factory TransferTicket.create({String host = '', int port = 0}) =>
      TransferTicket(
          id: randomId(),
          secret: randomBytes(32),
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
          host: host,
          port: port);
  final String id, host;
  final int port;
  final Uint8List secret;
  final DateTime expiresAt;
  void checkExpiry(DateTime now) {
    if (!now.toUtc().isBefore(expiresAt) ||
        expiresAt.difference(now.toUtc()) > const Duration(minutes: 10)) {
      throw const FormatException(
          'Transfer expired. Start a new transfer on the other device.');
    }
  }

  String encode() =>
      'spar-vault://transfer/#${base64UrlEncode(utf8.encode(jsonEncode({
            'version': 1,
            'id': id,
            'secret': base64UrlEncode(secret),
            'expiresAt': expiresAt.toIso8601String(),
            'host': host,
            'port': port
          })))}';
  factory TransferTicket.parse(String text) {
    if (text.length > 2048) {
      throw const FormatException('Invalid transfer ticket.');
    }
    try {
      final uri = Uri.parse(text.trim());
      if (uri.scheme != 'spar-vault' ||
          uri.host != 'transfer' ||
          uri.query.isNotEmpty ||
          uri.path != '/') {
        throw const FormatException();
      }
      final m = jsonDecode(utf8.decode(base64Url.decode(uri.fragment)));
      if (m is! Map<String, dynamic>) throw const FormatException();
      checkFields(m, {'version', 'id', 'secret', 'expiresAt', 'host', 'port'});
      if (m['version'] != 1 || m['port'] is! int) throw const FormatException();
      return TransferTicket(
          id: checkedString(m['id'], 32),
          secret: Uint8List.fromList(
              base64Url.decode(checkedString(m['secret'], 64))),
          expiresAt: checkedDate(m['expiresAt']),
          host: checkedString(m['host'], 15),
          port: m['port'] as int);
    } catch (_) {
      throw const FormatException(
          'Use the full transfer code from the sending device.');
    }
  }
  Future<String> proof(String requestNonce) async {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestNonce)) {
      throw const FormatException('Invalid request nonce.');
    }
    final key =
        SecretKeyData(Uint8List.fromList(secret), overwriteWhenDestroyed: true);
    try {
      return base64UrlEncode((await Hmac.sha256().calculateMac(
              utf8.encode('SparVault/transfer-request/v1|$id|$requestNonce'),
              secretKey: key))
          .bytes);
    } finally {
      key.destroy();
    }
  }

  void destroy() => secret.fillRange(0, secret.length, 0);
}

class TransferPackage {
  static List<int> _aad(TransferTicket ticket, String requestNonce) => utf8.encode(
      'SparVault/transfer/v1|${ticket.id}|${ticket.expiresAt.toIso8601String()}|$requestNonce');
  static Future<String> seal(String snapshot, TransferTicket ticket,
      {String requestNonce = ''}) async {
    ticket.checkExpiry(DateTime.now());
    VaultBundle.parse(snapshot);
    final bytes = Uint8List.fromList(utf8.encode(snapshot)),
        key = SecretKeyData(Uint8List.fromList(ticket.secret),
            overwriteWhenDestroyed: true);
    try {
      final box = await AesGcm.with256bits().encrypt(bytes,
          secretKey: key,
          nonce: randomBytes(12),
          aad: _aad(ticket, requestNonce));
      // The nonce belongs to the SecretBox, never an independently generated header.
      return jsonEncode({
        'format': 'spar-local-transfer',
        'version': 1,
        'id': ticket.id,
        'expiresAt': ticket.expiresAt.toIso8601String(),
        'requestNonce': requestNonce,
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'tag': base64Encode(box.mac.bytes)
      });
    } finally {
      key.destroy();
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  static Future<String> open(String text, TransferTicket ticket,
      {String requestNonce = ''}) async {
    ticket.checkExpiry(DateTime.now());
    if (text.length > maxTransferBytes) throw const VaultOpenFailure();
    SecretKeyData? key;
    List<int>? plain;
    try {
      final m = jsonDecode(text);
      if (m is! Map<String, dynamic>) throw const VaultOpenFailure();
      checkFields(m, {
        'format',
        'version',
        'id',
        'expiresAt',
        'requestNonce',
        'nonce',
        'ciphertext',
        'tag'
      });
      if (m['format'] != 'spar-local-transfer' ||
          m['version'] != 1 ||
          m['id'] != ticket.id ||
          m['expiresAt'] != ticket.expiresAt.toIso8601String() ||
          m['requestNonce'] != requestNonce) {
        throw const VaultOpenFailure();
      }
      List<int> decode(String f, int? length) {
        final s = checkedString(m[f], maxTransferBytes);
        final b = base64Decode(s);
        if ((length != null && b.length != length) || base64Encode(b) != s) {
          throw const VaultOpenFailure();
        }
        return b;
      }

      final ciphertext = decode('ciphertext', null);
      if (ciphertext.length > maxEnvelopeBytes) throw const VaultOpenFailure();
      key = SecretKeyData(Uint8List.fromList(ticket.secret),
          overwriteWhenDestroyed: true);
      plain = await AesGcm.with256bits().decrypt(
          SecretBox(ciphertext,
              nonce: decode('nonce', 12), mac: Mac(decode('tag', 16))),
          secretKey: key,
          aad: _aad(ticket, requestNonce));
      final snapshot = utf8.decode(plain);
      VaultBundle.parse(snapshot);
      return snapshot;
    } catch (_) {
      throw const VaultOpenFailure();
    } finally {
      key?.destroy();
      if (plain is Uint8List) plain.fillRange(0, plain.length, 0);
    }
  }
}
