import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vault_core/vault_core.dart';

import 'nearby_models.dart';

// Only public, short-lived receiver metadata is advertised. Pairing uses
// ephemeral X25519, a user-compared fingerprint, and AEAD for items/receipts.
class NearbyTransfer {
  NearbyTransfer({
    this.permission,
    this.advertise,
    this.nativeScan,
    this.nativeStop,
  });
  final Future<void> Function()? permission, nativeStop;
  final Future<void> Function(Map<String, Object>)? advertise;
  final Future<List<Map>> Function()? nativeScan;
  bool get available => true;
  static const discoveryPort = 47829;
  static final group = InternetAddress('239.255.77.77');
  int _epoch = 0;
  HttpServer? _server;
  RawDatagramSocket? _udp;
  final _clients = <Socket>{};
  NearbyIdentity? _identity;
  NearbyCipher? _cipher;
  Timer? _expiry;
  Completer<void>? _scanCancel;

  Future<List<NetworkInterface>> _interfaces() async {
    try {
      return (await NetworkInterface.list(type: InternetAddressType.IPv4))
          .where(
            (n) =>
                n.addresses.any((a) => privateIpv4(a.address) && !a.isLoopback),
          )
          .toList();
    } on SocketException {
      // Android NSD can still work when a platform cannot enumerate interfaces.
      return [];
    }
  }

  void _check(int epoch) {
    if (epoch != _epoch) {
      throw const FormatException('Transfer cancelled. Start again.');
    }
  }

