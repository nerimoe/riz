import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:riz_app/services/pairing_code.dart';

void main() {
  test('decodes a versioned relay pairing code', () {
    final payload = base64Url
        .encode(
          utf8.encode(
            jsonEncode({
              'v': 1,
              'name': 'Studio Mac',
              'url': 'wss://relay.example/v1/relay/device_abcdefghijkl/client',
              'token': 'daemon-token',
              'relayToken': 'A' * 43,
            }),
          ),
        )
        .replaceAll('=', '');
    final code = decodePairingCode('riz1.$payload');
    expect(code.name, 'Studio Mac');
    expect(code.url, contains('/client'));
    expect(code.token, 'daemon-token');
    expect(code.relayToken, 'A' * 43);
  });

  test('rejects malformed, insecure, and unknown pairing codes', () {
    expect(() => decodePairingCode('hello'), throwsFormatException);
    final payload = base64Url.encode(
      utf8.encode(
        jsonEncode({
          'v': 2,
          'name': 'Mac',
          'url': 'ws://relay.example/client',
          'token': 'token',
          'relayToken': 'short',
        }),
      ),
    );
    expect(() => decodePairingCode('riz1.$payload'), throwsFormatException);
  });
}
