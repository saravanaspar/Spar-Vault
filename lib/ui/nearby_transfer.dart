import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vault_core/vault_core.dart';

import '../platform/nearby.dart';
import 'widgets.dart';

Future<bool> confirmNearby(
  BuildContext context,
  String name,
  int count,
  String code,
  VoidCallback touch,
) async {
  if (!context.mounted) return false;
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _NearbyConfirmation(
          name: name,
          count: count,
          code: code,
          touch: touch,
        ),
      ) ??
      false;
}

class _NearbyConfirmation extends StatefulWidget {
  const _NearbyConfirmation({
    required this.name,
    required this.count,
    required this.code,
    required this.touch,
  });
  final String name, code;
  final int count;
  final VoidCallback touch;
  @override
  State<_NearbyConfirmation> createState() => _NearbyConfirmationState();
}

class _NearbyConfirmationState extends State<_NearbyConfirmation> {
  Timer? timeout;
  @override
  void initState() {
    super.initState();
    timeout = Timer(const Duration(seconds: 80), () {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context, false);
      }
    });
  }

  @override
  void dispose() {
    timeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Confirm the nearby device'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${widget.name} • ${widget.count} items'),
          const SizedBox(height: 16),
          const Text(
            'Check that both screens show this same number. No typing is needed.',
          ),
          const SizedBox(height: 12),
          Text(
            widget.code,
            style: const TextStyle(
              fontFamily: 'LocalMono',
              color: accent,
              fontSize: 32,
              letterSpacing: 5,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Continue only when the number matches on the device you chose.',
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          widget.touch();
          Navigator.pop(context, false);
        },
        child: const Text('Reject'),
      ),
      FilledButton(
        onPressed: () {
          widget.touch();
          Navigator.pop(context, true);
        },
        child: const Text('Numbers match'),
      ),
    ],
  );
}

class NearbySendDialog extends StatefulWidget {
  const NearbySendDialog({
    super.key,
    required this.transfer,
    required this.name,
    required this.entries,
    required this.touch,
  });
  final NearbyTransfer transfer;
  final String name;
  final List<VaultEntry> entries;
  final VoidCallback touch;
  @override
  State<NearbySendDialog> createState() => _NearbySendDialogState();
}

