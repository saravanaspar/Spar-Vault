import 'package:file_picker/file_picker.dart';
import 'package:file_picker_web/file_picker_web.dart';

FilePickerWebOptions backupPickerOptions() =>
    const FilePickerWebOptions(withData: false, withReadStream: true);

void warmupLinuxWindowId() {}

Future<LinuxOptions> pickerLinuxOptions({String? title, String? acceptLabel}) async =>
    const LinuxOptions();

void ensureDialogForeground(String? title) {}
