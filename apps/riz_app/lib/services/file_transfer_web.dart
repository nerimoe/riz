import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart';

Future<List<({String name, Uint8List bytes})>?> pickLocalFiles() async {
  final completer = Completer<List<({String name, Uint8List bytes})>?>();
  final input = HTMLInputElement()
    ..type = 'file'
    ..multiple = true
    ..style.display = 'none';

  void cleanUp() => input.remove();

  input.onChange.listen((_) async {
    final files = input.files;
    if (files == null || files.length == 0) {
      cleanUp();
      if (!completer.isCompleted) completer.complete(null);
      return;
    }
    final picked = <({String name, Uint8List bytes})>[];
    for (var i = 0; i < files.length; i++) {
      final file = files.item(i);
      if (file == null) continue;
      final reader = FileReader();
      final loaded = Completer<Uint8List>();
      reader.onLoadEnd.listen((_) {
        final buffer = (reader.result as JSArrayBuffer?)?.toDart;
        loaded.complete(buffer?.asUint8List() ?? Uint8List(0));
      });
      reader.readAsArrayBuffer(file);
      picked.add((name: file.name, bytes: await loaded.future));
    }
    cleanUp();
    if (!completer.isCompleted) completer.complete(picked);
  });
  input.addEventListener(
    'cancel',
    ((Event _) {
      cleanUp();
      if (!completer.isCompleted) completer.complete(null);
    }).toJS,
  );
  document.body?.append(input);
  input.click();
  return completer.future;
}

Future<void> saveLocalFile(String name, Uint8List bytes) async {
  final blob = Blob([bytes.toJS].toJS);
  final url = URL.createObjectURL(blob);
  final anchor = HTMLAnchorElement()
    ..href = url
    ..download = name;
  document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  await Future<void>.delayed(Duration.zero);
  URL.revokeObjectURL(url);
}
