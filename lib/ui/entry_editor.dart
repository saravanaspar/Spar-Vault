import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:vault_core/vault_core.dart';

import '../features/files.dart';
import '../platform/integrations.dart';
import 'widgets.dart';

class EntryEditor extends StatefulWidget {
  const EntryEditor({
    super.key,
    this.entry,
    required this.touch,
    required this.integrations,
  });
  final VaultEntry? entry;
  final VoidCallback touch;
  final PlatformIntegrations integrations;
  @override
  State<EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<EntryEditor> {
  late final title = TextEditingController(text: widget.entry?.title),
      username = TextEditingController(text: widget.entry?.username),
      password = TextEditingController(text: widget.entry?.password),
      url = TextEditingController(text: widget.entry?.url),
      notes = TextEditingController(text: widget.entry?.notes),
      totp = TextEditingController(text: widget.entry?.totp),
      package = TextEditingController(text: widget.entry?.androidPackage);
  late EntryKind kind = widget.entry?.kind ?? EntryKind.login;
  late bool favorite = widget.entry?.favorite ?? false;
  late List<VaultAttachment> attachments = [...?widget.entry?.attachments];
  late List<String> certs = [...?widget.entry?.androidCertificates];
  String? error;
  bool working = false;
  Widget field(
    TextEditingController c,
    String label, {
    bool secret = false,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: VField(
      controller: c,
      label: label,
      secret: secret,
      maxLines: lines,
      touch: widget.touch,
    ),
  );
  Future<void> attach() async {
    setState(() => working = true);
    try {
      if (attachments.length >= 10) {
        throw const FormatException('Maximum ten attachments per item.');
      }
      final name = TextEditingController();
      try {
        final bytes = await pickBytes(
          limit: maxAttachmentBytes,
          title: 'Choose attachment (maximum 2 MiB)',
        );
        if (bytes == null || !mounted) return;
        try {
          final n = await showDialog<String>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Attachment filename'),
              content: VField(
                controller: name,
                label: 'Filename to save later',
                touch: widget.touch,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, name.text.trim()),
                  child: const Text('Attach'),
                ),
              ],
            ),
          );
          if (n == null || !mounted) return;
          final a = VaultAttachment(
            id: randomId(),
            name: n,
            base64Bytes: base64Encode(bytes),
          );
          setState(() => attachments.add(a));
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      } finally {
        name.dispose();
      }
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = 'Could not read the attachment.');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  void save() {
    try {
      if (totp.text.trim().isNotEmpty) {
        final c = TotpConfig.parse(totp.text.trim());
        c.destroy();
      }
      final binding = package.text.trim();
      final old = widget.entry;
      final value = VaultEntry(
        id: old?.id ?? randomId(),
        title: title.text.trim(),
        username: username.text,
        password: password.text,
        url: url.text.trim(),
        notes: notes.text,
        totp: totp.text.trim(),
        favorite: favorite,
        kind: kind,
        updatedAt: DateTime.now().toUtc(),
        history: old?.history ?? [],
        attachments: attachments,
        androidPackage: binding,
        androidCertificates: certs,
      );
      Navigator.pop(context, value);
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  void dispose() {
    for (final c in [title, username, password, url, notes, totp, package]) {
      c.clear();
      c.dispose();
    }
    attachments = [];
    certs = [];
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.entry == null ? 'Add item' : 'Edit item'),
    content: SizedBox(
      width: 580,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            field(title, 'Title'),
            SegmentedButton<EntryKind>(
              segments: const [
                ButtonSegment(value: EntryKind.login, label: Text('Login')),
                ButtonSegment(
                  value: EntryKind.note,
                  label: Text('Secure note'),
                ),
              ],
              selected: {kind},
              onSelectionChanged: (v) => setState(() => kind = v.first),
            ),
            const SizedBox(height: 16),
            if (kind == EntryKind.login)
              ExpansionTile(
                initiallyExpanded: true,
                title: const Text('Credentials'),
                children: [
                  field(username, 'Email / username'),
                  field(password, 'Password', secret: true),
                  TextButton.icon(
                    onPressed: () {
                      password.text = generatePassword();
                      widget.touch();
                    },
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text('Generate 24-character password'),
                  ),
                  field(url, 'Website URL (HTTPS for autofill)'),
                ],
              ),
            ExpansionTile(
              initiallyExpanded: kind == EntryKind.note,
              title: const Text('Notes'),
              children: [field(notes, 'Secure notes', lines: 5)],
            ),
            ExpansionTile(
              title: const Text('Authenticator'),
              subtitle: Text(
                totp.text.isEmpty ? 'Optional offline TOTP' : 'TOTP configured',
              ),
              children: [
                const Text(
                  'Store a Base32 secret or otpauth://totp URI. This app does not scan QR codes in this release.',
                ),
                const SizedBox(height: 12),
                field(totp, 'TOTP secret / otpauth URI', secret: true),
              ],
            ),
            ExpansionTile(
              title: Text('Encrypted attachments (${attachments.length})'),
              children: [
                const Text(
                  'Maximum 2 MiB per file, ten files per item, 8 MiB total per vault. Saved attachments leave the encrypted vault.',
                ),
                ...attachments.map(
                  (a) => ListTile(
                    title: Text(a.name),
                    subtitle: Text('${a.byteLength} bytes'),
                    trailing: IconButton(
                      tooltip: 'Remove attachment',
                      onPressed: () => setState(() => attachments.remove(a)),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: working ? null : attach,
                  icon: const Icon(Icons.attach_file),
                  label: const Text('Add attachment'),
                ),
              ],
            ),
            if (widget.integrations.isAndroid)
              ExpansionTile(
                title: const Text('Android app binding'),
                children: [
                  VField(
                    controller: package,
                    label: 'Installed app package, e.g. com.example.app',
                    touch: widget.touch,
                    onChanged: (_) => setState(() => certs = []),
                  ),
                  TextButton(
                    onPressed: () async {
                      try {
                        final v = await widget.integrations.certificates(
                          package.text.trim(),
                        );
                        if (v.isEmpty) throw const FormatException();
                        if (mounted) setState(() => certs = v);
                      } catch (_) {
                        if (mounted) {
                          setState(
                            () => error = 'Install the app and enter its exact Android package.',
                          );
                        }
                      }
                    },
                    child: const Text('Bind installed signing certificates'),
                  ),
                  Text(
                    certs.isEmpty
                        ? 'No trusted app bound. Native app autofill will be refused.'
                        : '${certs.length} certificate(s) pinned for this app.',
                  ),
                ],
              ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: favorite,
              onChanged: (v) => setState(() => favorite = v ?? false),
              title: const Text('Favorite'),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.orange)),
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
        onPressed: working ? null : save,
        child: const Text('Save item'),
      ),
    ],
  );
}

class EntryDetails extends StatefulWidget {
  const EntryDetails({
    super.key,
    required this.entry,
    required this.touch,
    required this.copy,
    required this.save,
    required this.edit,
    required this.remove,
  });
  final VaultEntry entry;
  final VoidCallback touch, edit;
  final Future<void> Function(String) copy;
  final Future<void> Function(VaultAttachment) save;
  final Future<void> Function() remove;
  @override
  State<EntryDetails> createState() => _EntryDetailsState();
}

class _EntryDetailsState extends State<EntryDetails> {
  bool revealed = false, history = false;
  Timer? timer;
  void reveal() {
    widget.touch();
    setState(() => revealed = !revealed);
    timer?.cancel();
    if (revealed) {
      timer = Timer(const Duration(seconds: 20), () {
        if (mounted) setState(() => revealed = false);
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Widget copyRow(String label, String text, {bool secret = false}) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    subtitle: Text(secret && !revealed ? '••••••••••••' : text),
    trailing: Wrap(
      children: [
        if (secret)
          IconButton(
            tooltip: revealed ? 'Hide password' : 'Reveal for 20 seconds',
            onPressed: reveal,
            icon: Icon(revealed ? Icons.visibility_off : Icons.visibility),
          ),
        IconButton(
          tooltip: 'Copy $label',
          onPressed: () => widget.copy(text),
          icon: const Icon(Icons.copy),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    return AlertDialog(
      title: Text(e.title),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (e.username.isNotEmpty) copyRow('Username', e.username),
              if (e.password.isNotEmpty)
                copyRow('Password', e.password, secret: true),
              if (e.url.isNotEmpty) copyRow('Website', e.url),
              if (e.notes.isNotEmpty) copyRow('Notes', e.notes),
              if (e.totp.isNotEmpty) OtpCard(entry: e, copy: widget.copy),
              if (e.attachments.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Attachments • exporting saves plaintext'),
                ...e.attachments.map(
                  (a) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(a.name),
                    subtitle: Text('${a.byteLength} bytes'),
                    trailing: IconButton(
                      tooltip: 'Save attachment',
                      onPressed: () => widget.save(a),
                      icon: const Icon(Icons.download),
                    ),
                  ),
                ),
              ],
              if (e.history.isNotEmpty)
                ExpansionTile(
                  title: Text('Password history (${e.history.length})'),
                  onExpansionChanged: (v) => setState(() => history = v),
                  children: history
                      ? e.history
                            .map(
                              (v) => ListTile(
                                title: Text(v.changedAt.toLocal().toString()),
                                subtitle: const Text(
                                  'Previous password • copy only',
                                ),
                                trailing: IconButton(
                                  tooltip: 'Copy previous password',
                                  onPressed: () => widget.copy(v.password),
                                  icon: const Icon(Icons.copy),
                                ),
                              ),
                            )
                            .toList()
                      : [],
                ),
              const SizedBox(height: 12),
              Text(
                'Updated ${e.updatedAt.toLocal()}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: widget.remove, child: const Text('Delete')),
        TextButton(onPressed: widget.edit, child: const Text('Edit')),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
