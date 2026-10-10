import 'package:flutter/material.dart';
import 'package:vault_core/vault_core.dart';

import '../platform/integrations.dart';
import 'widgets.dart';

class AuthenticatorImportDialog extends StatefulWidget {
  const AuthenticatorImportDialog({
    super.key,
    required this.integrations,
    required this.touch,
  });
  final PlatformIntegrations integrations;
  final VoidCallback touch;
  @override
  State<AuthenticatorImportDialog> createState() =>
      _AuthenticatorImportDialogState();
}

class _AuthenticatorImportDialogState extends State<AuthenticatorImportDialog> {
  final input = TextEditingController();
  final accounts = <AuthenticatorAccount>[];
  final selected = <String>{};
  final pages = <int, String>{};
  int? batchId;
  int batchSize = 1;
  bool scanning = false;
  String? error;
  void add(String value) {
    final parsed = AuthenticatorImport.parse(value);
    final existing = accounts
        .map((account) => totpIdentity(account.uri))
        .toSet();
    final additions = <AuthenticatorAccount>[];
    for (final account in parsed.accounts) {
      if (existing.add(totpIdentity(account.uri))) additions.add(account);
    }
    if (accounts.length + additions.length > maxItems) {
      throw const FormatException('Too many authenticator accounts.');
    }
    if (parsed.batchId != null) {
      if (batchId != null &&
          (batchId != parsed.batchId || batchSize != parsed.batchSize)) {
        throw const FormatException(
          'Scan the remaining QR pages from the same Google export. Start a new import for another export.',
        );
      }
      final fingerprint = parsed.accounts
          .map((account) => totpIdentity(account.uri))
          .join('|');
      if (pages.containsKey(parsed.batchIndex) &&
          pages[parsed.batchIndex] != fingerprint) {
        throw const FormatException(
          'This QR page does not match the earlier scan.',
        );
      }
      batchId = parsed.batchId;
      batchSize = parsed.batchSize;
      pages[parsed.batchIndex] = fingerprint;
    }
    accounts.addAll(additions);
    selected.addAll(additions.map((account) => totpIdentity(account.uri)));
  }

  Future<void> scan(bool image) async {
    widget.touch();
    setState(() {
      scanning = true;
      error = null;
    });
    try {
      final values = await widget.integrations.scanTotpQr(image: image);
      if (!mounted || values == null) return;
      for (final value in values) {
        add(value);
      }
    } on FormatException catch (e) {
      if (mounted) error = e.message;
    } catch (_) {
      if (mounted) {
        error =
            'Could not scan the QR. Allow camera access or choose a QR image.';
      }
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  void paste() {
    widget.touch();
    try {
      add(input.text);
      input.clear();
      error = null;
    } on FormatException catch (e) {
      error = e.message;
    }
    setState(() {});
  }

  @override
  void dispose() {
    input.clear();
    input.dispose();
    accounts.clear();
    selected.clear();
    pages.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: dialogTitle(
              'Import authenticator accounts',
              Icons.qr_code_scanner,
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                const InfoBox(
                  text: 'In Google Authenticator, open Transfer accounts → Export accounts. Select all or the accounts you want. Scan every QR page, then review the accounts below. You can also choose a saved QR image.',
                ),
                const SizedBox(height: 12),
                if (widget.integrations.isAndroid)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: scanning ? null : () => scan(false),
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Scan QR'),
                      ),
                      OutlinedButton.icon(
                        onPressed: scanning ? null : () => scan(true),
                        icon: const Icon(Icons.image_outlined),
                        label: const Text('Choose QR image'),
                      ),
                    ],
                  ),
                if (scanning) const LinearProgressIndicator(),
                const SizedBox(height: 12),
                VField(
                  controller: input,
                  label: 'Or paste an authenticator QR URI',
                  touch: widget.touch,
                  secret: true,
                ),
                TextButton(
                  onPressed: scanning ? null : paste,
                  child: const Text('Read pasted QR'),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: const TextStyle(color: Color(0xFFFFB4AB)),
                  ),
                if (batchId != null)
                  Text(
                    '${pages.length} of $batchSize Google export QR pages scanned.',
                    style: const TextStyle(color: accent),
                  ),
                if (pages.length < batchSize)
                  const Text(
                    'Scan the remaining pages to include the entire export. Only listed accounts will be imported.',
                  ),
                if (accounts.isNotEmpty) ...[
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: () => setState(() {
                          selected.clear();
                          selected.addAll(
                            accounts.map(
                              (account) => totpIdentity(account.uri),
                            ),
                          );
                        }),
                        child: const Text('Select all listed'),
                      ),
                      TextButton(
                        onPressed: () => setState(selected.clear),
                        child: const Text('Select none'),
                      ),
                    ],
                  ),
                  ...accounts.map(
                    (account) => CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(account.title),
                      subtitle: account.username.isEmpty
                          ? null
                          : Text(account.username),
                      value: selected.contains(totpIdentity(account.uri)),
                      onChanged: (value) {
                        widget.touch();
                        setState(() {
                          if (value == true) {
                            selected.add(totpIdentity(account.uri));
                          } else {
                            selected.remove(totpIdentity(account.uri));
                          }
                        });
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: OverflowBar(
              spacing: 8,
              alignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: selected.isEmpty || scanning
                      ? null
                      : () => Navigator.pop(
                          context,
                          accounts
                              .where(
                                (account) => selected.contains(
                                  totpIdentity(account.uri),
                                ),
                              )
                              .toList(),
                        ),
                  child: Text('Import selected (${selected.length})'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
