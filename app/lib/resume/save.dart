import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../widgets/common.dart';

const docxMime = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
const pdfMime = 'application/pdf';

/// Browser download on the web, the system save sheet on phones.
Future<void> saveBytes(BuildContext context, String fileName, Uint8List bytes, String mime) async {
  try {
    final where = await FilePicker.saveFile(fileName: fileName, bytes: bytes, mimeType: mime);
    if (!context.mounted) return;
    if (kIsWeb) {
      toast(context, 'Downloading $fileName');
    } else if (where != null) {
      toast(context, 'Saved $fileName');
    }
  } catch (e) {
    if (context.mounted) toast(context, 'Could not save $fileName: $e');
  }
}