  Future<List<NearbyDevice>> discover() async {
    await stop();
    final epoch = _epoch;
    await permission?.call();
    _check(epoch);
    final interfaces = await _interfaces();
    _check(epoch);
    if (interfaces.isEmpty && nativeScan == null) {
      throw const FormatException(
        'Connect both devices to the same Wi-Fi or hotspot.',
      );
    }
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    if (epoch != _epoch) {
      socket.close();
      _check(epoch);
    }
    _udp = socket;
    socket.broadcastEnabled = true;
    final nonce = randomId(), found = <String, NearbyDevice>{};
    final request = utf8.encode(jsonEncode({'spar': 2, 'find': nonce}));
    void accept(Map value) {
      try {
        final d = NearbyDevice.fromJson(value);
        if (found.length < 32 || found.containsKey(d.id)) found[d.id] = d;
      } catch (_) {
        /* Ignore unrelated/invalid advertisements. */
      }
    }

    final subscription = socket.listen(
      (event) {
        if (event != RawSocketEvent.read || epoch != _epoch) return;
        Datagram? packet;
        var packets = 0;
        while (packets++ < 64 && (packet = socket.receive()) != null) {
          final p = packet!;
          if (p.data.length > 2048 || !privateIpv4(p.address.address)) continue;
          try {
            final value = jsonDecode(utf8.decode(p.data));
            if (value is Map && value['spar'] == 2 && value['reply'] == nonce) {
              accept({...value, 'host': p.address.address});
            }
          } catch (_) {
            /* Invalid network packet. */
          }
        }
      },
      onError: (_) {
        /* UDP may be blocked; native NSD still runs. */
      },
    );
    final native = nativeScan == null
        ? Future<List<Map>>.value([])
        : nativeScan!()
              .timeout(const Duration(seconds: 7), onTimeout: () => [])
              .catchError((_) => <Map>[]);
    void broadcast() {
      if (epoch != _epoch) return;
      try {
        socket.send(request, group, discoveryPort);
        socket.send(request, InternetAddress('255.255.255.255'), discoveryPort);
      } catch (_) {
        /* NSD can still discover Android peers. */
      }
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          try {
            socket.send(request, group, discoveryPort);
            final subnet = address.address.split('.');
            subnet[3] = '255';
            socket.send(
              request,
              InternetAddress(subnet.join('.')),
              discoveryPort,
            );
          } catch (_) {
            /* Some interfaces do not permit multicast. */
          }
        }
      }
    }

    broadcast();
    final retry = Timer.periodic(
      const Duration(seconds: 1),
      (_) => broadcast(),
    );
    final cancel = Completer<void>();
    _scanCancel = cancel;
    try {
      await Future.any([
        Future<void>.delayed(const Duration(seconds: 5)),
        cancel.future,
      ]);
      _check(epoch);
      for (final value in await native) {
        accept(value);
      }
      _check(epoch);
      return found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    } finally {
      retry.cancel();
      await subscription.cancel();
      socket.close();
      if (identical(_udp, socket)) _udp = null;
      if (identical(_scanCancel, cancel)) _scanCancel = null;
    }
  }

  Future<void> receive({
    required String name,
    required NearbyApproval approve,
    required NearbyImport import,
    required void Function(String) status,
  }) async {
    await stop();
    final epoch = _epoch;
    await permission?.call();
    _check(epoch);
    final interfaces = await _interfaces();
    _check(epoch);
    if (interfaces.isEmpty && advertise == null) {
      throw const FormatException(
        'Connect both devices to the same Wi-Fi or hotspot.',
      );
    }
    final identity = await NearbyIdentity.create();
    if (epoch != _epoch) {
      identity.destroy();
      _check(epoch);
    }
    _identity = identity;
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      if (epoch != _epoch) {
        await server.close(force: true);
        _check(epoch);
      }
      _server = server;
      final cleanName = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
      final label = cleanName.isEmpty
          ? 'Spar Vault device'
          : cleanName.substring(
              0,
              cleanName.length > 80 ? 80 : cleanName.length,
            );
      final metadata = <String, Object>{
        'id': identity.id,
        'public': identity.publicKey,
        'name': label,
        'port': server.port,
      };
      // NSD is preferred on Android; UDP also lets native desktop apps find peers.
      var udpReady = false;
      try {
        final udp = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          discoveryPort,
          reuseAddress: true,
        );
        if (epoch != _epoch) {
          udp.close();
          _check(epoch);
        }
        _udp = udp;
        for (final interface in interfaces) {
          try {
            udp.joinMulticast(group, interface);
          } catch (_) {}
        }
        udpReady = true;
        var lastReply = DateTime.fromMillisecondsSinceEpoch(0);
        udp.listen(
          (event) {
            if (event != RawSocketEvent.read || epoch != _epoch) return;
            Datagram? packet;
            var packets = 0;
            while (packets++ < 64 && (packet = udp.receive()) != null) {
              final p = packet!;
              if (p.data.length > 256 ||
                  !privateIpv4(p.address.address) ||
                  DateTime.now().difference(lastReply).inMilliseconds < 100) {
                continue;
              }
              try {
                final v = jsonDecode(utf8.decode(p.data));
                if (v is! Map || v['spar'] != 2 || v['find'] is! String) {
                  continue;
                }
                checkId(v['find'] as String);
                udp.send(
                  utf8.encode(
                    jsonEncode({...metadata, 'spar': 2, 'reply': v['find']}),
                  ),
                  p.address,
                  p.port,
                );
                lastReply = DateTime.now();
              } catch (_) {}
            }
          },
          onError: (_) {
            /* Ignore asynchronous UDP errors; NSD remains available. */
          },
        );
      } catch (_) {
        if (epoch != _epoch) rethrow;
      }
      var nativeReady = false;
      if (advertise != null) {
        try {
          await advertise!(metadata);
          nativeReady = true;
        } catch (_) {}
      }
      _check(epoch);
      if (!udpReady && !nativeReady) {
        throw const FormatException(
          'Could not advertise this receiver. Check local network permission and Wi-Fi.',
        );
      }
      var attempts = 0, used = false, pairing = false;
      String? peerAddress;
      _expiry = Timer(const Duration(minutes: 5), () {
        if (epoch == _epoch) {
          status('Receiver timed out. Close and reopen Receive.');
          unawaited(stop());
        }
      });
      server.listen(
        (request) async {
          var completed = false;
          try {
            final address = request.connectionInfo?.remoteAddress.address ?? '';
            if (epoch != _epoch ||
                !privateIpv4(address) ||
                request.method != 'POST' ||
                request.uri.hasQuery ||
                request.headers.value('origin') != null ||
                used ||
                ++attempts > 20) {
              throw const FormatException();
            }
            if (request.uri.path == '/pair') {
              if (pairing || _cipher != null) throw const FormatException();
              pairing = true;
              NearbyCipher? candidate;
              try {
                final offer = NearbyOffer.fromJson(
                  await _readRequest(request, 2048),
                );
                candidate = await identity.pair(offer);
                _check(epoch);
                final fingerprint = await candidate.verification();
                status('Connection request from ${offer.senderName}');
                final accepted = await approve(
                  offer.senderName,
                  offer.count,
                  fingerprint,
                ).timeout(const Duration(seconds: 90), onTimeout: () => false);
                _check(epoch);
                if (!accepted) {
                  status('Waiting for a sender…');
                  throw const FormatException();
                }
                _cipher = candidate;
                candidate = null;
                peerAddress = address;
                await _respond(
                  request,
                  await _cipher!.seal('accept', {'accepted': true}),
                );
                status('Approved. Waiting for the selected items…');
              } finally {
                candidate?.destroy();
                pairing = false;
              }
            } else if (request.uri.path == '/items') {
              final cipher = _cipher;
              if (cipher == null || address != peerAddress) {
                throw const FormatException();
              }
              final frame = await _readRequestText(request, maxTransferBytes);
              final value = await cipher.open('items', frame);
              _check(epoch);
              checkFields(value, {'version', 'entries'});
              final raw = value['entries'];
              if (value['version'] != 2 ||
                  raw is! List ||
                  raw.length != cipher.offer.count ||
                  raw.length > maxItems) {
                throw const FormatException();
              }
              final entries = raw
                  .map((e) => VaultEntry.fromJson(e as Map<String, dynamic>))
                  .toList();
              if (entries.map((e) => e.id).toSet().length != entries.length) {
                throw const FormatException();
              }
              used = true;
              status('Importing ${entries.length} items…');
              final count = await import(entries);
              _check(epoch);
              await _respond(
                request,
                await cipher.seal('receipt', {'imported': count}),
              );
              completed = true;
              status('Received $count new items. Transfer complete.');
            } else {
              throw const FormatException();
            }
          } catch (_) {
            request.response.statusCode = HttpStatus.forbidden;
            if (used && epoch == _epoch) {
              status('Transfer stopped. Check the vault before retrying.');
            }
          } finally {
            try {
              await request.response.close();
            } catch (_) {}
            if ((completed || used) && epoch == _epoch) unawaited(stop());
          }
        },
        onError: (_) {
          if (epoch == _epoch) {
            status('Receiver stopped. Close and reopen Receive.');
            unawaited(stop());
          }
        },
      );
      status('Waiting for a sender…');
    } catch (_) {
      if (epoch == _epoch) await stop();
      rethrow;
    }
  }

  Future<int> send(
    NearbyDevice device,
    String name,
    List<VaultEntry> entries,
    NearbyApproval approve,
  ) async {
    await stop();
    final epoch = _epoch;
    await permission?.call();
    _check(epoch);
    final identity = await NearbyIdentity.create();
    if (epoch != _epoch) {
      identity.destroy();
      _check(epoch);
    }
    _identity = identity;
    try {
      final clean = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
      final offer = NearbyOffer(
        receiverId: device.id,
        receiverPublic: device.publicKey,
        senderId: identity.id,
        senderPublic: identity.publicKey,
        senderName: clean.isEmpty
            ? 'Spar Vault device'
            : clean.substring(0, clean.length > 80 ? 80 : clean.length),
        count: entries.length,
      );
      final cipher = await identity.pair(offer);
      if (epoch != _epoch) {
        cipher.destroy();
        _check(epoch);
      }
      _cipher = cipher;
      // Show the sender fingerprint immediately: the receiver can compare it
      // before approving its own prompt. Both approvals finish before items seal.
      final code = await cipher.verification();
      final decisions = await Future.wait<Object>([
        _post(
          device,
          '/pair',
          jsonEncode(offer.toJson()),
          8192,
        ).then((value) => cipher.open('accept', value)),
        approve(device.name, entries.length, code).then((accepted) {
          if (!accepted) {
            throw const FormatException(
              'Transfer cancelled. Reopen Receive on the other device.',
            );
          }
          return accepted;
        }),
      ], eagerError: true);
      _check(epoch);
      if ((decisions[0] as Map)['accepted'] != true || decisions[1] != true) {
        throw const FormatException(
          'Transfer cancelled. Reopen Receive on the other device.',
        );
      }
      _check(epoch);
      final frame = await cipher.seal('items', {
        'version': 2,
        'entries': entries.map((e) => e.toJson()).toList(),
      });
      _check(epoch);
      final receipt = await cipher.open(
        'receipt',
        await _post(device, '/items', frame, 8192),
      );
      _check(epoch);
      final count = receipt['imported'];
      if (count is! int || count < 0 || count > entries.length) {
        throw const FormatException('Invalid transfer receipt.');
      }
      return count;
    } finally {
      if (epoch == _epoch) await stop();
    }
  }

  Future<String> _post(
    NearbyDevice device,
    String path,
    String body,
    int responseLimit,
  ) async {
    final epoch = _epoch;
    final socket = await Socket.connect(
      device.host,
      device.port,
      timeout: const Duration(seconds: 10),
    );
    if (epoch != _epoch) {
      socket.destroy();
      _check(epoch);
    }
    _clients.add(socket);
    final encoded = Uint8List.fromList(utf8.encode(body)),
        builder = BytesBuilder();
    try {
      socket.write(
        'POST $path HTTP/1.0\r\nHost: ${device.host}\r\nContent-Type: application/json\r\nContent-Length: ${encoded.length}\r\nConnection: close\r\n\r\n',
      );
      socket.add(encoded);
      await socket.flush();
      await for (final chunk in socket.timeout(const Duration(seconds: 100))) {
        _check(epoch);
        if (builder.length + chunk.length > responseLimit + 8192) {
          throw const FormatException('Invalid transfer response.');
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      try {
        final response = utf8.decode(bytes), end = response.indexOf('\r\n\r\n');
        if (end < 0 ||
            end > 8192 ||
            !RegExp(r'^HTTP/1\.[01] 200 ').hasMatch(response)) {
          throw const FormatException(
            'Receiver declined or timed out. Reopen Receive and try again.',
          );
        }
        final result = response.substring(end + 4);
        if (utf8.encode(result).length > responseLimit) {
          throw const FormatException();
        }
        return result;
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
    } on SocketException {
      throw const FormatException(
        'Could not reach the receiver. Keep both apps open on the same Wi-Fi or hotspot.',
      );
    } finally {
      encoded.fillRange(0, encoded.length, 0);
      socket.destroy();
      _clients.remove(socket);
    }
  }

  Future<Map<String, dynamic>> _readRequest(
    HttpRequest request,
    int limit,
  ) async {
    final value = jsonDecode(await _readRequestText(request, limit));
    if (value is! Map<String, dynamic>) throw const FormatException();
    return value;
  }

  Future<String> _readRequestText(HttpRequest request, int limit) async {
    if (request.contentLength < 0 || request.contentLength > limit) {
      throw const FormatException();
    }
    final builder = BytesBuilder();
    await for (final chunk in request.timeout(const Duration(seconds: 20))) {
      if (builder.length + chunk.length > limit) throw const FormatException();
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    try {
      return utf8.decode(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<void> _respond(HttpRequest request, String body) async {
    final bytes = utf8.encode(body);
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('cache-control', 'no-store');
    request.response.contentLength = bytes.length;
    request.response.add(bytes);
  }

  Future<void> stop() async {
    _epoch++;
    _expiry?.cancel();
    _expiry = null;
    final cancel = _scanCancel;
    _scanCancel = null;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
    _udp?.close();
    _udp = null;
    for (final socket in _clients) {
      socket.destroy();
    }
    _clients.clear();
    _identity?.destroy();
    _identity = null;
    _cipher?.destroy();
    _cipher = null;
    final server = _server;
    _server = null;
    await Future.wait([
      if (server != null) server.close(force: true),
      if (nativeStop != null) nativeStop!().catchError((_) {}),
    ]);
  }
}
