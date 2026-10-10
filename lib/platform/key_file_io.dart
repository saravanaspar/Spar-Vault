import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vault_core/vault_core.dart';

const masterKeyFileName = 'spar-vault-master-key.txt';

/// Commit a complete key file before replacing the existing copy in this folder.
Future<void> writeMasterKeyFile(String directory, Uint8List bytes) async {
  final key = MasterKey.parse(utf8.decode(bytes));
  key.destroy();
  final dir = Directory(directory);
  if (!await dir.exists()) {
    throw const FileSystemException('Key folder unavailable.');
  }
  final target = File('${dir.path}${Platform.pathSeparator}$masterKeyFileName');
  Future<void> checkTarget() async {
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const FileSystemException(
        'The key filename is occupied by a folder or link.',
      );
    }
  }

  await checkTarget();
  final temporary = File('${target.path}.${randomId()}.tmp');
  try {
    await temporary.create(exclusive: true);
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('chmod', ['600', temporary.path]);
      if (result.exitCode != 0) {
        throw const FileSystemException(
          'Cannot restrict key-file permissions.',
        );
      }
    }
    await temporary.writeAsBytes(bytes, flush: true);
    await checkTarget();
    await temporary.rename(target.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
