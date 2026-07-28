import 'package:flutter_test/flutter_test.dart';
import 'package:riz_app/services/ssh_installer_stub.dart';

void main() {
  test('maps macOS architectures to release targets', () {
    expect(macOsReleaseTarget('arm64'), 'aarch64-apple-darwin');
    expect(macOsReleaseTarget('x86_64'), 'x86_64-apple-darwin');
    expect(() => macOsReleaseTarget('i386'), throwsStateError);
  });

  test('resolves architecture placeholders in release URLs', () {
    expect(
      resolveMacOsReleaseUrl(
        'https://example.test/rizd-{target}-{arch}',
        'arm64',
      ),
      'https://example.test/rizd-aarch64-apple-darwin-arm64',
    );
  });
}
