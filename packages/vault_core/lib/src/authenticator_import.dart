import 'dart:convert';
import 'dart:typed_data';
import 'models.dart';
import 'totp.dart';

class AuthenticatorAccount {
  const AuthenticatorAccount(this.title, this.username, this.uri);
  final String title, username, uri;
  @override
  String toString() => 'AuthenticatorAccount(<redacted>)';
}

class AuthenticatorImport {
  const AuthenticatorImport(this.accounts,
      {this.batchId, this.batchSize = 1, this.batchIndex = 0});
  final List<AuthenticatorAccount> accounts;
  final int? batchId;
  final int batchSize, batchIndex;
  static AuthenticatorImport parse(String value) {
    if (value.length > 65536) {
      throw const FormatException('Authenticator QR is too large.');
    }
    final uri = Uri.tryParse(value.trim());
    if (uri == null) {
      throw const FormatException('Scan an authenticator QR code.');
    }
    if (uri.scheme == 'otpauth' && uri.host == 'totp') {
      final config = TotpConfig.parse(value.trim());
      try {
        final label = uri.pathSegments.join('/');
        final issuer = uri.queryParameters['issuer'] ??
            (label.contains(':') ? label.split(':').first : '');
        final account = label.contains(':')
            ? label.substring(label.indexOf(':') + 1).trim()
            : label;
        return AuthenticatorImport([
          _account(config.secret, issuer, account, config.algorithm,
              config.digits, config.period)
        ]);
      } finally {
        config.destroy();
      }
    }
    if (uri.scheme != 'otpauth-migration' ||
        uri.host != 'offline' ||
        uri.queryParametersAll['data']?.length != 1) {
      throw const FormatException(
          'Use a TOTP QR or Google Authenticator Export accounts QR.');
    }
    Uint8List? bytes;
    try {
      bytes = Uint8List.fromList(base64.decode(
          base64.normalize(uri.queryParameters['data']!.replaceAll(' ', '+'))));
      if (bytes.length > 49152) throw const FormatException();
      final reader = _Proto(bytes), accounts = <AuthenticatorAccount>[];
      int version = 1, size = 1, index = 0, id = 0;
      final seen = <int>{};
      while (!reader.done) {
        final tag = reader.number(), field = tag >> 3, wire = tag & 7;
        if (field == 0) throw const FormatException();
        if (field == 1 && wire == 2) {
          if (accounts.length >= maxItems) throw const FormatException();
          accounts.add(_googleAccount(reader.data()));
        } else if (field >= 2 && field <= 5 && wire == 0) {
          if (!seen.add(field)) throw const FormatException();
          final n = reader.number();
          switch (field) {
            case 2:
              version = n;
            case 3:
              size = n;
            case 4:
              index = n;
            case 5:
              id = n.toUnsigned(32);
          }
        } else {
          reader.skip(wire);
        }
      }
      if (version != 1 ||
          size < 1 ||
          size > 100 ||
          index < 0 ||
          index >= size ||
          accounts.isEmpty) {
        throw const FormatException();
      }
      return AuthenticatorImport(List.unmodifiable(accounts),
          batchId: id, batchSize: size, batchIndex: index);
    } on FormatException catch (error) {
      if (error.message == 'HOTP accounts cannot be imported as TOTP.' ||
          error.message ==
              'This QR uses an unsupported authenticator algorithm.') {
        rethrow;
      }
      throw const FormatException(
          'Invalid or unsupported Google Authenticator export QR.');
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
    }
  }
}

