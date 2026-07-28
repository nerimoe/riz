import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:riz_app/services/daemon_client.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'usage: dart run tool/daemon_smoke.dart <ws-url> <token> <remote-path>',
    );
    exitCode = 64;
    return;
  }
  final connected = Completer<void>();
  final client = DaemonClient(
    url: args[0],
    token: args[1],
    onEvent: (_, _, _) {},
    onBinary: (_, _, _) {},
    onStatus: (ready, error) {
      if (ready && !connected.isCompleted) connected.complete();
      if (error != null && !connected.isCompleted) {
        connected.completeError(error);
      }
    },
  );
  try {
    await client.connect();
    await connected.future.timeout(const Duration(seconds: 5));
    final payload = Uint8List.fromList(
      utf8.encode('Riz binary upload smoke test\n'),
    );
    await client.uploadFile(args[2], payload);
    final read = await client.request('fs.read', {'path': args[2]});
    if (read['text'] != utf8.decode(payload)) {
      throw StateError('uploaded content mismatch');
    }
    final snapshot = await client.request('snapshot.get');
    stdout.writeln(
      jsonEncode({
        'ok': true,
        'lastSeq': snapshot['lastSeq'],
        'uploadedBytes': payload.length,
      }),
    );
  } finally {
    await client.close();
  }
}
