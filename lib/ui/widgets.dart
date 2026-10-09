import 'dart:async';

import '../features/files.dart';

import 'package:flutter/material.dart';
import 'package:vault_core/vault_core.dart';

import '../app/vault_controller.dart';

// ─── Design system palette ───────────────────────────────────────────────────

const ink = Color(0xFF0E1018);
const panel = Color(0xFF1A1D28);
const accent = Color(0xFFE0BB83);
const surface = Color(0xFF222636);
const surfaceHover = Color(0xFF2A2F3F);
const borderSubtle = Color(0xFF2E3245);
const dimText = Color(0xFF717896);
const successColor = Color(0xFF34D399);
const warningColor = Color(0xFFFBBF24);
const dangerColor = Color(0xFFEF4444);
const accentDim = Color(0x28E0BB83);
const noteColor = Color(0xFF8B9CF7);

// ─── Dialog title helper ─────────────────────────────────────────────────────

Widget dialogTitle(String text, IconData icon, {Color? color}) {
  final c = color ?? accent;
  return Row(
    children: [
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: c.withAlpha(25),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: c, size: 22),
      ),
      const SizedBox(width: 14),
      Flexible(child: Text(text)),
    ],
  );
}

// ─── Breathing shield animation ──────────────────────────────────────────────

class BreathingShield extends StatefulWidget {
  const BreathingShield({super.key, this.size = 64});
  final double size;
  @override
  State<BreathingShield> createState() => _BreathingShieldState();
}

class _BreathingShieldState extends State<BreathingShield>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    if (!WidgetsBinding.instance.runtimeType.toString().contains('Test')) {
      _ctrl.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _ctrl,
    builder: (_, __) {
      final t = _ctrl.value;
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: accent.withAlpha((35 * t).round()),
              blurRadius: 40 + 30 * t,
              spreadRadius: 6 * t,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.size * 0.22),
          child: Image.asset(
            'assets/branding/app_icon.png',
            width: widget.size,
            height: widget.size,
          ),
        ),
      );
    },
  );
}

// ─── Reusable text field ─────────────────────────────────────────────────────

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
    this.prefixIcon,
  });
  final TextEditingController controller;
  final String label;
  final VoidCallback touch;
  final bool secret;
  final int maxLines;
  final ValueChanged<String>? onChanged, onSubmitted;
  final IconData? prefixIcon;
  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    decoration: InputDecoration(
      labelText: label,
      prefixIcon: prefixIcon != null
          ? Icon(prefixIcon, size: 20, color: dimText)
          : null,
    ),
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

// ─── Section card with icon and accent ───────────────────────────────────────

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.children,
    this.icon,
    this.accentColor,
  });
  final String title;
  final List<Widget> children;
  final IconData? icon;
  final Color? accentColor;
  @override
  Widget build(BuildContext context) {
    final color = accentColor ?? accent;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: panel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: borderSubtle, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: borderSubtle, width: 1),
              ),
            ),
            child: Row(
              children: [
                if (icon != null) ...[
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: color.withAlpha(30),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, size: 18, color: color),
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Info box helper ─────────────────────────────────────────────────────────

class InfoBox extends StatelessWidget {
  const InfoBox({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: surface,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(text, style: const TextStyle(fontSize: 13, color: dimText)),
  );
}

// ─── Unlock choice ───────────────────────────────────────────────────────────

class UnlockChoice {
  const UnlockChoice(this.value, this.usePassword);
  final String value;
  final bool usePassword;
}

// ─── Transfer code dialog ────────────────────────────────────────────────────

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
    title: dialogTitle('Receive transfer', Icons.sync_alt_rounded),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const InfoBox(
              text: 'Paste the full private code from the sending device. For a file transfer, you will choose its encrypted .svx file next.',
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

// ─── Backup credentials dialog ───────────────────────────────────────────────

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
    title: dialogTitle('Unlock selected backup', Icons.lock_open_rounded),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const InfoBox(
            text: 'Choose the credentials that were active when this backup was exported. A key file contains the key, not the vault data.',
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
            prefixIcon: password ? Icons.password : Icons.key,
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
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(error!, style: const TextStyle(color: dangerColor)),
            ),
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

// ─── Merge dialog ────────────────────────────────────────────────────────────

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

  Widget _badge(String label, int count, Color color, IconData icon) =>
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: color.withAlpha(18),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(40)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Text(
              '$label: $count',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: dialogTitle('Review incoming changes', Icons.compare_arrows_rounded),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _badge('Additions', widget.preview.additions.length,
                successColor, Icons.add_circle_outline),
            if (widget.preview.additions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 12),
                child: Text(
                  widget.preview.additions.take(20).join(', '),
                  style: const TextStyle(fontSize: 13, color: dimText),
                ),
              ),
            _badge('Conflicts', widget.preview.conflicts.length,
                warningColor, Icons.warning_amber_rounded),
            if (widget.preview.conflicts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 4),
                child: Text(
                  widget.preview.conflicts.take(20).join(', '),
                  style: const TextStyle(fontSize: 13, color: dimText),
                ),
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
            _badge('Incoming deletions', widget.preview.deletions.length,
                dangerColor, Icons.remove_circle_outline),
            if (widget.preview.deletions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 4),
                child: Text(
                  widget.preview.deletions.take(20).join(', '),
                  style: const TextStyle(fontSize: 13, color: dimText),
                ),
              ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: deletions,
              onChanged: (v) => setState(() => deletions = v ?? false),
              title: const Text('Apply incoming deletions'),
            ),
            const SizedBox(height: 8),
            const InfoBox(
              text: 'Local password unlock and integration settings are retained. This is a manual merge of a snapshot, not continuous synchronization.',
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

// ─── OTP card with circular countdown ────────────────────────────────────────

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
  static const _period = 30;
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
  Widget build(BuildContext context) {
    final isLow = remaining <= 5;
    final progressColor = isLow ? dangerColor : accent;
    final progress = remaining.clamp(0, _period) / _period;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderSubtle),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 3,
                      color: progressColor,
                      backgroundColor: borderSubtle,
                    ),
                  ),
                  Text(
                    '${remaining}s',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: isLow ? dangerColor : dimText,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.entry.title,
                    style: const TextStyle(fontSize: 13, color: dimText),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    code,
                    style: const TextStyle(
                      fontFamily: 'LocalMono',
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 4,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Copy authenticator code',
              onPressed: config == null ? null : () => widget.copy(code),
              icon: const Icon(Icons.copy, size: 20),
              style: IconButton.styleFrom(
                backgroundColor: accentDim,
                foregroundColor: accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