AuthenticatorAccount _googleAccount(Uint8List bytes) {
  final reader = _Proto(bytes), seen = <int>{};
  Uint8List? secret;
  var name = '', issuer = '', algorithm = 0, digits = 0, type = 0;
  try {
    while (!reader.done) {
      final tag = reader.number(), field = tag >> 3, wire = tag & 7;
      if (field == 0) throw const FormatException();
      if (field >= 1 && field <= 6 && !seen.add(field)) {
        throw const FormatException();
      }
      if (field == 1 && wire == 2) {
        secret = reader.data();
      } else if ((field == 2 || field == 3) && wire == 2) {
        final text = utf8.decode(reader.data());
        if (text.length > 1000) throw const FormatException();
        if (field == 2) {
          name = text;
        } else {
          issuer = text;
        }
      } else if (field >= 4 && field <= 6 && wire == 0) {
        final n = reader.number();
        if (field == 4) algorithm = n;
        if (field == 5) digits = n;
        if (field == 6) type = n;
      } else {
        reader.skip(wire);
      }
    }
    if (type == 1) {
      throw const FormatException('HOTP accounts cannot be imported as TOTP.');
    }
    if (type != 2 || secret == null || ![1, 2].contains(digits)) {
      throw const FormatException();
    }
    final hash = switch (algorithm) {
      1 => 'SHA1',
      2 => 'SHA256',
      3 => 'SHA512',
      _ => throw const FormatException(
          'This QR uses an unsupported authenticator algorithm.')
    };
    if (issuer.isNotEmpty && name.startsWith('$issuer:')) {
      name = name.substring(issuer.length + 1).trim();
    }
    return _account(secret, issuer, name, hash, digits == 2 ? 8 : 6, 30);
  } finally {
    secret?.fillRange(0, secret.length, 0);
    bytes.fillRange(0, bytes.length, 0);
  }
}

AuthenticatorAccount _account(List<int> secret, String issuer, String name,
    String algorithm, int digits, int period) {
  if (secret.length < 10 || secret.length > 320) {
    throw const FormatException('Invalid authenticator secret.');
  }
  issuer = issuer.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  name = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  final title =
      issuer.isEmpty ? (name.isEmpty ? 'Authenticator' : name) : issuer;
  checkedString(title, 200, nonEmpty: true);
  checkedString(name, 1000);
  var buffer = 0, bits = 0;
  final text = StringBuffer();
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  for (final byte in secret) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      text.write(alphabet[(buffer >> bits) & 31]);
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) text.write(alphabet[(buffer << (5 - bits)) & 31]);
  final uri = Uri(
      scheme: 'otpauth',
      host: 'totp',
      path: '/${issuer.isEmpty ? name : '$issuer:$name'}',
      queryParameters: {
        'secret': text.toString(),
        'algorithm': algorithm,
        'digits': '$digits',
        'period': '$period',
        if (issuer.isNotEmpty) 'issuer': issuer,
      }).toString();
  final config = TotpConfig.parse(uri);
  config.destroy();
  return AuthenticatorAccount(title, name, uri);
}

String totpIdentity(String value) {
  final config = TotpConfig.parse(value);
  try {
    return '${config.algorithm}/${config.digits}/${config.period}/${base64Encode(config.secret)}';
  } finally {
    config.destroy();
  }
}

class _Proto {
  _Proto(this.bytes);
  final Uint8List bytes;
  int offset = 0;
  bool get done => offset == bytes.length;
  int number() {
    var value = 0;
    for (var shift = 0; shift < 70; shift += 7) {
      if (offset >= bytes.length) throw const FormatException();
      final byte = bytes[offset++];
      if (shift == 63 && byte > 1) throw const FormatException();
      value |= (byte & 127) << shift;
      if (byte < 128) return value;
    }
    throw const FormatException();
  }

  Uint8List data() {
    final length = number();
    if (length < 0 || length > bytes.length - offset) {
      throw const FormatException();
    }
    final result = Uint8List.fromList(bytes.sublist(offset, offset + length));
    offset += length;
    return result;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        number();
      case 1:
        advance(8);
      case 2:
        advance(number());
      case 5:
        advance(4);
      default:
        throw const FormatException();
    }
  }

  void advance(int length) {
    if (length < 0 || length > bytes.length - offset) {
      throw const FormatException();
    }
    offset += length;
  }
}
