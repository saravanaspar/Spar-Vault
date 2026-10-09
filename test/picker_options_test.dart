import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spar_vault/platform/picker_options.dart';

void main() {
  test('pickerLinuxOptions returns modal options on Linux', () async {
    warmupLinuxWindowId();
    final options = await pickerLinuxOptions(
      title: 'Test Picker',
      acceptLabel: 'Open',
    );
    if (Platform.isLinux) {
      expect(options.lockParentWindow, isTrue);
    }
  });

  test('ensureDialogForeground runs without exception', () {
    expect(() => ensureDialogForeground('Test Title'), returnsNormally);
    expect(() => ensureDialogForeground(null), returnsNormally);
  });

  test('backupPickerOptions returns WebOptions', () {
    final opts = backupPickerOptions();
    expect(opts, isA<WebOptions>());
  });
}
