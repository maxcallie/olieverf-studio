import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Web: triggers a browser download (on iPhone Safari you get a
/// "Download?" prompt; the file lands in Files → Downloads).
Future<String?> saveBytes(Uint8List bytes, String fileName, String mime) async {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime));
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  Future<void>.delayed(
      const Duration(minutes: 1), () => web.URL.revokeObjectURL(url));
  return fileName;
}
