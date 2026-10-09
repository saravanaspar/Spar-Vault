import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

class TotpConfig {
  TotpConfig._(this.secret, this.digits, this.period, this.algorithm);
  final Uint8List secret;
  final int digits, period;
  final String algorithm;
  factory TotpConfig.parse(String value) {
    var text = value.trim();
    var digits = 6, period = 30, algorithm = 'SHA1';
    if (text.toLowerCase().startsWith('otpauth:')) {
      final uri = Uri.parse(text);
      if (uri.scheme != 'otpauth' || uri.host != 'totp') {
        throw const FormatException(
            'Only TOTP authenticator codes are supported.');
      }
      text = uri.queryParameters['secret'] ?? '';
      digits = int.tryParse(uri.queryParameters['digits'] ?? '6') ?? 0;
      period = int.tryParse(uri.queryParameters['period'] ?? '30') ?? 0;
      algorithm = (uri.queryParameters['algorithm'] ?? 'SHA1').toUpperCase();
    }
    text =
        text.replaceAll(' ', '').toUpperCase().replaceFirst(RegExp(r'=+$'), '');
    if (text.length < 16 ||
        text.length > 512 ||
        !RegExp(r'^[A-Z2-7]+$').hasMatch(text) ||
        ![6, 8].contains(digits) ||
        period < 15 ||
        period > 120 ||
        !['SHA1', 'SHA256', 'SHA512'].contains(algorithm)) {
      throw const FormatException(
          'Use a valid Base32 TOTP secret or otpauth://totp URI.');
    }
    var bits = 0, buffer = 0;
    final output = <int>[];
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    for (final ch in text.codeUnits) {
      buffer = (buffer << 5) | alphabet.indexOf(String.fromCharCode(ch));
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        output.add((buffer >> bits) & 255);
        buffer &= (1 << bits) - 1;
      }
    }
    if (buffer != 0) throw const FormatException('Noncanonical Base32 secret.');
    return TotpConfig._(Uint8List.fromList(output), digits, period, algorithm);
  }
  Future<String> code(DateTime now) async {
    final counter = now.toUtc().millisecondsSinceEpoch ~/ 1000 ~/ period;
    if (counter < 0) throw const FormatException('Invalid clock.');
    final message = Uint8List(8);
    ByteData.sublistView(message).setUint64(0, counter, Endian.big);
    final key =
        SecretKeyData(Uint8List.fromList(secret), overwriteWhenDestroyed: true);
    try {
      final hmac = switch (algorithm) {
        'SHA256' => Hmac.sha256(),
        'SHA512' => Hmac.sha512(),
        _ => Hmac.sha1()
      };
      final digest = (await hmac.calculateMac(message, secretKey: key)).bytes;
      final o = digest.last & 15;
      final n = ((digest[o] & 127) << 24) |
          (digest[o + 1] << 16) |
          (digest[o + 2] << 8) |
          digest[o + 3];
      return (n % (digits == 8 ? 100000000 : 1000000))
          .toString()
          .padLeft(digits, '0');
    } finally {
      key.destroy();
      message.fillRange(0, message.length, 0);
    }
  }

  int remaining(DateTime now) =>
      period - (now.millisecondsSinceEpoch ~/ 1000 % period);
  void destroy() => secret.fillRange(0, secret.length, 0);
}
