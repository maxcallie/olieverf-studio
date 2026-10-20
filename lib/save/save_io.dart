import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Native (iOS/Android/desktop): opens a save dialog.
/// Returns the file name that was saved, or null if cancelled.
Future<String?> saveBytes(Uint8List bytes, String fileName, String mime) async {
  final ext = fileName.split('.').last;
  final path = await FilePicker.platform.saveFile(
    dialogTitle: 'Schilderij opslaan',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: [ext],
    bytes: bytes,
  );
  if (path == null) return null;
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    // On desktop file_picker only returns the chosen path.
    await File(path).writeAsBytes(bytes, flush: true);
  }
  return path.split(RegExp(r'[/\\]')).last;
}
