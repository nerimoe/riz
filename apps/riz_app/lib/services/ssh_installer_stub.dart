typedef HostKeyVerifier =
    Future<bool> Function(String type, String fingerprint);

class SshInstallRequest {
  const SshInstallRequest({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.privateKey,
    required this.releaseUrl,
    required this.sha256,
  });
  final String host;
  final int port;
  final String username;
  final String password;
  final String privateKey;
  final String releaseUrl;
  final String sha256;
}

class SshInstallResult {
  const SshInstallResult({required this.token, required this.architecture});
  final String token;
  final String architecture;
}

String macOsReleaseTarget(String architecture) => switch (architecture) {
  'arm64' => 'aarch64-apple-darwin',
  'x86_64' => 'x86_64-apple-darwin',
  _ => throw StateError('Unsupported architecture: $architecture'),
};

String resolveMacOsReleaseUrl(String template, String architecture) {
  final target = macOsReleaseTarget(architecture);
  return template
      .replaceAll('{arch}', architecture)
      .replaceAll('{target}', target);
}

Future<SshInstallResult> installRizDaemon(
  SshInstallRequest request,
  HostKeyVerifier verify,
) => throw UnsupportedError('SSH installation is unavailable on Web');
