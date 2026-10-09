import 'package:flutter_test/flutter_test.dart';
import 'package:spar_vault/platform/transfer_native.dart';
import 'package:vault_core/vault_core.dart';

void main() {
  test(
    'one-use authenticated native transport round-trip and replay refusal',
    () async {
      final transport = LocalTransfer(), root = MasterKey.generate();
      try {
        final snapshot = VaultBundle(
          await VaultCodec().seal(
            VaultData(createdAt: DateTime.utc(2026), entries: []),
            root,
            vaultId: randomId(),
            revision: 1,
          ),
        ).serialize();
        final live = await transport.host('127.0.0.1', snapshot);
        final receiver = TransferTicket.parse(live.encode());
        try {
          expect(await transport.receive(receiver), snapshot);
          await expectLater(transport.receive(receiver), throwsA(anything));
        } finally {
          receiver.destroy();
        }
      } finally {
        root.destroy();
        await transport.stop();
      }
    },
  );
}
