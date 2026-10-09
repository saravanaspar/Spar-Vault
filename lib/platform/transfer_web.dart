import 'package:vault_core/vault_core.dart';

import 'local_network.dart';

class LocalTransfer {
  bool get canHost => false;
  Future<List<String>> addresses() async => [];
  Future<List<LocalNetworkChoice>> networks() async => [];
  Future<TransferTicket> host(String address, String snapshot) async =>
      throw const FormatException(
        'Browsers use encrypted transfer files; LAN hosting requires the native app.',
      );
  Future<String> receive(TransferTicket ticket) async =>
      throw const FormatException(
        'Use the encrypted .svx transfer file in the browser.',
      );
  Future<void> stop() async {}
}
