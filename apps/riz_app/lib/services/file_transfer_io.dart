import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

Future<List<({String name, Uint8List bytes})>?> pickLocalFiles() async {
  final files = await openFiles();
  if (files.isEmpty) return null;
  return [
    for (final file in files)
      (name: file.name, bytes: await file.readAsBytes()),
  ];
}

Future<void> saveLocalFile(String name, Uint8List bytes) async {
  final location = await getSaveLocation(suggestedName: name);
  if (location == null) return;
  await XFile.fromData(bytes, name: name).saveTo(location.path);
}
