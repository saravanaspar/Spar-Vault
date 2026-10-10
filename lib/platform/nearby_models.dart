import 'dart:convert';

import 'package:vault_core/vault_core.dart';

class NearbyDevice {
  NearbyDevice({
    required this.id,
    required this.publicKey,
    required this.name,
    required this.host,
    required this.port,
  }) {
    checkId(id);
    checkedString(name, 80, nonEmpty: true);
    final key = base64Url.decode(publicKey);
    if (key.length != 32 ||
        base64UrlEncode(key) != publicKey ||
        !privateIpv4(host) ||
        port < 1024 ||
        port > 65535) {
      throw const FormatException('Invalid nearby receiver.');
    }
  }
  final String id, publicKey, name, host;
  final int port;
  factory NearbyDevice.fromJson(Map value) => NearbyDevice(
    id: value['id'] as String,
    publicKey: value['public'] as String,
    name: value['name'] as String,
    host: value['host'] as String,
    port: value['port'] as int,
  );
  Map<String, Object> toJson() => {
    'id': id,
    'public': publicKey,
    'name': name,
    'host': host,
    'port': port,
  };
}

typedef NearbyApproval = Future<bool> Function(
  String name,
  int count,
  String verification,
);
typedef NearbyImport = Future<int> Function(List<VaultEntry> entries);
