import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vault_core/vault_core.dart';
import 'package:flutter/services.dart';

import 'local_network.dart';

class LocalTransfer {
  HttpServer? _server;
  TransferTicket? _ticket;
  Timer? _timer;
  Future<List<LocalNetworkChoice>> networks() async {
    await _permission();
    return (await NetworkInterface.list(type: InternetAddressType.IPv4))
        .expand(
          (n) => n.addresses.map((a) => LocalNetworkChoice(a.address, n.name)),
        )
        .where((n) => privateIpv4(n.address) && !n.address.startsWith('127.'))
        .toList();
  }

  Future<List<String>> addresses() async =>
      (await networks()).map((n) => n.address).toList();
  bool get canHost => true;
  Future<void> _permission() async {
    if (Platform.isAndroid &&
        await const MethodChannel('spar/integrations')
                .invokeMethod<bool>('localNetworkPermission') !=
            true) {
      throw const FormatException(
        'Local network permission is needed for LAN transfer. Use an encrypted transfer file instead.',
      );
    }
  }

  Future<TransferTicket> host(String address, String snapshot) async {
    await _permission();
    await stop();
    if (!privateIpv4(address)) {
      throw const FormatException('Choose a private local IPv4 address.');
    }
    VaultBundle.parse(snapshot);
    final server = await HttpServer.bind(address, 0, shared: false);
    _server = server;
    final ticket = TransferTicket.create(host: address, port: server.port);
    _ticket = ticket;
    _timer = Timer(const Duration(minutes: 5), () => unawaited(stop()));
    var used = false;
    var attempts = 0;
    server.listen((request) async {
      try {
        final ip = request.connectionInfo?.remoteAddress.address ?? '';
        if (!privateIpv4(ip) ||
            request.method != 'GET' ||
            request.uri.path != '/transfer' ||
            request.headers.value('origin') != null ||
            used ||
            ++attempts > 20) {
          request.response.statusCode = 403;
          return;
        }
        ticket.checkExpiry(DateTime.now());
        final q = request.uri.queryParameters;
        if (q.length != 3 || q['id'] != ticket.id) {
          throw const FormatException();
        }
        final nonce = q['nonce'] ?? '',
            expected = await ticket.proof(nonce),
            proof = q['proof'] ?? '';
        var different = expected.length ^ proof.length;
        for (var i = 0; i < expected.length; i++) {
          different |=
              expected.codeUnitAt(i) ^
              (i < proof.length ? proof.codeUnitAt(i) : 0);
        }
        if (different != 0 || used) throw const FormatException();
        used = true; // A ticket is consumed before awaiting encryption.
        final encoded = await TransferPackage.seal(
          snapshot,
          ticket,
          requestNonce: nonce,
        );
        request.response.headers.set('cache-control', 'no-store');
        request.response.headers.contentType = ContentType.json;
        request.response.write(encoded);
      } catch (_) {
        request.response.statusCode = 403;
      } finally {
        await request.response.close();
        if (used) unawaited(stop());
      }
    });
    return ticket;
  }

  Future<String> receive(TransferTicket ticket) async {
    await _permission();
    ticket.checkExpiry(DateTime.now());
    if (ticket.host.isEmpty || !privateIpv4(ticket.host)) {
      throw const FormatException(
        'This code is for a transfer file. Select its .svx file.',
      );
    }
    final nonce = randomId(), proof = await ticket.proof(nonce);
    // Raw sockets keep Android's global cleartext policy disabled. The payload
    // has application-level AEAD; neither plaintext credentials nor the secret
    // travel over this socket. No DNS, proxy, redirect, cookies or TLS claims.
    final socket = await Socket.connect(
      ticket.host,
      ticket.port,
      timeout: const Duration(seconds: 10),
    );
    final builder = BytesBuilder();
    try {
      socket.write(
        'GET /transfer?id=${ticket.id}&nonce=$nonce&proof=${Uri.encodeQueryComponent(proof)} HTTP/1.0\r\nHost: ${ticket.host}\r\nConnection: close\r\n\r\n',
      );
      await socket.flush();
      await for (final chunk in socket.timeout(const Duration(seconds: 20))) {
        if (builder.length + chunk.length > maxTransferBytes + 8192) {
          throw const FormatException('Transfer too large.');
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      try {
        final response = utf8.decode(bytes), end = response.indexOf('\r\n\r\n');
        if (end < 0 ||
            end > 8192 ||
            !RegExp(r'^HTTP/1\.[01] 200 ').hasMatch(response)) {
          throw const FormatException('Transfer refused or expired.');
        }
        return await TransferPackage.open(
          response.substring(end + 4),
          ticket,
          requestNonce: nonce,
        );
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
    } finally {
      socket.destroy();
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final s = _server;
    _server = null;
    await s?.close(force: true);
    _ticket?.destroy();
    _ticket = null;
  }
}
