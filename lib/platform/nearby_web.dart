import 'package:vault_core/vault_core.dart';

import 'nearby_models.dart';

class NearbyTransfer {
  NearbyTransfer({
    Future<void> Function()? permission,
    Future<void> Function(Map<String, Object>)? advertise,
    Future<List<Map>> Function()? nativeScan,
    Future<void> Function()? nativeStop,
  });
  bool get available => false;
  Future<List<NearbyDevice>> discover() async => [];
  Future<void> receive({
    required String name,
    required NearbyApproval approve,
    required NearbyImport import,
    required void Function(String) status,
  }) async =>
      throw const FormatException('Nearby transfer requires the native app.');
  Future<int> send(
    NearbyDevice device,
    String name,
    List<VaultEntry> entries,
    NearbyApproval approve,
  ) async =>
      throw const FormatException('Nearby transfer requires the native app.');
  Future<void> stop() async {}
}
