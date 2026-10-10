import 'dart:convert';
import 'package:test/test.dart';
import 'package:vault_core/vault_core.dart';

void main() {
  test('both peers derive matching fingerprints and can exchange items/receipt',
      () async {
    final sender = await NearbyIdentity.create(),
        receiver = await NearbyIdentity.create();
    final offer = NearbyOffer(
        receiverId: receiver.id,
        receiverPublic: receiver.publicKey,
        senderId: sender.id,
        senderPublic: sender.publicKey,
        senderName: 'Alice phone',
        count: 1);
    final a = await sender.pair(offer), b = await receiver.pair(offer);
    try {
      expect(await a.verification(), await b.verification());
      final frame = await a.seal('items', {'secret': 'PRIVATE VALUE'});
      expect(frame, isNot(contains('PRIVATE VALUE')));
      expect(await b.open('items', frame), {'secret': 'PRIVATE VALUE'});
      expect(await a.open('receipt', await b.seal('receipt', {'imported': 1})),
          {'imported': 1});
      await expectLater(
          b.open('receipt', frame), throwsA(isA<FormatException>()));
      final tampered = jsonDecode(frame) as Map<String, dynamic>;
      final bytes = base64Decode(tampered['ciphertext'] as String);
      bytes[0] ^= 1;
      tampered['ciphertext'] = base64Encode(bytes);
      await expectLater(b.open('items', jsonEncode(tampered)),
          throwsA(isA<FormatException>()));
    } finally {
      a.destroy();
      b.destroy();
      sender.destroy();
      receiver.destroy();
    }
  });
  test('offer transcript binds sender name and item count', () async {
    final sender = await NearbyIdentity.create(),
        receiver = await NearbyIdentity.create();
    NearbyOffer offer(String name, int count) => NearbyOffer(
        receiverId: receiver.id,
        receiverPublic: receiver.publicKey,
        senderId: sender.id,
        senderPublic: sender.publicKey,
        senderName: name,
        count: count);
    final original = await sender.pair(offer('Alice', 1));
    final changed = await receiver.pair(offer('Mallory', 2));
    try {
      await expectLater(
          changed.open('items', await original.seal('items', {'entries': []})),
          throwsA(isA<FormatException>()));
    } finally {
      original.destroy();
      changed.destroy();
      sender.destroy();
      receiver.destroy();
    }
  });
  test('stale identities and weak all-zero public keys cannot pair', () async {
    final sender = await NearbyIdentity.create(),
        receiver = await NearbyIdentity.create(),
        stranger = await NearbyIdentity.create();
    final offer = NearbyOffer(
        receiverId: receiver.id,
        receiverPublic: receiver.publicKey,
        senderId: sender.id,
        senderPublic: sender.publicKey,
        senderName: 'Phone',
        count: 1);
    try {
      await expectLater(stranger.pair(offer), throwsA(isA<FormatException>()));
      final zero = NearbyOffer(
          receiverId: receiver.id,
          receiverPublic: base64UrlEncode(List.filled(32, 0)),
          senderId: sender.id,
          senderPublic: sender.publicKey,
          senderName: 'Phone',
          count: 1);
      await expectLater(sender.pair(zero), throwsA(anything));
    } finally {
      sender.destroy();
      receiver.destroy();
      stranger.destroy();
    }
  });
}
