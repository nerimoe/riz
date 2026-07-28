import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_installer_stub.dart';
export 'ssh_installer_stub.dart';

String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

Future<Uint8List> _downloadRelease(String url) async {
  final uri = Uri.parse(url);
  if (uri.scheme != 'https' || uri.host.isEmpty) {
    throw FormatException('The release URL must use HTTPS');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Release download failed with HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    const limit = 100 * 1024 * 1024;
    if (response.contentLength > limit) {
      throw StateError('Release exceeds the 100 MiB limit');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      bytes.add(chunk);
      if (bytes.length > limit) {
        throw StateError('Release exceeds the 100 MiB limit');
      }
    }
    return bytes.takeBytes();
  } finally {
    client.close(force: true);
  }
}

Future<SshInstallResult> installRizDaemon(
  SshInstallRequest request,
  HostKeyVerifier verify,
) async {
  final socket = await SSHSocket.connect(
    request.host,
    request.port,
    timeout: const Duration(seconds: 15),
  );
  final identities = request.privateKey.trim().isEmpty
      ? null
      : SSHKeyPair.fromPem(request.privateKey);
  final client = SSHClient(
    socket,
    username: request.username,
    identities: identities,
    onPasswordRequest: request.password.isEmpty ? null : () => request.password,
    onVerifyHostKey: (type, fingerprint) =>
        verify(type, 'SHA256:${base64Encode(fingerprint).replaceAll('=', '')}'),
  );
  try {
    final arch = utf8.decode(await client.run('uname -m')).trim();
    if (arch != 'arm64' && arch != 'x86_64') {
      throw StateError('Unsupported architecture: $arch');
    }
    final checksum = request.sha256.trim().toLowerCase();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(checksum)) {
      throw FormatException('A valid SHA-256 checksum is required');
    }
    final releaseUrl = resolveMacOsReleaseUrl(request.releaseUrl.trim(), arch);
    final release = await _downloadRelease(releaseUrl);
    final remoteBinary =
        '/tmp/rizd-install-${DateTime.now().microsecondsSinceEpoch}';
    final sftp = await client.sftp();
    final remoteFile = await sftp.open(
      remoteBinary,
      mode:
          SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );
    try {
      await remoteFile.write(Stream.value(release));
    } finally {
      await remoteFile.close();
    }
    final plist = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.riz.rizd</string>
<key>ProgramArguments</key><array><string>__HOME__/.local/bin/rizd</string><string>serve</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>__HOME__/.riz/rizd.log</string>
<key>StandardErrorPath</key><string>__HOME__/.riz/rizd.err.log</string>
    </dict></plist>''';
    final plist64 = base64Encode(utf8.encode(plist));
    final install =
        '''set -eu
test "\$(uname -s)" = Darwin
test "\$(uname -m)" = ${_quote(arch)}
mkdir -p "\$HOME/.local/bin" "\$HOME/Library/LaunchAgents" "\$HOME/.riz"
REMOTE=${_quote(remoteBinary)}
BIN="\$HOME/.local/bin/rizd"
NEW="\$HOME/.local/bin/.rizd.new"
BACKUP="\$HOME/.local/bin/.rizd.previous"
PLIST="\$HOME/Library/LaunchAgents/dev.riz.rizd.plist"
echo ${_quote('$checksum  $remoteBinary')} | shasum -a 256 -c -
chmod 755 "\$REMOTE"
codesign --verify --strict "\$REMOTE"
"\$REMOTE" --version
rm -f "\$NEW" "\$BACKUP"
install -m 755 "\$REMOTE" "\$NEW"
if test -f "\$BIN"; then cp -p "\$BIN" "\$BACKUP"; fi
mv "\$NEW" "\$BIN"
echo ${_quote(plist64)} | base64 -D | sed "s|__HOME__|\$HOME|g" > "\$PLIST.new"
mv "\$PLIST.new" "\$PLIST"
if test -f "\$HOME/.riz/config.json"; then "\$BIN" token issue --name ssh-installer; else "\$BIN" init; fi
launchctl bootout "gui/\$(id -u)/dev.riz.rizd" >/dev/null 2>&1 || true
if ! launchctl bootstrap "gui/\$(id -u)" "\$PLIST"; then
  if test -f "\$BACKUP"; then mv "\$BACKUP" "\$BIN"; launchctl bootstrap "gui/\$(id -u)" "\$PLIST" || true; fi
  exit 1
fi
launchctl enable "gui/\$(id -u)/dev.riz.rizd"
rm -f "\$BACKUP" "\$REMOTE"''';
    final result = await client.runWithResult(install);
    if (result.exitCode != 0) throw StateError(utf8.decode(result.stderr));
    final output = utf8.decode(result.stdout);
    final token = RegExp(
      r'(?:Token:\s*)?([A-Za-z0-9_-]{43})',
    ).allMatches(output).lastOrNull?.group(1);
    if (token == null) {
      throw StateError('rizd installed but no token was returned');
    }
    return SshInstallResult(token: token, architecture: arch);
  } finally {
    client.close();
    await client.done;
  }
}
