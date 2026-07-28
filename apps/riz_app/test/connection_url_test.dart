import 'package:flutter_test/flutter_test.dart';
import 'package:riz_app/services/connection_url.dart';

void main() {
  test('normalizes daemon WebSocket URLs', () {
    expect(normalizeDaemonUrl('mac.example:7497'), 'ws://mac.example:7497/ws');
    expect(
      normalizeDaemonUrl('mac.example', requireSecureWebSocket: true),
      'wss://mac.example/ws',
    );
    expect(
      normalizeDaemonUrl('wss://mac.example/custom'),
      'wss://mac.example/custom',
    );
  });

  test('HTTPS Web clients reject insecure and invalid URLs', () {
    expect(
      () => normalizeDaemonUrl(
        'ws://mac.example/ws',
        requireSecureWebSocket: true,
      ),
      throwsFormatException,
    );
    expect(
      () => normalizeDaemonUrl('https://mac.example'),
      throwsFormatException,
    );
    expect(() => normalizeDaemonUrl('wss:///ws'), throwsFormatException);
  });

  test('warns only for non-loopback plaintext daemon URLs', () {
    expect(isInsecureRemoteDaemonUrl('ws://mac.example/ws'), isTrue);
    expect(isInsecureRemoteDaemonUrl('ws://127.0.0.1:7497/ws'), isFalse);
    expect(isInsecureRemoteDaemonUrl('ws://localhost:7497/ws'), isFalse);
    expect(isInsecureRemoteDaemonUrl('wss://mac.example/ws'), isFalse);
  });
}
