import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_picker_linux/file_picker_linux.dart';

WebOptions backupPickerOptions() => const WebOptions();

String? _cachedLinuxWindowId;
bool _resolving = false;

/// Resolves the X11/Wayland window ID for the running Spar Vault process.
Future<String?> resolveLinuxWindowId() async {
  if (!Platform.isLinux) return null;
  if (_cachedLinuxWindowId != null) return _cachedLinuxWindowId;
  if (_resolving) {
    for (var i = 0; i < 15 && _resolving; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (_cachedLinuxWindowId != null) return _cachedLinuxWindowId;
    }
  }

  _resolving = true;
  try {
    final currentPid = pid;

    // 1. Check wmctrl -lp for a window belonging to current PID.
    try {
      final res = await Process.run('wmctrl', ['-lp'])
          .timeout(const Duration(milliseconds: 300));
      if (res.exitCode == 0) {
        final lines = (res.stdout as String).split('\n');
        for (final line in lines) {
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.length >= 3 && parts[2] == currentPid.toString()) {
            final winId = parts[0];
            if (winId.startsWith('0x')) {
              _cachedLinuxWindowId = 'x11:$winId';
              return _cachedLinuxWindowId;
            }
          }
        }
      }
    } catch (_) {}

    // 2. Check xdotool search for visible windows of current PID.
    try {
      final res = await Process.run('xdotool', [
        'search',
        '--onlyvisible',
        '--pid',
        currentPid.toString(),
      ]).timeout(const Duration(milliseconds: 300));
      if (res.exitCode == 0) {
        final ids = (res.stdout as String).trim().split('\n');
        for (final idStr in ids.reversed) {
          final id = int.tryParse(idStr.trim());
          if (id != null && id > 0) {
            _cachedLinuxWindowId = 'x11:0x${id.toRadixString(16)}';
            return _cachedLinuxWindowId;
          }
        }
      }
    } catch (_) {}

    // 3. Check xprop client list for our PID.
    try {
      final rootRes = await Process.run('xprop', ['-root', '_NET_CLIENT_LIST'])
          .timeout(const Duration(milliseconds: 300));
      if (rootRes.exitCode == 0) {
        final winIds = RegExp(r'0x[0-9a-fA-F]+')
            .allMatches(rootRes.stdout as String)
            .map((m) => m.group(0)!)
            .toList();
        for (final wid in winIds.reversed) {
          try {
            final pidRes = await Process.run('xprop', ['-id', wid, '_NET_WM_PID'])
                .timeout(const Duration(milliseconds: 150));
            if (pidRes.exitCode == 0 &&
                (pidRes.stdout as String).contains(currentPid.toString())) {
              _cachedLinuxWindowId = 'x11:$wid';
              return _cachedLinuxWindowId;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}

    // 4. Fallback to active window if it was our window when triggered.
    try {
      final res = await Process.run('xprop', ['-root', '_NET_ACTIVE_WINDOW'])
          .timeout(const Duration(milliseconds: 300));
      if (res.exitCode == 0) {
        final match = RegExp(r'0x[0-9a-fA-F]+').firstMatch(res.stdout as String);
        if (match != null && match.group(0) != '0x0') {
          _cachedLinuxWindowId = 'x11:${match.group(0)}';
          return _cachedLinuxWindowId;
        }
      }
    } catch (_) {}
  } finally {
    _resolving = false;
  }

  return _cachedLinuxWindowId;
}

/// Warms up window ID resolution during app startup in the background.
void warmupLinuxWindowId() {
  if (Platform.isLinux) {
    unawaited(resolveLinuxWindowId());
  }
}

/// Prepares LinuxOptions for FilePicker so desktop portal dialogs are attached
/// as modal child windows to the Flutter window and appear upfront.
Future<LinuxOptions> pickerLinuxOptions({
  String? title,
  String? acceptLabel,
}) async {
  if (!Platform.isLinux) {
    return const LinuxOptions();
  }
  final parentWindow = await resolveLinuxWindowId();
  return FilePickerLinuxOptions(
    parentWindow: parentWindow,
    lockParentWindow: true,
    acceptLabel: acceptLabel,
  );
}

/// Proactively ensures the file chooser dialog is raised to the foreground
/// and focused if the window manager has aggressive focus-stealing prevention.
void ensureDialogForeground(String? title) {
  if (!Platform.isLinux) return;
  unawaited(
    Future.microtask(() async {
      for (final delay in [150, 400, 800]) {
        await Future<void>.delayed(Duration(milliseconds: delay));
        try {
          if (title != null && title.isNotEmpty) {
            final res = await Process.run('wmctrl', ['-a', title])
                .timeout(const Duration(milliseconds: 200));
            if (res.exitCode == 0) break;
          }
          if (_cachedLinuxWindowId != null) {
            final res = await Process.run('xdotool', [
              'search',
              '--onlyvisible',
              '--name',
              title ?? 'Choose',
            ]).timeout(const Duration(milliseconds: 200));
            if (res.exitCode == 0) {
              final lines = (res.stdout as String).trim().split('\n');
              for (final line in lines) {
                final id = line.trim();
                if (id.isNotEmpty) {
                  await Process.run('xdotool', ['windowactivate', id])
                      .timeout(const Duration(milliseconds: 200));
                  break;
                }
              }
            }
          }
        } catch (_) {}
      }
    }),
  );
}
