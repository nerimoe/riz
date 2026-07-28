import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../providers/app_controller.dart';
import '../services/ssh_installer.dart';
import 'adaptive_text_selection.dart';

class SshInstallDialog extends ConsumerStatefulWidget {
  const SshInstallDialog({super.key});
  @override
  ConsumerState<SshInstallDialog> createState() => _SshInstallDialogState();
}

class _SshInstallDialogState extends ConsumerState<SshInstallDialog> {
  final host = TextEditingController();
  final port = TextEditingController(text: '22');
  final username = TextEditingController();
  final password = TextEditingController();
  final privateKey = TextEditingController();
  final releaseUrl = TextEditingController();
  final sha256 = TextEditingController();
  final endpoint = TextEditingController();
  bool busy = false;
  String? progress;

  String t(String zh, String en) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

  @override
  void initState() {
    super.initState();
    for (final controller in [host, username, releaseUrl, sha256]) {
      controller.addListener(_formChanged);
    }
  }

  void _formChanged() => setState(() {});

  @override
  void dispose() {
    for (final controller in [
      host,
      port,
      username,
      password,
      privateKey,
      releaseUrl,
      sha256,
      endpoint,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<bool> verify(String type, String fingerprint) async =>
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(t('验证 SSH 主机密钥', 'Verify SSH host key')),
          content: SelectableText(
            '$type\n$fingerprint',
            selectionControls: rizTextSelectionControls,
            magnifierConfiguration: rizTextMagnifierConfiguration,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('拒绝', 'Reject')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('接受', 'Accept')),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> install() async {
    setState(() {
      busy = true;
      progress = t('正在连接、校验并安装…', 'Connecting, verifying, and installing…');
    });
    try {
      final result = await installRizDaemon(
        SshInstallRequest(
          host: host.text.trim(),
          port: int.tryParse(port.text) ?? 22,
          username: username.text.trim(),
          password: password.text,
          privateKey: privateKey.text,
          releaseUrl: releaseUrl.text.trim(),
          sha256: sha256.text.trim(),
        ),
        verify,
      );
      final url = endpoint.text.trim().isEmpty
          ? 'ws://${host.text.trim()}:7497/ws'
          : endpoint.text.trim();
      await ref
          .read(appControllerProvider.notifier)
          .addConnection(name: host.text.trim(), url: url, token: result.token);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => progress = '$e');
    } finally {
      password.clear();
      privateKey.clear();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final valid =
        host.text.trim().isNotEmpty &&
        username.text.trim().isNotEmpty &&
        releaseUrl.text.trim().isNotEmpty &&
        RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(sha256.text.trim());
    return AlertDialog(
      title: Text(t('通过 SSH 安装 rizd', 'Install rizd over SSH')),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      selectionControls: rizTextSelectionControls,
                      magnifierConfiguration: rizTextMagnifierConfiguration,
                      controller: host,
                      decoration: InputDecoration(labelText: t('主机', 'Host')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 100,
                    child: TextField(
                      selectionControls: rizTextSelectionControls,
                      magnifierConfiguration: rizTextMagnifierConfiguration,
                      controller: port,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: t('端口', 'Port')),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                selectionControls: rizTextSelectionControls,
                magnifierConfiguration: rizTextMagnifierConfiguration,
                controller: username,
                decoration: InputDecoration(labelText: t('用户名', 'Username')),
              ),
              const SizedBox(height: 10),
              TextField(
                selectionControls: rizTextSelectionControls,
                magnifierConfiguration: rizTextMagnifierConfiguration,
                controller: password,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: t('密码（仅保存在内存）', 'Password (kept in memory only)'),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                selectionControls: rizTextSelectionControls,
                magnifierConfiguration: rizTextMagnifierConfiguration,
                controller: privateKey,
                minLines: 2,
                maxLines: 5,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: t(
                    'PEM 私钥（可选，仅保存在内存）',
                    'Private key PEM (optional, kept in memory only)',
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                selectionControls: rizTextSelectionControls,
                magnifierConfiguration: rizTextMagnifierConfiguration,
                controller: releaseUrl,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: t('已签名 rizd 下载地址', 'Signed rizd release URL'),
                  helperText: t(
                    '可使用 {target} 或 {arch} 作为架构占位符',
                    'Use {target} or {arch} as an architecture placeholder',
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                selectionControls: rizTextSelectionControls,
                magnifierConfiguration: rizTextMagnifierConfiguration,
                controller: sha256,
                decoration: InputDecoration(
                  labelText: t(
                    'SHA-256 校验值（必填）',
                    'SHA-256 checksum (required)',
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                selectionControls: rizTextSelectionControls,
                magnifierConfiguration: rizTextMagnifierConfiguration,
                controller: endpoint,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: t(
                    '外部 WSS 地址（可选）',
                    'External WSS endpoint (optional)',
                  ),
                ),
              ),
              if (progress != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SelectableText(
                    progress!,
                    selectionControls: rizTextSelectionControls,
                    magnifierConfiguration: rizTextMagnifierConfiguration,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: Text(t('取消', 'Cancel')),
        ),
        FilledButton.icon(
          onPressed: busy || !valid ? null : install,
          icon: busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.install_mobile),
          label: Text(t('安装', 'Install')),
        ),
      ],
    );
  }
}
