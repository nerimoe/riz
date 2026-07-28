String normalizeDaemonUrl(String raw, {bool requireSecureWebSocket = false}) {
  var value = raw.trim();
  if (value.isEmpty) {
    throw const FormatException('WebSocket URL is required');
  }
  if (!value.contains('://')) {
    value = '${requireSecureWebSocket ? 'wss' : 'ws'}://$value';
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !const {'ws', 'wss'}.contains(uri.scheme.toLowerCase()) ||
      uri.host.isEmpty ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('Enter a valid ws:// or wss:// URL');
  }
  if (requireSecureWebSocket && uri.scheme.toLowerCase() != 'wss') {
    throw const FormatException(
      'HTTPS Web clients require a wss:// daemon URL',
    );
  }
  final path = uri.path.isEmpty || uri.path == '/' ? '/ws' : uri.path;
  return uri.replace(scheme: uri.scheme.toLowerCase(), path: path).toString();
}

bool isInsecureRemoteDaemonUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme.toLowerCase() != 'ws') return false;
  final host = uri.host.toLowerCase();
  final loopback =
      host == 'localhost' ||
      host == '::1' ||
      host == '0:0:0:0:0:0:0:1' ||
      host.startsWith('127.');
  return !loopback;
}
