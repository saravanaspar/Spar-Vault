import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:vault_core/vault_core.dart';

import '../features/files.dart';
import '../platform/integrations.dart';
import 'widgets.dart';
import 'app_picker.dart';

class EntryEditor extends StatefulWidget {
  const EntryEditor({
    super.key,
    this.entry,
    this.initialKind = EntryKind.login,
    required this.touch,
    required this.integrations,
  });
  final VaultEntry? entry;
  final EntryKind initialKind;
  final VoidCallback touch;
  final PlatformIntegrations integrations;
  @override
  State<EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<EntryEditor>
    with SingleTickerProviderStateMixin {
  late final TabController sections;
  final scroll = ScrollController();
  int section = 0;
  late final title = TextEditingController(text: widget.entry?.title),
      username = TextEditingController(text: widget.entry?.username),
      password = TextEditingController(text: widget.entry?.password),
      url = TextEditingController(text: widget.entry?.url),
      notes = TextEditingController(text: widget.entry?.notes),
      totp = TextEditingController(text: widget.entry?.totp),
      package = TextEditingController(text: widget.entry?.androidPackage);
  late EntryKind kind = widget.entry?.kind ?? widget.initialKind;
  String? appName;
  List<int> get sectionKinds => [
    0,
    if (kind == EntryKind.login) 1,
    2,
    3,
    if (widget.integrations.isAndroid && kind == EntryKind.login) 4,
  ];
  late bool favorite = widget.entry?.favorite ?? false;
  late List<VaultAttachment> attachments = [...?widget.entry?.attachments];
  late List<String> certs = [...?widget.entry?.androidCertificates];
  String? error;
  bool working = false;
  @override
  void initState() {
    super.initState();
    sections = TabController(length: sectionKinds.length, vsync: this)
      ..addListener(sectionChanged);
    if (widget.integrations.isAndroid &&
        kind == EntryKind.login &&
        package.text.isNotEmpty) {
      unawaited(loadAppName());
    }
  }

  Future<void> loadAppName() async {
    final requested = package.text;
    try {
      final apps = await widget.integrations.installedApps();
      if (!mounted || package.text != requested) return;
      final matches = apps.where((app) => app.package == requested);
      if (matches.isNotEmpty) setState(() => appName = matches.first.name);
    } catch (_) {
      /* A saved binding stays intact if the app is no longer visible. */
    }
  }

  void sectionChanged() {
    final next = sectionKinds[sections.index];
    if (section == next) return;
    FocusScope.of(context).unfocus();
    setState(() => section = next);
  }

  void showError(String message, int target) {
    setState(() => error = message);
    sections.index = sectionKinds.indexOf(target);
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  Widget field(
    TextEditingController c,
    String label, {
    bool secret = false,
    int lines = 1,
    IconData? prefixIcon,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: VField(
      controller: c,
      label: label,
      secret: secret,
      maxLines: lines,
      touch: widget.touch,
      prefixIcon: prefixIcon,
    ),
  );
  Future<void> attach() async {
    widget.touch();
    setState(() {
      working = true;
      error = null;
    });
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
              title: dialogTitle('Attachment filename', Icons.attach_file),
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
      if (mounted) showError(e.message, 3);
    } catch (_) {
      if (mounted) showError('Could not read the attachment.', 3);
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  void save() {
    widget.touch();
    if (title.text.trim().isEmpty) {
      showError('Enter a title for this item.', 0);
      return;
    }
    if (totp.text.trim().isNotEmpty) {
      try {
        final c = TotpConfig.parse(totp.text.trim());
        c.destroy();
      } on FormatException catch (e) {
        showError(e.message, 2);
        return;
      }
    }
    try {
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
      showError(
        e.message,
        e.message == 'Invalid Android package.' &&
                widget.integrations.isAndroid &&
                kind == EntryKind.login
            ? 4
            : section,
      );
    }
  }

  @override
  void dispose() {
    sections.removeListener(sectionChanged);
    sections.dispose();
    scroll.dispose();
    for (final c in [title, username, password, url, notes, totp, package]) {
      c.clear();
      c.dispose();
    }
    attachments = [];
    certs = [];
    super.dispose();
  }

  Future<void> chooseApp() async {
    widget.touch();
    final app = await showDialog<InstalledApp>(
      context: context,
      builder: (_) =>
          AppPicker(integrations: widget.integrations, touch: widget.touch),
    );
    if (app == null || !mounted) return;
    setState(() {
      working = true;
      error = null;
    });
    try {
      final values = await widget.integrations.certificates(app.package);
      if (values.isEmpty) {
        throw const FormatException('Could not verify this installed app.');
      }
      if (!mounted) return;
      setState(() {
        package.text = app.package;
        appName = app.name;
        certs = values;
      });
    } catch (_) {
      if (mounted) {
        showError(
          'Could not verify this app. Check that it is still installed and try again.',
          4,
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> scanTotp(bool image) async {
    widget.touch();
    setState(() {
      working = true;
      error = null;
    });
    try {
      final values = await widget.integrations.scanTotpQr(image: image);
      if (!mounted || values == null) return;
      final accounts = values
          .expand((v) => AuthenticatorImport.parse(v).accounts)
          .toList();
      if (accounts.length != 1) {
        throw const FormatException(
          'For multiple accounts, use Codes → Import from Google Authenticator.',
        );
      }
      setState(() => totp.text = accounts.single.uri);
    } on FormatException catch (e) {
      if (mounted) showError(e.message, 2);
    } catch (_) {
      if (mounted) {
        showError(
          'Could not scan the QR. Allow camera access or choose a clear QR image.',
          2,
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  List<Widget> sectionFields() => switch (section) {
    0 => [
      field(title, 'Title', prefixIcon: Icons.label_outline),
      if (kind == EntryKind.login) ...[
        field(username, 'Email / username', prefixIcon: Icons.person_outline),
        field(
          password,
          'Password',
          secret: true,
          prefixIcon: Icons.lock_outline,
        ),
        TextButton.icon(
          onPressed: () {
            password.text = generatePassword();
            widget.touch();
          },
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Generate 24-character password'),
        ),
        const SizedBox(height: 8),
        field(
          url,
          'Website URL (HTTPS for autofill)',
          prefixIcon: Icons.language,
        ),
      ] else
        field(notes, 'Secure note', lines: 5),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: favorite,
        onChanged: (value) {
          widget.touch();
          setState(() => favorite = value ?? false);
        },
        title: const Text('Favorite'),
        secondary: Icon(
          favorite ? Icons.star_rounded : Icons.star_outline_rounded,
          color: favorite ? accent : dimText,
        ),
      ),
    ],
    1 => [field(notes, 'Extra notes', lines: 5)],
    2 => [
      const InfoBox(
        text: 'Scan an authenticator QR, choose its image, or enter a Base32 secret / otpauth URI. For a Google export with multiple accounts, use Codes → Import from Google Authenticator.',
      ),
      const SizedBox(height: 16),
      if (widget.integrations.isAndroid)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: working ? null : () => scanTotp(false),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR'),
            ),
            OutlinedButton.icon(
              onPressed: working ? null : () => scanTotp(true),
              icon: const Icon(Icons.image_outlined),
              label: const Text('Choose QR image'),
            ),
          ],
        ),
      const SizedBox(height: 12),
      field(totp, 'TOTP secret / otpauth URI', secret: true),
    ],
    3 => [
      const InfoBox(
        text: 'Maximum 2 MiB per file, ten files per item, 8 MiB total per vault. Saved attachments leave the encrypted vault.',
      ),
      const SizedBox(height: 12),
      ...attachments.map(
        (attachment) => ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            attachment.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${attachment.byteLength} bytes',
            style: const TextStyle(color: dimText, fontSize: 12),
          ),
          trailing: IconButton(
            tooltip: 'Remove attachment',
            onPressed: () {
              widget.touch();
              setState(() => attachments.remove(attachment));
            },
            icon: const Icon(Icons.delete_outline, color: dangerColor),
          ),
        ),
      ),
      TextButton.icon(
        onPressed: working ? null : attach,
        icon: const Icon(Icons.attach_file),
        label: Text(working ? 'Reading attachment…' : 'Add attachment'),
      ),
    ],
    _ => [
      const InfoBox(
        text: 'Optional Android autofill binding for an installed app.',
      ),
      const SizedBox(height: 16),
      if (package.text.isNotEmpty)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.android),
          title: Text(appName ?? 'Selected Android app'),
          subtitle: Text(
            appName == null
                ? 'Previously saved app binding'
                : 'Verified installed app',
          ),
          trailing: IconButton(
            tooltip: 'Remove app binding',
            onPressed: working
                ? null
                : () => setState(() {
                    package.clear();
                    appName = null;
                    certs = [];
                  }),
            icon: const Icon(Icons.close),
          ),
        ),
      OutlinedButton.icon(
        onPressed: working ? null : chooseApp,
        icon: const Icon(Icons.apps),
        label: Text(working ? 'Verifying app…' : 'Choose installed app'),
      ),
      const SizedBox(height: 8),
      Text(
        certs.isEmpty
            ? 'Choose an app to use this login with Android autofill.'
            : 'App verified. This login can be used for autofill.',
        style: TextStyle(
          color: certs.isEmpty ? dimText : successColor,
          fontSize: 13,
        ),
      ),
    ],
  };

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620, maxHeight: 680),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final header = Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: dialogTitle(
              widget.entry == null
                  ? (kind == EntryKind.note ? 'Add secure note' : 'Add login')
                  : 'Edit item',
              widget.entry == null
                  ? Icons.add_circle_outline
                  : Icons.edit_outlined,
            ),
          );
          final tabs = TabBar(
            controller: sections,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: accent,
            unselectedLabelColor: dimText,
            indicatorColor: accent,
            onTap: (_) => widget.touch(),
            tabs: [
              Tab(text: kind == EntryKind.login ? 'Login' : 'Note'),
              if (kind == EntryKind.login) const Tab(text: 'Extra notes'),
              const Tab(text: '2FA'),
              Tab(text: 'Files (${attachments.length})'),
              if (widget.integrations.isAndroid && kind == EntryKind.login)
                const Tab(text: 'Autofill'),
            ],
          );
          final content = Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (error != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: dangerColor.withAlpha(20),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: dangerColor.withAlpha(50)),
                    ),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Color(0xFFFFB4AB)),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                ...sectionFields(),
              ],
            ),
          );
          final actions = Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              overflowSpacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: working ? null : save,
                  child: const Text('Save item'),
                ),
              ],
            ),
          );
          // On short screens or with a large keyboard, let the entire dialog
          // scroll so that the tabs and Save button remain reachable.
          if (constraints.maxHeight < 360 ||
              MediaQuery.textScalerOf(context).scale(14) > 21) {
            return SingleChildScrollView(
              controller: scroll,
              primary: false,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [header, tabs, content, actions],
              ),
            );
          }
          return Column(
            children: [
              header,
              tabs,
              Expanded(
                child: SingleChildScrollView(
                  key: ValueKey(section),
                  controller: scroll,
                  primary: false,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  child: content,
                ),
              ),
              actions,
            ],
          );
        },
      ),
    ),
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

  Widget copyRow(String label, String text, {bool secret = false}) => Container(
    margin: const EdgeInsets.only(bottom: 2),
    child: ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          color: dimText,
          letterSpacing: 0.5,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          secret && !revealed ? '••••••••••••' : text,
          style: const TextStyle(fontSize: 15),
        ),
      ),
      trailing: Wrap(
        children: [
          if (secret)
            IconButton(
              tooltip: revealed ? 'Hide password' : 'Reveal for 20 seconds',
              onPressed: reveal,
              icon: Icon(
                revealed ? Icons.visibility_off : Icons.visibility,
                color: dimText,
              ),
            ),
          IconButton(
            tooltip: 'Copy $label',
            onPressed: () => widget.copy(text),
            icon: const Icon(Icons.copy),
          ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    return AlertDialog(
      title: dialogTitle(
        e.title,
        e.kind == EntryKind.note ? Icons.notes_outlined : Icons.key_outlined,
        color: e.kind == EntryKind.note ? noteColor : accent,
      ),
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
              if (e.totp.isNotEmpty) ...[
                const SizedBox(height: 8),
                OtpCard(entry: e, copy: widget.copy),
              ],
              if (e.attachments.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      'Attachments',
                      style: TextStyle(
                        fontSize: 12,
                        color: dimText,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: surface,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'exporting saves plaintext',
                        style: TextStyle(fontSize: 11, color: dimText),
                      ),
                    ),
                  ],
                ),
                ...e.attachments.map(
                  (a) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(a.name),
                    subtitle: Text(
                      '${a.byteLength} bytes',
                      style: const TextStyle(color: dimText, fontSize: 12),
                    ),
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
                  leading: const Icon(Icons.history, size: 20, color: dimText),
                  onExpansionChanged: (v) => setState(() => history = v),
                  children: history
                      ? e.history
                            .map(
                              (v) => ListTile(
                                title: Text(
                                  v.changedAt.toLocal().toString(),
                                  style: const TextStyle(fontSize: 13),
                                ),
                                subtitle: const Text(
                                  'Previous password • copy only',
                                  style: TextStyle(
                                    color: dimText,
                                    fontSize: 12,
                                  ),
                                ),
                                trailing: IconButton(
                                  tooltip: 'Copy previous password',
                                  onPressed: () => widget.copy(v.password),
                                  icon: const Icon(Icons.copy, size: 18),
                                ),
                              ),
                            )
                            .toList()
                      : [],
                ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Updated ${e.updatedAt.toLocal()}',
                  style: const TextStyle(fontSize: 12, color: dimText),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: widget.remove,
          child: const Text('Delete', style: TextStyle(color: dangerColor)),
        ),
        TextButton(onPressed: widget.edit, child: const Text('Edit')),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
