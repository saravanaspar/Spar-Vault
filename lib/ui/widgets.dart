import 'dart:async';

import '../features/files.dart';

import 'package:flutter/material.dart';
import 'package:vault_core/vault_core.dart';

import '../app/vault_controller.dart';

class VField extends StatelessWidget {
  const VField({
    super.key,
    required this.controller,
    required this.label,
    required this.touch,
    this.secret = false,
    this.maxLines = 1,
    this.onChanged,
    this.onSubmitted,
  });
  final TextEditingController controller;
  final String label;
  final VoidCallback touch;
  final bool secret;
  final int maxLines;
  final ValueChanged<String>? onChanged, onSubmitted;
  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    decoration: InputDecoration(labelText: label),
    obscureText: secret,
    maxLines: secret ? 1 : maxLines,
    autocorrect: false,
    enableSuggestions: false,
    enableIMEPersonalizedLearning: false,
    onChanged: (s) {
      touch();
      onChanged?.call(s);
    },
    onSubmitted: onSubmitted,
  );
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    ),
  );
}

class UnlockChoice {
  const UnlockChoice(this.value, this.usePassword);
  final String value;
  final bool usePassword;
}

class TransferCodeDialog extends StatefulWidget {
  const TransferCodeDialog({super.key, required this.touch});
  final VoidCallback touch;
  @override
  State<TransferCodeDialog> createState() => _TransferCodeDialogState();
}

class _TransferCodeDialogState extends State<TransferCodeDialog> {
  final input = TextEditingController();
  @override
  void dispose() {
    input.clear();
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Receive transfer'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Paste the full private code from the sending device. For a file transfer, you will choose its encrypted .svx file next.',
            ),
            const SizedBox(height: 16),
            VField(
              controller: input,
              label: 'Full private transfer code',
              touch: widget.touch,
              maxLines: 4,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, input.text.trim()),
        child: const Text('Continue'),
      ),
    ],
  );
}

class BackupCredentials extends StatefulWidget {
  const BackupCredentials({
    super.key,
    required this.bundle,
    required this.touch,
  });
  final VaultBundle bundle;
  final VoidCallback touch;
  @override
  State<BackupCredentials> createState() => _BackupCredentialsState();
}

class _BackupCredentialsState extends State<BackupCredentials> {
  final input = TextEditingController();
  late bool password = widget.bundle.passwordSlot != null;
  String? error;
  @override
  void dispose() {
    input.clear();
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Unlock selected backup'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Choose the credentials that were active when this backup was exported. A key file contains the key, not the vault data.',
          ),
          const SizedBox(height: 16),
          if (widget.bundle.passwordSlot != null)
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Password')),
                ButtonSegment(value: false, label: Text('Secure key')),
              ],
              selected: {password},
              onSelectionChanged: (v) {
                input.clear();
                setState(() => password = v.first);
              },
            ),
          const SizedBox(height: 16),
          VField(
            controller: input,
            label: password ? 'Backup unlock password' : 'Backup secure key',
            secret: true,
            touch: widget.touch,
          ),
          if (!password)
            TextButton.icon(
              icon: const Icon(Icons.upload_file),
              label: const Text('Import master-key .txt file'),
              onPressed: () async {
                try {
                  final key = await pickMasterKey();
                  if (key == null) return;
                  try {
                    if (mounted) {
                      input.text = key.display();
                      widget.touch();
                    }
                  } finally {
                    key.destroy();
                  }
                } catch (_) {
                  if (mounted) {
                    setState(
                      () => error = 'Could not read a complete master key from that file.',
                    );
                  }
                }
              },
            ),
          if (error != null) Text(error!),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, UnlockChoice(input.text, password)),
        child: const Text('Verify credentials'),
      ),
    ],
  );
}

class MergeChoice {
  const MergeChoice(this.conflicts, this.deletions);
  final bool conflicts, deletions;
}

class MergeDialog extends StatefulWidget {
  const MergeDialog({super.key, required this.preview});
  final MergePreview preview;
  @override
  State<MergeDialog> createState() => _MergeDialogState();
}

class _MergeDialogState extends State<MergeDialog> {
  bool conflicts = false, deletions = false;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Review incoming changes'),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Additions: ${widget.preview.additions.length}\n${widget.preview.additions.take(20).join(', ')}',
            ),
            const SizedBox(height: 12),
            Text(
              'Conflicts: ${widget.preview.conflicts.length}\n${widget.preview.conflicts.take(20).join(', ')}',
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: conflicts,
              onChanged: (v) => setState(() => conflicts = v ?? false),
              title: const Text('Use incoming values for conflicts'),
              subtitle: const Text(
                'Off keeps local values, including local deletions.',
              ),
            ),
            Text(
              'Incoming deletions: ${widget.preview.deletions.length}\n${widget.preview.deletions.take(20).join(', ')}',
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: deletions,
              onChanged: (v) => setState(() => deletions = v ?? false),
              title: const Text('Apply incoming deletions'),
            ),
            const Text(
              'Local password unlock and integration settings are retained. This is a manual merge of a snapshot, not continuous synchronization.',
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, MergeChoice(conflicts, deletions)),
        child: const Text('Merge selected changes'),
      ),
    ],
  );
}

class OtpCard extends StatefulWidget {
  const OtpCard({super.key, required this.entry, required this.copy});
  final VaultEntry entry;
  final Future<void> Function(String) copy;
  @override
  State<OtpCard> createState() => _OtpCardState();
}

class _OtpCardState extends State<OtpCard> {
  TotpConfig? config;
  Timer? timer;
  String code = '••••••';
  int remaining = 0;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    try {
      config = TotpConfig.parse(widget.entry.totp);
      unawaited(_tick());
      timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_tick()),
      );
    } catch (_) {
      code = 'Invalid secret';
    }
  }

  Future<void> _tick() async {
    final c = config;
    if (c == null) return;
    final epoch = ++generation;
    final value = await c.code(DateTime.now());
    if (mounted && generation == epoch) {
      setState(() {
        code = value;
        remaining = c.remaining(DateTime.now());
      });
    }
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    config?.destroy();
    code = '';
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      title: Text(widget.entry.title),
      subtitle: Text(
        '$code • ${remaining}s',
        style: const TextStyle(fontFamily: 'LocalMono', fontSize: 20),
      ),
      trailing: IconButton(
        tooltip: 'Copy authenticator code',
        onPressed: config == null ? null : () => widget.copy(code),
        icon: const Icon(Icons.copy),
      ),
    ),
  );
}