class _NearbySendDialogState extends State<NearbySendDialog> {
  late final selected = widget.entries.map((e) => e.id).toSet();
  List<NearbyDevice> devices = [];
  bool searching = true, sending = false;
  String? error, result;
  DialogRoute<bool>? prompt;
  NavigatorState? promptNavigator;
  Future<bool> approval(String name, int count, String code) async {
    if (!mounted) return false;
    final navigator = Navigator.of(context);
    final route = DialogRoute<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _NearbyConfirmation(
        name: name,
        count: count,
        code: code,
        touch: widget.touch,
      ),
    );
    prompt = route;
    promptNavigator = navigator;
    try {
      return await navigator.push(route) ?? false;
    } finally {
      if (identical(prompt, route)) {
        prompt = null;
        promptNavigator = null;
      }
    }
  }

  void closePrompt() {
    final route = prompt, navigator = promptNavigator;
    prompt = null;
    promptNavigator = null;
    if (route != null && route.isActive && navigator?.mounted == true) {
      navigator!.removeRoute(route, false);
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(search());
  }

  Future<void> search() async {
    setState(() {
      searching = true;
      error = null;
      devices = [];
    });
    try {
      final found = await widget.transfer.discover();
      if (mounted) setState(() => devices = found);
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not search for receivers. Check Wi-Fi and local network permission.',
        );
      }
    } finally {
      if (mounted) setState(() => searching = false);
    }
  }

  Future<void> send(NearbyDevice device) async {
    widget.touch();
    setState(() {
      sending = true;
      error = null;
      result = null;
    });
    try {
      final count = await widget.transfer.send(
        device,
        widget.name,
        widget.entries.where((e) => selected.contains(e.id)).toList(),
        approval,
      );
      if (mounted) {
        setState(() {
          result =
              'Sent successfully. $count new items imported on ${device.name}.';
          devices = [];
        });
      }
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Transfer stopped. Check the receiver before retrying.',
        );
      }
    } finally {
      closePrompt();
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  void dispose() {
    unawaited(widget.transfer.stop());
    selected.clear();
    devices.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _TransferFrame(
    title: 'Send to nearby device',
    close: sending ? 'Cancel transfer' : 'Close',
    children: [
      const InfoBox(
        text: 'On the other device, unlock Spar Vault and open Backups → Receive. Keep both apps open on the same Wi-Fi or hotspot.',
      ),
      const SizedBox(height: 12),
      if (sending) ...[
        const LinearProgressIndicator(),
        const SizedBox(height: 12),
        const Text('Connecting… Confirm the matching number on both devices.'),
      ],
      if (error != null)
        Text(error!, style: const TextStyle(color: Color(0xFFFFB4AB))),
      if (result != null)
        Text(result!, style: const TextStyle(color: successColor)),
      Wrap(
        spacing: 8,
        children: [
          TextButton(
            onPressed: sending
                ? null
                : () {
                    widget.touch();
                    setState(
                      () => selected.addAll(widget.entries.map((e) => e.id)),
                    );
                  },
            child: const Text('Select all'),
          ),
          TextButton(
            onPressed: sending
                ? null
                : () {
                    widget.touch();
                    setState(selected.clear);
                  },
            child: const Text('Select none'),
          ),
        ],
      ),
      Text(
        '${selected.length} of ${widget.entries.length} items selected',
        style: const TextStyle(color: accent),
      ),
      ...widget.entries.map(
        (e) => CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          value: selected.contains(e.id),
          onChanged: sending
              ? null
              : (v) {
                  widget.touch();
                  setState(() {
                    if (v == true) {
                      selected.add(e.id);
                    } else {
                      selected.remove(e.id);
                    }
                  });
                },
        ),
      ),
      const Divider(),
      Row(
        children: [
          const Expanded(
            child: Text(
              'Nearby receivers',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: 'Search again',
            onPressed: sending || searching
                ? null
                : () {
                    widget.touch();
                    unawaited(search());
                  },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      if (searching) const LinearProgressIndicator(),
      if (!searching && devices.isEmpty && result == null)
        const Text(
          'No receivers found. Open Receive on the other device, then search again. Wi-Fi guest networks may prevent devices from finding each other.',
        ),
      ...devices.map(
        (d) => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.phonelink, color: accent),
          title: Text(d.name),
          subtitle: const Text('Ready to receive'),
          trailing: FilledButton(
            onPressed: sending || searching || selected.isEmpty
                ? null
                : () => send(d),
            child: const Text('Send'),
          ),
        ),
      ),
    ],
  );
}

class NearbyReceiveDialog extends StatefulWidget {
  const NearbyReceiveDialog({
    super.key,
    required this.transfer,
    required this.name,
    required this.import,
    required this.touch,
  });
  final NearbyTransfer transfer;
  final String name;
  final NearbyImport import;
  final VoidCallback touch;
  @override
  State<NearbyReceiveDialog> createState() => _NearbyReceiveDialogState();
}

class _NearbyReceiveDialogState extends State<NearbyReceiveDialog> {
  String status = 'Starting receiver…';
  bool starting = true;
  String? error;
  @override
  void initState() {
    super.initState();
    unawaited(start());
  }

  Future<void> start() async {
    try {
      await widget.transfer.receive(
        name: widget.name,
        approve: (name, count, code) =>
            confirmNearby(context, name, count, code, widget.touch),
        import: (entries) {
          widget.touch();
          return widget.import(entries);
        },
        status: (value) {
          if (mounted) setState(() => status = value);
        },
      );
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not start the receiver. Check Wi-Fi and local network permission.',
        );
      }
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  @override
  void dispose() {
    unawaited(widget.transfer.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _TransferFrame(
    title: 'Receive from nearby device',
    close: 'Close receiver',
    children: [
      const SizedBox(height: 24),
      const Center(child: Icon(Icons.wifi_tethering, size: 80, color: accent)),
      const SizedBox(height: 20),
      Center(
        child: Text(
          widget.name,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
      ),
      const SizedBox(height: 16),
      Text(
        status,
        textAlign: TextAlign.center,
        style: const TextStyle(color: accent),
      ),
      if (starting) const LinearProgressIndicator(),
      if (error != null)
        Text(error!, style: const TextStyle(color: Color(0xFFFFB4AB))),
      const SizedBox(height: 20),
      const InfoBox(
        text: 'This device is visible while this screen is open, for up to five minutes. On the sender, select items and tap this device. Confirm the matching number on both screens. Received items are encrypted with this vault’s own key; existing items are kept.',
      ),
      const SizedBox(height: 12),
      const Text(
        'Keep both devices on the same Wi-Fi or hotspot and both apps open.',
      ),
    ],
  );
}

class _TransferFrame extends StatelessWidget {
  const _TransferFrame({
    required this.title,
    required this.children,
    required this.close,
  });
  final String title, close;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: dialogTitle(title, Icons.sync_alt),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: children,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(close),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
