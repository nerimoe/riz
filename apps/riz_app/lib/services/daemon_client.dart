import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

typedef EventHandler = void Function(String topic, dynamic data, int? seq);
typedef BinaryHandler = void Function(int channel, String id, Uint8List data);
typedef DebugHandler =
    void Function(String event, String level, String? detail);

class _DownloadTransfer {
  final bytes = BytesBuilder(copy: false);
  final completer = Completer<Uint8List>();
  int? expectedSize;

  void add(Uint8List chunk) {
    bytes.add(chunk);
    completeIfReady();
  }

  void completeIfReady() {
    final expected = expectedSize;
    if (expected == null || completer.isCompleted) return;
    if (bytes.length > expected) {
      completer.completeError(StateError('Download exceeded declared size'));
    } else if (bytes.length == expected) {
      completer.complete(bytes.takeBytes());
    }
  }
}

class DaemonClient {
  DaemonClient({
    required this.url,
    required this.token,
    required this.onEvent,
    required this.onBinary,
    required this.onStatus,
    this.onDebug,
  });
  final String url;
  final String token;
  final EventHandler onEvent;
  final BinaryHandler onBinary;
  final void Function(bool connected, String? error) onStatus;
  final DebugHandler? onDebug;
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _downloads = <String, _DownloadTransfer>{};
  int _generation = 0;
  int lastSeq = 0;

  Future<void> connect() async {
    _debug('connect.start', detail: url);
    await close();
    final generation = ++_generation;
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      await channel.ready;
      _debug('socket.ready');
      if (generation != _generation) {
        await channel.sink.close();
        return;
      }
      _channel = channel;
      _subscription = channel.stream.listen(
        _onData,
        onError: (Object e) {
          _debug('socket.error', level: 'error', detail: e.toString());
          _disconnected(e.toString(), generation);
        },
        onDone: () {
          _debug('socket.done', level: 'warning', detail: 'Connection closed');
          _disconnected('Connection closed', generation);
        },
      );
      channel.sink.add(
        jsonEncode({
          'v': 1,
          'type': 'auth',
          'requestId': 'auth',
          'payload': {'token': token, 'lastSeq': lastSeq},
        }),
      );
      _debug('auth.sent', detail: 'lastSeq=$lastSeq');
    } catch (e) {
      _debug('connect.failed', level: 'error', detail: e.toString());
      onStatus(false, e.toString());
      rethrow;
    }
  }

  void _onData(dynamic raw) {
    if (raw is List<int>) {
      final bytes = Uint8List.fromList(raw);
      if (bytes.length < 17) return;
      final idBytes = bytes.sublist(1, 17);
      final hex = idBytes
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join();
      final id =
          '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
      final transfer = _downloads[id];
      if (bytes[0] == 2 && transfer != null) {
        transfer.add(bytes.sublist(17));
        return;
      }
      onBinary(bytes[0], id, bytes.sublist(17));
      return;
    }
    final envelope = jsonDecode(raw as String) as Map<String, dynamic>;
    if (envelope['error'] != null) {
      final id = envelope['requestId'] as String?;
      _pending
          .remove(id)
          ?.completeError(Exception((envelope['error'] as Map)['message']));
      if (id == 'auth') {
        final message = (envelope['error'] as Map)['message'] as String?;
        _debug('auth.failed', level: 'error', detail: message);
        onStatus(false, message);
      }
      return;
    }
    if (envelope['type'] == 'response') {
      final payload = (envelope['payload'] as Map? ?? const {})
          .cast<String, dynamic>();
      if (payload['kind'] == 'hello') {
        _debug(
          'hello.received',
          detail: [
            payload['daemonName'],
            payload['daemonVersion'],
          ].whereType<Object>().join(' '),
        );
        onStatus(true, null);
      }
      _pending.remove(envelope['requestId'])?.complete(payload);
    } else if (envelope['type'] == 'event') {
      lastSeq = envelope['seq'] as int? ?? lastSeq;
      final payload = (envelope['payload'] as Map).cast<String, dynamic>();
      onEvent(
        payload['topic'] as String,
        payload['data'],
        envelope['seq'] as int?,
      );
    }
  }

  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) {
    final channel = _channel;
    if (channel == null) throw StateError('Not connected');
    final id = const Uuid().v4();
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    channel.sink.add(
      jsonEncode({
        'v': 1,
        'type': 'request',
        'requestId': id,
        'payload': {'method': method, 'params': params},
      }),
    );
    final timeout = method == 'daemon.update.install'
        ? const Duration(minutes: 5)
        : const Duration(seconds: 30);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException(method);
      },
    );
  }

  void sendTerminal(String id, List<int> data) {
    _sendBinary(3, id, data);
  }

  Future<Map<String, dynamic>> uploadFile(String path, Uint8List bytes) async {
    final begin = await request('fs.upload.begin', {
      'path': path,
      'size': bytes.length,
    });
    final id = begin['transferId'] as String;
    final chunkBytes = begin['chunkBytes'] as int? ?? 256 * 1024;
    for (var offset = 0; offset < bytes.length; offset += chunkBytes) {
      final end = (offset + chunkBytes).clamp(0, bytes.length);
      _sendBinary(2, id, bytes.sublist(offset, end));
    }
    return request('fs.upload.finish', {'transferId': id});
  }

  Future<({Map<String, dynamic> metadata, Uint8List bytes})> downloadFile(
    String path,
  ) async {
    final id = const Uuid().v4();
    final transfer = _DownloadTransfer();
    _downloads[id] = transfer;
    try {
      final metadata = await request('fs.download', {
        'path': path,
        'transferId': id,
      });
      transfer.expectedSize = metadata['size'] as int;
      transfer.completeIfReady();
      final bytes = await transfer.completer.future.timeout(
        const Duration(seconds: 30),
      );
      return (metadata: metadata, bytes: bytes);
    } finally {
      _downloads.remove(id);
    }
  }

  void _sendBinary(int channel, String id, List<int> data) {
    final clean = id.replaceAll('-', '');
    final frame = BytesBuilder()..addByte(channel);
    for (var i = 0; i < clean.length; i += 2) {
      frame.addByte(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    frame.add(data);
    _channel?.sink.add(frame.toBytes());
  }

  void _disconnected(String error, int generation) {
    if (generation != _generation) return;
    _generation++;
    final subscription = _subscription;
    _subscription = null;
    _channel = null;
    if (subscription != null) unawaited(subscription.cancel());
    onStatus(false, error);
    for (final value in _pending.values) {
      if (!value.isCompleted) value.completeError(StateError(error));
    }
    _pending.clear();
    for (final value in _downloads.values) {
      if (!value.completer.isCompleted) {
        value.completer.completeError(StateError(error));
      }
    }
    _downloads.clear();
  }

  void _debug(String event, {String level = 'info', String? detail}) {
    onDebug?.call(event, level, detail);
  }

  Future<void> close() async {
    _generation++;
    final subscription = _subscription;
    final channel = _channel;
    _subscription = null;
    _channel = null;
    await subscription?.cancel();
    try {
      await channel?.sink.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}
