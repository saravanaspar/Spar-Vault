import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

Uint8List randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

String randomId() => randomBytes(16)
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

/// Only app-generated, uniformly random 256-bit keys are used at creation.
/// This is NOT a password KDF. Do not replace these keys with human passwords.
class MasterKey {
  MasterKey._(this._secret);

  factory MasterKey.fromBytes(List<int> bytes) {
    if (bytes.length != 32) throw const FormatException('Invalid master key.');
    return MasterKey._(
        SecretKeyData(Uint8List.fromList(bytes), overwriteWhenDestroyed: true));
  }

  Uint8List copyBytes() => Uint8List.fromList(_secret.bytes);

  factory MasterKey.generate() => MasterKey._(
        SecretKeyData(randomBytes(32), overwriteWhenDestroyed: true),
      );

  factory MasterKey.parse(String text) {
    if (text.length > 256) throw const FormatException('Invalid master key.');
    final normalized = text.replaceAll(RegExp(r'[\s-]'), '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized)) {
      throw const FormatException('Enter the full 64-character master key.');
    }
    return MasterKey._(SecretKeyData(
      Uint8List.fromList(List.generate(32,
          (i) => int.parse(normalized.substring(i * 2, i * 2 + 2), radix: 16))),
      overwriteWhenDestroyed: true,
    ));
  }

  final SecretKeyData _secret;
  SecretKey get secret => _secret;
  bool get isDestroyed => _secret.isDestroyed;

  String display() {
    final hex = _secret.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return List.generate(8, (i) => hex.substring(i * 8, i * 8 + 8)).join(' ');
  }

  bool matches(MasterKey other) {
    var difference = 0;
    for (var i = 0; i < 32; i++) {
      difference |= _secret.bytes[i] ^ other._secret.bytes[i];
    }
    return difference == 0;
  }

  void destroy() => _secret.destroy();
  @override
  String toString() => 'MasterKey(<redacted>)';
}

String generatePassword({int length = 24, bool symbols = true}) {
  if (length < 16 || length > 128) {
    throw ArgumentError('Password length must be between 16 and 128.');
  }
  const lower = 'abcdefghijklmnopqrstuvwxyz';
  const upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  const digits = '0123456789';
  const special = '!@#\$%^&*()-_=+[]{}:,.?';
  final groups = [lower, upper, digits, if (symbols) special];
  final alphabet = groups.join();
  final random = Random.secure();
  final chars = groups.map((g) => g[random.nextInt(g.length)]).toList();
  while (chars.length < length) {
    chars.add(alphabet[random.nextInt(alphabet.length)]);
  }
  for (var i = chars.length - 1; i > 0; i--) {
    final j = random.nextInt(i + 1);
    final temp = chars[i];
    chars[i] = chars[j];
    chars[j] = temp;
  }
  return chars.join();
}
