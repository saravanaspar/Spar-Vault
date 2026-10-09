import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:vault_core/vault_core.dart';

import '../platform/picker_options.dart';

Future<Uint8List?> pickBytes({
  required int limit,
  String? extension,
  String title = 'Choose file',
}) async {
  final file = await FilePicker.pickFile(
    dialogTitle: title,
    type: extension == null ? FileType.any : FileType.custom,
    allowedExtensions: extension == null ? null : [extension],
    webOptions: backupPickerOptions(),
  );
  if (file == null) return null;
  final size = await file.length();
  if (size == null || size > limit) {
    throw const FormatException(
      'The selected file exceeds the size limit or could not be read.',
    );
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.readAsByteStream()) {
    if (builder.length + chunk.length > limit) {
      throw const FormatException('The selected file exceeds the size limit.');
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<MasterKey?> pickMasterKey() async {
  final bytes = await pickBytes(
    limit: 512,
    extension: 'txt',
    title: 'Choose master-key text file',
  );
  if (bytes == null) return null;
  try {
    return MasterKey.parse(utf8.decode(bytes));
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

Future<String?> pickBackup() async {
  final bytes = await pickBytes(
    limit: maxEnvelopeBytes,
    extension: 'svlt',
    title: 'Choose encrypted vault backup (.svlt)',
  );
  if (bytes == null) return null;
  try {
    final text = utf8.decode(bytes);
    MasterKey? accidentalKey;
    try {
      accidentalKey = MasterKey.parse(text);
    } on FormatException {
      /* Not a bare key. */
    }
    if (accidentalKey != null) {
      accidentalKey.destroy();
      throw const FormatException(
        'This is a master-key text file. Restore needs the encrypted .svlt backup and its matching key. Export an encrypted backup on your other device first.',
      );
    }
    VaultBundle.parse(text);
    return text;
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

String? webOrigin(String value) {
  if (value.length > 2000) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return Uri(
    scheme: 'https',
    host: uri.host,
    port: uri.hasPort && uri.port != 443 ? uri.port : null,
  ).origin;
}

class HealthReport {
  HealthReport(List<VaultEntry> entries) {
    final groups = <String, List<VaultEntry>>{};
    for (final e in entries.where(
      (e) => e.kind == EntryKind.login && e.password.isNotEmpty,
    )) {
      groups.putIfAbsent(e.password, () => []).add(e);
      if (e.password.length < 16) short.add(e);
      if (e.password.length >= 16 &&
          !e.password.contains(RegExp(r'[^A-Za-z]'))) {
        wordOnly.add(e);
      }
    }
    for (final g in groups.values) {
      if (g.length > 1) reused.addAll(g);
    }
  }
  final List<VaultEntry> short = [], reused = [], wordOnly = [];
}
