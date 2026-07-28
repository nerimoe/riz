import 'package:flutter_test/flutter_test.dart';
import 'package:riz_app/models.dart';

void main() {
  test('persists relay connection type', () {
    const connection = DaemonConnection(
      id: 'daemon-1',
      name: 'My Mac',
      url: 'wss://relay.example/v1/relay/device/client',
      usesRelay: true,
    );

    expect(DaemonConnection.fromJson(connection.toJson()).usesRelay, isTrue);
  });

  test('infers relay type for connection records saved before build 9', () {
    final connection = DaemonConnection.fromJson({
      'id': 'daemon-1',
      'name': 'My Mac',
      'url': 'wss://relay.example/v1/relay/device/client',
    });

    expect(connection.usesRelay, isTrue);
  });

  test('does not infer relay type for direct daemon connections', () {
    final connection = DaemonConnection.fromJson({
      'id': 'daemon-1',
      'name': 'My Mac',
      'url': 'wss://mac.example/ws',
    });

    expect(connection.usesRelay, isFalse);
  });
}
