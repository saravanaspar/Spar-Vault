import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_core/vault_core.dart';

import 'package:spar_vault/platform/nearby_io.dart';
import 'package:spar_vault/platform/nearby_models.dart';

Future<String> address() async =>
    Platform.environment['SPAR_NEARBY_TEST_ADDRESS'] ?? '127.0.0.1';
void main() {
  test('nearby receiver discovers and imports selected items with matching fingerprints', () async {
    final sender = NearbyTransfer();
    final advertised = Completer<Map<String, Object>>(),
        received = <VaultEntry>[];
    final host = await address();
    final nativeReceiver = NearbyTransfer(
      advertise: (metadata) async {
        advertised.complete(metadata);
      },
    );
    String? receiverCode;
    try {
      await nativeReceiver.receive(
        name: 'Receiver phone',
        approve: (_, count, code) async {
          receiverCode = code;
          expect(count, 1);
          return true;
        },
        import: (entries) async {
          received.addAll(entries);
          return entries.length;
        },
        status: (_) {},
      );
      final metadata = await advertised.future;
      final finder = NearbyTransfer(
        nativeScan: () async => [
          {...metadata, 'host': host},
        ],
      );
      try {
        final devices = await finder.discover();
        expect(devices.map((d) => d.name), contains('Receiver phone'));
      } finally {
        await finder.stop();
      }
      final item = VaultEntry(
        id: randomId(),
        title: 'Selected account',
        password: 'PRIVATE',
        updatedAt: DateTime.utc(2026),
      );
      final count = await sender.send(
        NearbyDevice.fromJson({...metadata, 'host': host}),
        'Sender phone',
        [item],
        (_, count, code) async {
          // Both prompts must be available before either requires approval.
          for (var i = 0; receiverCode == null && i < 100; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(code, receiverCode);
          return true;
        },
      );
      expect(count, 1);
      expect(received.single.toJson(), item.toJson());
    } finally {
      await nativeReceiver.stop();
      await sender.stop();
    }
  });
  test('receiver rejection sends no items', () async {
    final advertised = Completer<Map<String, Object>>(),
        receiver = NearbyTransfer(
          advertise: (m) async => advertised.complete(m),
        ),
        sender = NearbyTransfer();
    var imports = 0;
    try {
      await receiver.receive(
        name: 'Receiver',
        approve: (_, _, _) async => false,
        import: (_) async {
          imports++;
          return 1;
        },
        status: (_) {},
      );
      final device = NearbyDevice.fromJson({
        ...await advertised.future,
        'host': await address(),
      });
      final item = VaultEntry(
        id: randomId(),
        title: 'Private',
        updatedAt: DateTime.utc(2026),
      );
      await expectLater(
        sender.send(device, 'Sender', [item], (_, _, _) async => true),
        throwsA(isA<FormatException>()),
      );
      expect(imports, 0);
    } finally {
      await receiver.stop();
      await sender.stop();
    }
  });
  test(
    'closing receiver during pending approval cancels before import',
    () async {
      final advertised = Completer<Map<String, Object>>(),
          asked = Completer<void>(),
          gate = Completer<bool>();
      final receiver = NearbyTransfer(
            advertise: (m) async => advertised.complete(m),
          ),
          sender = NearbyTransfer();
      var imports = 0;
      try {
        await receiver.receive(
          name: 'Receiver',
          approve: (_, _, _) {
            asked.complete();
            return gate.future;
          },
          import: (_) async {
            imports++;
            return 1;
          },
          status: (_) {},
        );
        final device = NearbyDevice.fromJson({
          ...await advertised.future,
          'host': await address(),
        });
        final item = VaultEntry(
          id: randomId(),
          title: 'Private',
          updatedAt: DateTime.utc(2026),
        );
        final sending = sender.send(device, 'Sender', [
          item,
        ], (_, _, _) async => true);
        final failure = expectLater(sending, throwsA(anything));
        await asked.future;
        await receiver.stop();
        gate.complete(true);
        await failure;
        expect(imports, 0);
      } finally {
        if (!gate.isCompleted) gate.complete(false);
        await receiver.stop();
        await sender.stop();
      }
    },
  );
  test(
    'sender rejection cancels without waiting for receiver approval',
    () async {
      final advertised = Completer<Map<String, Object>>(),
          gate = Completer<bool>();
      final receiver = NearbyTransfer(
            advertise: (m) async => advertised.complete(m),
          ),
          sender = NearbyTransfer();
      var imports = 0;
      try {
        await receiver.receive(
          name: 'Receiver',
          approve: (_, _, _) => gate.future,
          import: (_) async {
            imports++;
            return 1;
          },
          status: (_) {},
        );
        final device = NearbyDevice.fromJson({
          ...await advertised.future,
          'host': await address(),
        });
        final item = VaultEntry(
          id: randomId(),
          title: 'Private',
          updatedAt: DateTime.utc(2026),
        );
        await expectLater(
          sender
              .send(device, 'Sender', [item], (_, _, _) async => false)
              .timeout(const Duration(seconds: 2)),
          throwsA(isA<FormatException>()),
        );
        expect(imports, 0);
      } finally {
        gate.complete(false);
        await receiver.stop();
        await sender.stop();
      }
    },
  );
}
