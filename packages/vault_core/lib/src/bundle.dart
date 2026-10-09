import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'codec.dart';
import 'models.dart';
import 'secrets.dart';

const passwordMemoryKiB = 19456;
const passwordIterations = 2;
void validateUnlockPassword(String password) {
  if (password.length < 15 ||
      password.length > 256 ||
      password.trim().length < 15 ||
      [
        'passwordpassword',
        '123456789012345',
        'qwertyqwertyqwerty',
        'letmeinletmeinletmein'
      ].contains(password.toLowerCase())) {
    throw const FormatException(
        'Use a unique password or passphrase of at least 15 characters (maximum 256).');
  }
}

/// Passwords only wrap a random root key; they never replace it as an AES key.
/// Fixed, bounded Argon2id v1.3 profile: 19 MiB, 2 passes, 1 lane, 32 bytes.
class PasswordSlot {
  PasswordSlot._(this.salt, this.nonce, this.ciphertext, this.tag);
  final List<int> salt, nonce, ciphertext, tag;
  Map<String, Object> toJson() => {
        'kdf': 'Argon2id',
        'version': 19,
        'memoryKiB': passwordMemoryKiB,
        'iterations': passwordIterations,
        'parallelism': 1,
        'salt': base64Encode(salt),
        'nonce': base64Encode(nonce),
        'ciphertext': base64Encode(ciphertext),
        'tag': base64Encode(tag)
      };
  factory PasswordSlot.fromJson(Map<String, dynamic> m) {
    checkFields(m, {
      'kdf',
      'version',
      'memoryKiB',
      'iterations',
      'parallelism',
      'salt',
      'nonce',
      'ciphertext',
      'tag'
    });
    if (m['kdf'] != 'Argon2id' ||
        m['version'] != 19 ||
        m['memoryKiB'] != passwordMemoryKiB ||
        m['iterations'] != passwordIterations ||
        m['parallelism'] != 1) {
      throw const VaultOpenFailure();
    }
    List<int> decode(String name, int length) {
      final text = checkedString(m[name], 128);
      final b = base64Decode(text);
      if (b.length != length || base64Encode(b) != text) {
        throw const VaultOpenFailure();
      }
      return b;
    }

    return PasswordSlot._(decode('salt', 32), decode('nonce', 12),
        decode('ciphertext', 32), decode('tag', 16));
  }
  List<int> _aad(String vaultId) => utf8.encode(
      'SparVault/password/v1|$vaultId|Argon2id|19|19456|2|1|${base64Encode(salt)}');
  static Future<SecretKey> derive(String password, List<int> salt) async {
    if (password.length > 256) throw const VaultOpenFailure();
    final bytes = Uint8List.fromList(utf8.encode(password));
    final input = SecretKeyData(bytes, overwriteWhenDestroyed: true);
    try {
      final derived = await Argon2id(
              parallelism: 1,
              memory: passwordMemoryKiB,
              iterations: passwordIterations,
              hashLength: 32)
          .deriveKey(secretKey: input, nonce: salt);
      final extracted = Uint8List.fromList(await derived.extractBytes());
      try {
        return SecretKeyData(Uint8List.fromList(extracted),
            overwriteWhenDestroyed: true);
      } finally {
        derived.destroy();
        extracted.fillRange(0, extracted.length, 0);
      }
    } finally {
      input.destroy();
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  static Future<PasswordSlot> wrap(
      MasterKey key, String password, String vaultId) async {
    validateUnlockPassword(password);
    checkId(vaultId);
    final salt = randomBytes(32), nonce = randomBytes(12);
    final derived = await derive(password, salt);
    final root = key.copyBytes();
    try {
      final header = PasswordSlot._(salt, nonce, const [], const []);
      final box = await AesGcm.with256bits().encrypt(root,
          secretKey: derived, nonce: nonce, aad: header._aad(vaultId));
      return PasswordSlot._(salt, nonce, box.cipherText, box.mac.bytes);
    } finally {
      derived.destroy();
      root.fillRange(0, root.length, 0);
    }
  }

  Future<MasterKey> unwrap(String password, String vaultId) async {
    SecretKey? derived;
    List<int>? root;
    try {
      derived = await derive(password, salt);
      root = await AesGcm.with256bits().decrypt(
          SecretBox(ciphertext, nonce: nonce, mac: Mac(tag)),
          secretKey: derived,
          aad: _aad(vaultId));
      return MasterKey.fromBytes(root);
    } catch (_) {
      throw const VaultOpenFailure();
    } finally {
      derived?.destroy();
      if (root is Uint8List) root.fillRange(0, root.length, 0);
    }
  }
}

class VaultBundle {
  VaultBundle(this.vault, {this.passwordSlot, this.legacy = false})
      : _header = VaultEnvelope.parse(vault);
  final VaultEnvelope _header;
  final String vault;
  final PasswordSlot? passwordSlot;
  final bool legacy;
  VaultEnvelope get header => _header;
  String serialize() => legacy
      ? vault
      : jsonEncode({
          'format': 'spar-vault-bundle',
          'version': 2,
          'vault': vault,
          'passwordUnlock': passwordSlot?.toJson()
        });
  factory VaultBundle.parse(String text) {
    if (text.length > maxEnvelopeBytes) throw const VaultOpenFailure();
    try {
      final m = jsonDecode(text);
      if (m is! Map<String, dynamic>) throw const VaultOpenFailure();
      if (m['format'] == 'sable-vault') {
        return VaultBundle(VaultEnvelope.parse(text).serialize(), legacy: true);
      }
      checkFields(m, {'format', 'version', 'vault', 'passwordUnlock'});
      if (m['format'] != 'spar-vault-bundle' ||
          m['version'] != 2 ||
          (m['passwordUnlock'] != null &&
              m['passwordUnlock'] is! Map<String, dynamic>)) {
        throw const VaultOpenFailure();
      }
      final vault = checkedString(m['vault'], maxEnvelopeBytes);
      return VaultBundle(vault,
          passwordSlot: m['passwordUnlock'] == null
              ? null
              : PasswordSlot.fromJson(
                  m['passwordUnlock'] as Map<String, dynamic>));
    } catch (_) {
      throw const VaultOpenFailure();
    }
  }
}
