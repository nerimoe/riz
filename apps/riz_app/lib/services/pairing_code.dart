import 'dart:convert';

class RizPairingCode {
  const RizPairingCode({
    required this.name,
    required this.url,
    required this.token,
    required this.relayToken,
  });

  final String name;
  final String url;
  final String token;
  final String relayToken;
}

RizPairingCode decodePairingCode(String raw) {
  final value = raw.trim();
  if (!value.startsWith('riz1.')) {
    throw const FormatException('Pairing code must start with riz1.');
  }
  try {
    final decoded = utf8.decode(
      base64Url.decode(base64Url.normalize(value.substring(5))),
    );
    final json = (jsonDecode(decoded) as Map).cast<String, dynamic>();
    if (json['v'] != 1) throw const FormatException('Unsupported pairing code');
    final name = json['name'] as String?;
    final url = json['url'] as String?;
    final token = json['token'] as String?;
    final relayToken = json['relayToken'] as String?;
    final uri = Uri.tryParse(url ?? '');
    if (name == null ||
        name.trim().isEmpty ||
        uri == null ||
        uri.scheme != 'wss' ||
        uri.host.isEmpty ||
        token == null ||
        token.trim().isEmpty ||
        relayToken == null ||
        !RegExp(r'^[A-Za-z0-9_-]{32,256}$').hasMatch(relayToken)) {
      throw const FormatException('Invalid pairing code');
    }
    return RizPairingCode(
      name: name.trim(),
      url: url!,
      token: token.trim(),
      relayToken: relayToken,
    );
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('Invalid pairing code');
  }
}
