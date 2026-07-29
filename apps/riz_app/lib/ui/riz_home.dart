import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:code_text_field/code_text_field.dart';
import 'package:xterm/xterm.dart';

import '../app_build.dart';
import '../main.dart';
import '../models.dart';
import '../providers/app_controller.dart';
import '../services/connection_url.dart';
import '../services/file_transfer.dart';
import '../services/pairing_code.dart';
import 'adaptive_text_selection.dart';
import 'adaptive_composer.dart';
import 'ssh_install_dialog.dart';

String tr(BuildContext context, String zh, String en) =>
    Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

class RizHome extends ConsumerWidget {
  const RizHome({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    if (state.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (state.connections.isEmpty) return const _ConnectPage();
    return const _Shell();
  }
}

class _ConnectPage extends ConsumerWidget {
  const _ConnectPage();
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Riz')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.computer_rounded,
                size: 56,
                color: context.colors.primary,
              ),
              const SizedBox(height: 20),
              Text(
                tr(context, '连接一台电脑', 'Connect a computer'),
                style: context.text.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                tr(
                  context,
                  '输入 rizd 的 WebSocket 地址和安装时生成的 token。',
                  'Enter the rizd WebSocket URL and the token shown during setup.',
                ),
                style: context.text.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => const _ConnectionDialog(),
                ),
                icon: const Icon(Icons.add_link),
                label: Text(tr(context, '添加连接', 'Add connection')),
              ),
              if (!kIsWeb) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => const SshInstallDialog(),
                  ),
                  icon: const Icon(Icons.install_mobile),
                  label: Text(tr(context, '通过 SSH 安装', 'Install over SSH')),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class _Shell extends ConsumerWidget {
  const _Shell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);
    final body = switch (state.navigationIndex) {
      1 => const _TasksView(),
      2 => const _SkillsView(),
      3 => const _SettingsView(),
      _ => const _ProjectsView(),
    };
    final wide = MediaQuery.sizeOf(context).width >= 840;
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            SizedBox(
              width: 272,
              child: _ProjectTreeSidebar(
                projects: state.projects,
                selected: state.selectedProjectId,
              ),
            ),
            VerticalDivider(
              width: 1,
              color: context.colors.outlineVariant.withValues(alpha: .65),
            ),
            Expanded(
              child: _MotionSwap(
                switchKey: ValueKey(state.navigationIndex),
                child: body,
              ),
            ),
          ],
        ),
      );
    }
    final title =
        state.activeSession?['title']?.toString() ??
        state.selectedProject?['name']?.toString() ??
        switch (state.navigationIndex) {
          1 => tr(context, '运行中的任务', 'Running tasks'),
          2 => tr(context, '全局 Skills', 'Global skills'),
          3 => tr(context, '设置', 'Settings'),
          _ => 'Riz',
        };
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 56,
        leading: state.navigationIndex == 0 && state.activeSession != null
            ? IconButton(
                tooltip: tr(context, '返回会话列表', 'Back to sessions'),
                onPressed: () => controller.selectSession(null),
                icon: const Icon(Icons.arrow_back),
              )
            : null,
        titleSpacing: 4,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              state.connections
                      .where((item) => item.id == state.activeConnectionId)
                      .firstOrNull
                      ?.name ??
                  '',
              style: context.text.labelSmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: state.connected
                ? tr(context, '刷新', 'Refresh')
                : tr(context, '重新连接', 'Reconnect'),
            onPressed: controller.refreshOrReconnect,
            icon: Icon(
              state.connected
                  ? Icons.cloud_done_outlined
                  : Icons.cloud_off_outlined,
              color: state.connected
                  ? context.colors.primary
                  : context.colors.error,
            ),
          ),
        ],
      ),
      drawer: Drawer(
        width: 320,
        child: SafeArea(
          child: _ProjectTreeSidebar(
            projects: state.projects,
            selected: state.selectedProjectId,
            inDrawer: true,
          ),
        ),
      ),
      body: _MotionSwap(
        switchKey: ValueKey(state.navigationIndex),
        child: body,
      ),
    );
  }
}

class _MotionSwap extends StatelessWidget {
  const _MotionSwap({required this.switchKey, required this.child});

  final Key switchKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 240),
      reverseDuration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(.018, 0),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: switchKey, child: child),
    );
  }
}

class _DaemonPicker extends StatelessWidget {
  const _DaemonPicker({required this.state});
  final RizState state;
  @override
  Widget build(BuildContext context) => DropdownButtonHideUnderline(
    child: DropdownButton<String>(
      value: state.activeConnectionId,
      isDense: true,
      isExpanded: true,
      items: state.connections
          .map(
            (c) => DropdownMenuItem(
              value: c.id,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: (state.daemonStatuses[c.id] ?? false)
                          ? Colors.green
                          : context.colors.outline,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
      onChanged: (id) {
        if (id != null) context.readController.activateConnection(id);
      },
    ),
  );
}

extension ControllerContext on BuildContext {
  AppController get readController {
    final container = ProviderScope.containerOf(this);
    return container.read(appControllerProvider.notifier);
  }
}

class _ConnectionDialog extends ConsumerStatefulWidget {
  const _ConnectionDialog();
  @override
  ConsumerState<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends ConsumerState<_ConnectionDialog> {
  final pairingCode = TextEditingController();
  final name = TextEditingController(text: 'My Mac');
  final url = TextEditingController(
    text: kIsWeb && Uri.base.scheme == 'https'
        ? 'wss://'
        : 'ws://127.0.0.1:7497/ws',
  );
  final token = TextEditingController();
  bool busy = false;

  @override
  void initState() {
    super.initState();
    url.addListener(_urlChanged);
  }

  void _urlChanged() => setState(() {});

  @override
  void dispose() {
    url.removeListener(_urlChanged);
    name.dispose();
    url.dispose();
    token.dispose();
    pairingCode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr(context, '添加 daemon', 'Add daemon')),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            selectionControls: rizTextSelectionControls,
            magnifierConfiguration: rizTextMagnifierConfiguration,
            controller: pairingCode,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: tr(context, '配对码', 'Pairing code'),
              hintText: 'riz1...',
              prefixIcon: const Icon(Icons.key_rounded),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              tr(
                context,
                '粘贴电脑上 `rizd relay configure` 显示的配对码。',
                'Paste the pairing code shown by `rizd relay configure`.',
              ),
              style: context.text.bodySmall,
            ),
          ),
          const SizedBox(height: 8),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text(tr(context, '手动连接', 'Manual connection')),
            children: [
              TextField(
                selectionControls: rizTextSelectionControls,
                magnifierConfiguration: rizTextMagnifierConfiguration,
                controller: name,
                decoration: InputDecoration(
                  labelText: tr(context, '名称', 'Name'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                selectionControls: rizTextSelectionControls,
                magnifierConfiguration: rizTextMagnifierConfiguration,
                controller: url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'WebSocket URL'),
              ),
              const SizedBox(height: 12),
              TextField(
                selectionControls: rizTextSelectionControls,
                magnifierConfiguration: rizTextMagnifierConfiguration,
                controller: token,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Token'),
              ),
              if (isInsecureRemoteDaemonUrl(url.text)) ...[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: context.colors.error,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        tr(
                          context,
                          '该地址会通过未加密的 WebSocket 发送 token 和电脑数据。远程连接请使用 WSS tunnel。',
                          'This address sends the token and computer data over an unencrypted WebSocket. Use a WSS tunnel for remote connections.',
                        ),
                        style: context.text.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr(context, '取消', 'Cancel')),
      ),
      FilledButton(
        onPressed: busy
            ? null
            : () async {
                setState(() => busy = true);
                try {
                  final paired = pairingCode.text.trim().isEmpty
                      ? null
                      : decodePairingCode(pairingCode.text);
                  await ref
                      .read(appControllerProvider.notifier)
                      .addConnection(
                        name: paired?.name ?? name.text,
                        url: paired?.url ?? url.text,
                        token: paired?.token ?? token.text,
                        relayToken: paired?.relayToken,
                      );
                  if (context.mounted) Navigator.pop(context);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('$e')));
                  }
                } finally {
                  if (mounted) setState(() => busy = false);
                }
              },
        child: busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(tr(context, '连接', 'Connect')),
      ),
    ],
  );
}

class _TokenDialog extends ConsumerStatefulWidget {
  const _TokenDialog({required this.connection});

  final DaemonConnection connection;

  @override
  ConsumerState<_TokenDialog> createState() => _TokenDialogState();
}

class _TokenDialogState extends ConsumerState<_TokenDialog> {
  final token = TextEditingController();
  final pairingCode = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    token.dispose();
    pairingCode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.connection.usesRelay
          ? tr(context, '更新配对码', 'Update pairing code')
          : tr(context, '更新 token', 'Update token'),
    ),
    content: SizedBox(
      width: 420,
      child: widget.connection.usesRelay
          ? TextField(
              selectionControls: rizTextSelectionControls,
              magnifierConfiguration: rizTextMagnifierConfiguration,
              controller: pairingCode,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: tr(context, '完整配对码', 'Full pairing code'),
                hintText: 'riz1...',
                helperText: tr(
                  context,
                  '同时更新中继地址和两项连接凭据',
                  'Updates the relay URL and both credentials',
                ),
              ),
              onSubmitted: busy ? null : (_) => _save(),
            )
          : TextField(
              selectionControls: rizTextSelectionControls,
              magnifierConfiguration: rizTextMagnifierConfiguration,
              controller: token,
              autofocus: true,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Token',
                helperText: widget.connection.name,
              ),
              onSubmitted: busy ? null : (_) => _save(),
            ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: Text(tr(context, '取消', 'Cancel')),
      ),
      FilledButton(
        onPressed: busy ? null : _save,
        child: busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(tr(context, '保存并重连', 'Save and reconnect')),
      ),
    ],
  );

  Future<void> _save() async {
    if (widget.connection.usesRelay
        ? pairingCode.text.trim().isEmpty
        : token.text.trim().isEmpty) {
      return;
    }
    setState(() => busy = true);
    try {
      final controller = ref.read(appControllerProvider.notifier);
      if (widget.connection.usesRelay) {
        await controller.updateConnectionPairing(
          widget.connection.id,
          decodePairingCode(pairingCode.text),
        );
      } else {
        await controller.updateConnectionToken(
          widget.connection.id,
          token.text,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
      setState(() => busy = false);
    }
  }
}

class _ProjectsView extends ConsumerStatefulWidget {
  const _ProjectsView();

  @override
  ConsumerState<_ProjectsView> createState() => _ProjectsViewState();
}

class _ProjectsViewState extends ConsumerState<_ProjectsView> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final project = state.selectedProject;
    final list = _ProjectList(
      projects: state.projects,
      selected: state.selectedProjectId,
    );
    if (state.isUnboundSession) {
      return state.isDraftSession
          ? const _ChatView()
          : _UnboundWorkspace(
              key: ValueKey(state.selectedSessionId),
              session: state.selectedSession!,
            );
    }
    if (project == null) {
      return context.isExpanded ? const _DesktopProjectPrompt() : list;
    }
    return _ProjectWorkspace(key: ValueKey(project['id']), project: project);
  }
}

class _UnboundWorkspace extends StatefulWidget {
  const _UnboundWorkspace({super.key, required this.session});

  final Map<String, dynamic> session;

  @override
  State<_UnboundWorkspace> createState() => _UnboundWorkspaceState();
}

class _UnboundWorkspaceState extends State<_UnboundWorkspace>
    with SingleTickerProviderStateMixin {
  late final TabController tabs;

  @override
  void initState() {
    super.initState();
    tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessionWorkspacePath = widget.session['workspacePath']?.toString();
    final runtimePath = sessionWorkspacePath == null
        ? null
        : '$sessionWorkspacePath/runtime';
    final items = [
      Tab(
        child: _CompactTab(
          icon: Icons.chat_bubble_outline,
          label: tr(context, '聊天', 'Chat'),
        ),
      ),
      Tab(
        child: _CompactTab(
          icon: Icons.folder_copy_outlined,
          label: tr(context, '文件', 'Files'),
        ),
      ),
      Tab(
        child: _CompactTab(
          icon: Icons.terminal,
          label: tr(context, '终端', 'Terminal'),
        ),
      ),
    ];
    return Column(
      children: [
        Material(
          color: context.colors.surfaceContainerLow,
          child: Align(
            alignment: Alignment.centerLeft,
            child: TabBar(controller: tabs, isScrollable: true, tabs: items),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: tabs,
            children: [
              const _ChatView(),
              if (runtimePath != null)
                _FilesPane(root: runtimePath)
              else
                const _WorkspaceUnavailable(),
              if (runtimePath != null)
                _TerminalPane(cwd: runtimePath)
              else
                const _WorkspaceUnavailable(),
            ],
          ),
        ),
      ],
    );
  }
}

class _WorkspaceUnavailable extends StatelessWidget {
  const _WorkspaceUnavailable();

  @override
  Widget build(BuildContext context) =>
      Center(child: Text(tr(context, '工作区不可用', 'Workspace unavailable')));
}

class _DesktopProjectPrompt extends StatelessWidget {
  const _DesktopProjectPrompt();

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.folder_open_outlined,
          size: 32,
          color: context.colors.outline,
        ),
        const SizedBox(height: 12),
        Text(
          tr(context, '从侧栏选择项目', 'Choose a project from the sidebar'),
          style: context.text.titleMedium,
        ),
      ],
    ),
  );
}

class _ProjectList extends ConsumerWidget {
  const _ProjectList({required this.projects, required this.selected});
  final List<Map<String, dynamic>> projects;
  final String? selected;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                tr(context, '项目', 'Projects'),
                style: context.text.titleLarge,
              ),
            ),
            IconButton(
              tooltip: tr(context, '添加文件夹', 'Add folder'),
              onPressed: () => showDialog(
                context: context,
                builder: (_) => const _RemoteFolderDialog(),
              ),
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
          ],
        ),
      ),
      Expanded(
        child: projects.isEmpty
            ? Center(child: Text(tr(context, '还没有项目', 'No projects yet')))
            : ListView.builder(
                itemCount: projects.length,
                itemBuilder: (context, index) {
                  final p = projects[index];
                  return ListTile(
                    selected: p['id'] == selected,
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(p['name'] as String),
                    subtitle: Text(
                      _projectFolderSummary(context, p),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => ref
                        .read(appControllerProvider.notifier)
                        .selectProject(p['id'] as String),
                  );
                },
              ),
      ),
    ],
  );
}

String _projectFolderSummary(
  BuildContext context,
  Map<String, dynamic> project,
) {
  final folders = project['folders'] as List? ?? const [];
  if (folders.isEmpty) {
    return tr(context, '尚未绑定文件夹', 'No folders bound');
  }
  if (folders.length == 1) {
    return (folders.first as Map)['path']?.toString() ??
        tr(context, '1 个文件夹', '1 folder');
  }
  return tr(
    context,
    '${folders.length} 个平级文件夹',
    '${folders.length} peer folders',
  );
}

class _ProjectTreeSidebar extends ConsumerWidget {
  const _ProjectTreeSidebar({
    required this.projects,
    required this.selected,
    this.inDrawer = false,
  });

  final List<Map<String, dynamic>> projects;
  final String? selected;
  final bool inDrawer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final ctl = ref.read(appControllerProvider.notifier);
    final projectSessions = state.sessions
        .where((session) => session['projectId'] == selected)
        .toList();
    final sessions = projectSessions
        .where((session) => session['archivedAt'] == null)
        .toList();
    final archived = projectSessions
        .where((session) => session['archivedAt'] != null)
        .toList();
    final quickChatSessions = state.quickChatSessions
        .where((session) => session['archivedAt'] == null)
        .toList();
    void closeDrawer() {
      if (inDrawer) Navigator.of(context).pop();
    }

    return Material(
      color: context.colors.surfaceContainerLowest,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Text('Riz', style: context.text.titleLarge),
                const SizedBox(width: 12),
                Expanded(child: _DaemonPicker(state: state)),
                IconButton(
                  tooltip: state.connected
                      ? tr(context, '刷新', 'Refresh')
                      : tr(context, '重新连接', 'Reconnect'),
                  onPressed: ctl.refreshOrReconnect,
                  icon: Icon(
                    state.connected
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_off_outlined,
                    color: state.connected
                        ? context.colors.primary
                        : context.colors.error,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr(context, '项目', 'Projects'),
                    style: context.text.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: tr(context, '添加文件夹', 'Add folder'),
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => const _RemoteFolderDialog(),
                  ),
                  icon: const Icon(Icons.create_new_folder_outlined),
                ),
              ],
            ),
          ),
          _SidebarDestination(
            icon: Icons.bolt_outlined,
            label: tr(context, '快速聊天', 'Quick chat'),
            selected:
                (state.draftSession != null &&
                    state.draftSession?['projectId'] == null) ||
                (state.selectedSession != null &&
                    state.selectedSession?['projectId'] == null),
            onTap: () {
              ctl.createSession(quickChat: true);
              closeDrawer();
            },
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 12),
              children: [
                if (quickChatSessions.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                    child: Text(
                      tr(context, '快速聊天', 'Quick chats'),
                      style: context.text.labelMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (final session in quickChatSessions)
                    ListTile(
                      minTileHeight: 44,
                      contentPadding: const EdgeInsets.only(left: 20, right: 4),
                      selected: session['id'] == state.selectedSessionId,
                      leading: _StatusIcon(
                        status: session['status'] as String,
                        compact: true,
                      ),
                      title: Text(
                        session['title'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: PopupMenuButton<String>(
                        tooltip: tr(context, '会话操作', 'Session actions'),
                        onSelected: (value) {
                          if (value == 'archive') {
                            ctl.archiveSession(session['id'], true);
                          }
                          if (value == 'move') {
                            _showMoveSessionDialog(context, ref, session);
                          }
                          if (value == 'delete') {
                            _confirmDeleteSession(context, ref, session);
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'move',
                            child: Text(tr(context, '加入项目', 'Move to project')),
                          ),
                          PopupMenuItem(
                            value: 'archive',
                            child: Text(tr(context, '归档', 'Archive')),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(tr(context, '删除', 'Delete')),
                          ),
                        ],
                      ),
                      onTap: () {
                        ctl.setNavigation(0);
                        ctl.selectProject(null);
                        ctl.selectSession(session['id'] as String);
                        closeDrawer();
                      },
                    ),
                  const Divider(height: 1),
                ],
                if (projects.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      tr(context, '还没有项目', 'No projects yet'),
                      textAlign: TextAlign.center,
                      style: context.text.bodyMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                for (final project in projects) ...[
                  Material(
                    color: project['id'] == selected
                        ? context.colors.secondaryContainer
                        : Colors.transparent,
                    child: ListTile(
                      minTileHeight: 48,
                      contentPadding: const EdgeInsets.only(left: 12, right: 4),
                      leading: Icon(
                        project['id'] == selected
                            ? Icons.folder_open_outlined
                            : Icons.folder_outlined,
                      ),
                      title: Text(
                        project['name'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: project['id'] == selected
                          ? Text(
                              _projectFolderSummary(context, project),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : null,
                      trailing: project['id'] == selected
                          ? IconButton(
                              tooltip: tr(context, '新会话', 'New session'),
                              onPressed: ctl.createSession,
                              icon: const Icon(Icons.add, size: 20),
                              visualDensity: VisualDensity.compact,
                            )
                          : null,
                      onTap: () {
                        ctl.setNavigation(0);
                        ctl.selectProject(project['id'] as String);
                        closeDrawer();
                      },
                    ),
                  ),
                  if (project['id'] == selected) ...[
                    if (sessions.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(52, 12, 16, 12),
                        child: Text(
                          tr(context, '创建会话开始工作', 'Create a session to start'),
                          style: context.text.bodySmall?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    for (final session in sessions)
                      ListTile(
                        minTileHeight: 48,
                        contentPadding: const EdgeInsets.only(
                          left: 20,
                          right: 4,
                        ),
                        selected: session['id'] == state.selectedSessionId,
                        leading: _StatusIcon(
                          status: session['status'] as String,
                          compact: true,
                        ),
                        title: Text(
                          session['title'] as String,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: PopupMenuButton<String>(
                          tooltip: tr(context, '会话操作', 'Session actions'),
                          onSelected: (value) {
                            if (value == 'archive') {
                              ctl.archiveSession(session['id'], true);
                            }
                            if (value == 'move') {
                              _showMoveSessionDialog(context, ref, session);
                            }
                            if (value == 'delete') {
                              _confirmDeleteSession(context, ref, session);
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'move',
                              child: Text(tr(context, '移动会话', 'Move session')),
                            ),
                            PopupMenuItem(
                              value: 'archive',
                              child: Text(tr(context, '归档', 'Archive')),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text(tr(context, '删除', 'Delete')),
                            ),
                          ],
                        ),
                        onTap: () {
                          ctl.setNavigation(0);
                          ctl.selectSession(session['id'] as String);
                          closeDrawer();
                        },
                      ),
                    if (archived.isNotEmpty)
                      ExpansionTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        tilePadding: const EdgeInsets.only(left: 20, right: 8),
                        leading: const Icon(Icons.archive_outlined, size: 20),
                        title: Text(
                          '${tr(context, '已归档', 'Archived')} (${archived.length})',
                          style: context.text.bodyMedium,
                        ),
                        children: [
                          for (final session in archived)
                            ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.only(
                                left: 44,
                                right: 8,
                              ),
                              title: Text(
                                session['title'] as String,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                tooltip: tr(context, '恢复', 'Restore'),
                                onPressed: () => ctl.archiveSession(
                                  session['id'] as String,
                                  false,
                                ),
                                icon: const Icon(
                                  Icons.unarchive_outlined,
                                  size: 20,
                                ),
                              ),
                            ),
                        ],
                      ),
                    const Divider(height: 1),
                  ],
                ],
              ],
            ),
          ),
          Divider(height: 1, color: context.colors.outlineVariant),
          _SidebarDestination(
            icon: Icons.monitor_heart_outlined,
            label: tr(context, '运行中的任务', 'Running tasks'),
            selected: state.navigationIndex == 1,
            onTap: () {
              ctl.setNavigation(1);
              closeDrawer();
            },
          ),
          _SidebarDestination(
            icon: Icons.extension_outlined,
            label: tr(context, '全局 Skills', 'Global skills'),
            selected: state.navigationIndex == 2,
            onTap: () {
              ctl.setNavigation(2);
              closeDrawer();
            },
          ),
          const _QuotaSidebarItem(),
          _SidebarDestination(
            icon: Icons.settings_outlined,
            label: tr(context, '设置', 'Settings'),
            selected: state.navigationIndex == 3,
            onTap: () {
              ctl.setNavigation(3);
              closeDrawer();
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SidebarDestination extends StatefulWidget {
  const _SidebarDestination({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SidebarDestination> createState() => _SidebarDestinationState();
}

class _SidebarDestinationState extends State<_SidebarDestination> {
  bool pressed = false;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
    child: AnimatedScale(
      scale: pressed ? .985 : 1,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
      child: Material(
        color: widget.selected
            ? context.colors.secondaryContainer
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          onHighlightChanged: (value) => setState(() => pressed = value),
          child: SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(widget.icon, size: 21),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(widget.label, style: context.text.labelLarge),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _QuotaSidebarItem extends ConsumerStatefulWidget {
  const _QuotaSidebarItem();

  @override
  ConsumerState<_QuotaSidebarItem> createState() => _QuotaSidebarItemState();
}

class _QuotaSidebarItemState extends ConsumerState<_QuotaSidebarItem> {
  bool refreshing = false;

  Future<void> refresh() async {
    if (refreshing) return;
    setState(() => refreshing = true);
    try {
      await ref.read(appControllerProvider.notifier).request('quota.get');
      await ref.read(appControllerProvider.notifier).refresh();
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final quota = ref.watch(appControllerProvider).snapshot['quota'] as Map?;
    final snapshot = quota?['snapshot'] as Map?;
    final values = (snapshot?['remainingPercentages'] as List? ?? const [])
        .whereType<num>()
        .map((value) => value.toDouble())
        .toList();
    final remaining = values.isEmpty
        ? null
        : values.reduce((left, right) => left < right ? left : right);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            builder: (_) => const FractionallySizedBox(
              heightFactor: .72,
              child: _QuotaView(),
            ),
          ),
          onLongPress: refresh,
          child: SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  refreshing
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.data_usage_outlined, size: 21),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                tr(context, '配额', 'Quota'),
                                style: context.text.labelLarge,
                              ),
                            ),
                            Text(
                              remaining == null
                                  ? tr(context, '读取', 'Fetch')
                                  : '${remaining.toStringAsFixed(0)}%',
                              style: context.text.labelMedium?.copyWith(
                                color: context.colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        LinearProgressIndicator(
                          minHeight: 3,
                          value: remaining == null
                              ? 0
                              : (remaining / 100).clamp(0, 1),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProjectWorkspace extends ConsumerStatefulWidget {
  const _ProjectWorkspace({super.key, required this.project});
  final Map<String, dynamic> project;
  @override
  ConsumerState<_ProjectWorkspace> createState() => _ProjectWorkspaceState();
}

class _ProjectWorkspaceState extends ConsumerState<_ProjectWorkspace>
    with SingleTickerProviderStateMixin {
  late TabController tabs;
  @override
  void initState() {
    super.initState();
    tabs = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctl = ref.read(appControllerProvider.notifier);
    final runtimePath = widget.project['runtimePath']?.toString();
    final tabItems = [
      Tab(
        height: 48,
        child: _CompactTab(
          icon: Icons.chat_bubble_outline,
          label: tr(context, '会话', 'Sessions'),
        ),
      ),
      Tab(
        height: 48,
        child: _CompactTab(
          icon: Icons.folder_copy_outlined,
          label: tr(context, '文件', 'Files'),
        ),
      ),
      Tab(
        height: 48,
        child: _CompactTab(
          icon: Icons.terminal,
          label: tr(context, '终端', 'Terminal'),
        ),
      ),
      const Tab(
        height: 48,
        child: _CompactTab(icon: Icons.extension_outlined, label: 'Skills'),
      ),
    ];
    return Column(
      children: [
        if (context.isExpanded)
          Material(
            color: context.colors.surfaceContainerLow,
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TabBar(
                      controller: tabs,
                      isScrollable: true,
                      tabs: tabItems,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: tr(context, '管理项目文件夹', 'Manage project folders'),
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) =>
                        _ProjectFoldersDialog(project: widget.project),
                  ),
                  icon: const Icon(Icons.folder_copy_outlined),
                ),
                IconButton(
                  tooltip: tr(context, '重命名项目', 'Rename project'),
                  onPressed: () =>
                      _showRenameProjectDialog(context, ref, widget.project),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: tr(context, '删除项目', 'Delete project'),
                  onPressed: () =>
                      _showDeleteProjectDialog(context, ref, widget.project),
                  icon: const Icon(Icons.delete_outline),
                ),
                IconButton(
                  tooltip: tr(context, '导入 agy 会话', 'Import agy conversation'),
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => _HistoryImportDialog(
                      projectId: widget.project['id'] as String,
                    ),
                  ),
                  icon: const Icon(Icons.history),
                ),
                IconButton(
                  tooltip: tr(context, '新会话', 'New session'),
                  onPressed: () => ctl.createSession(),
                  icon: const Icon(Icons.add_comment_outlined),
                ),
                const SizedBox(width: 4),
              ],
            ),
          )
        else ...[
          Material(
            color: context.colors.surfaceContainerLow,
            child: Row(
              children: [
                Expanded(
                  child: TabBar(
                    controller: tabs,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: tabItems,
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: tr(context, '项目操作', 'Project actions'),
                  onSelected: (value) {
                    if (value == 'new') ctl.createSession();
                    if (value == 'folders') {
                      showDialog(
                        context: context,
                        builder: (_) =>
                            _ProjectFoldersDialog(project: widget.project),
                      );
                    }
                    if (value == 'rename') {
                      _showRenameProjectDialog(context, ref, widget.project);
                    }
                    if (value == 'delete') {
                      _showDeleteProjectDialog(context, ref, widget.project);
                    }
                    if (value == 'import') {
                      showDialog(
                        context: context,
                        builder: (_) => _HistoryImportDialog(
                          projectId: widget.project['id'] as String,
                        ),
                      );
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'new',
                      child: ListTile(
                        leading: const Icon(Icons.add_comment_outlined),
                        title: Text(tr(context, '新会话', 'New session')),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'folders',
                      child: ListTile(
                        leading: const Icon(Icons.folder_copy_outlined),
                        title: Text(
                          tr(context, '管理项目文件夹', 'Manage project folders'),
                        ),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'rename',
                      child: ListTile(
                        leading: const Icon(Icons.edit_outlined),
                        title: Text(tr(context, '重命名项目', 'Rename project')),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'import',
                      child: ListTile(
                        leading: const Icon(Icons.history),
                        title: Text(
                          tr(context, '导入 agy 会话', 'Import agy conversation'),
                        ),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading: const Icon(Icons.delete_outline),
                        title: Text(tr(context, '删除项目', 'Delete project')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        Expanded(
          child: TabBarView(
            controller: tabs,
            children: [
              _SessionsPane(projectId: widget.project['id']),
              if (runtimePath != null)
                _FilesPane(root: runtimePath)
              else
                const _WorkspaceUnavailable(),
              if (runtimePath != null)
                _TerminalPane(projectId: widget.project['id'], cwd: runtimePath)
              else
                const _WorkspaceUnavailable(),
              _ProjectSkillsPane(project: widget.project),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProjectSkillsPane extends StatefulWidget {
  const _ProjectSkillsPane({required this.project});

  final Map<String, dynamic> project;

  @override
  State<_ProjectSkillsPane> createState() => _ProjectSkillsPaneState();
}

class _ProjectSkillsPaneState extends State<_ProjectSkillsPane> {
  String? selectedPath;

  List<String> get paths => (widget.project['folders'] as List? ?? const [])
      .cast<Map>()
      .map((folder) => folder['path']?.toString())
      .whereType<String>()
      .toList();

  @override
  Widget build(BuildContext context) {
    final available = paths;
    if (available.isEmpty) return const _ProjectNeedsFolder();
    final path = available.contains(selectedPath)
        ? selectedPath!
        : available.first;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: DropdownButtonFormField<String>(
            initialValue: path,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: tr(context, 'Skills 文件夹', 'Skills folder'),
              prefixIcon: const Icon(Icons.folder_outlined),
            ),
            items: [
              for (final item in available)
                DropdownMenuItem(
                  value: item,
                  child: Text(item, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) => setState(() => selectedPath = value),
          ),
        ),
        Expanded(
          child: _SkillsView(key: ValueKey(path), projectPath: path),
        ),
      ],
    );
  }
}

class _ProjectNeedsFolder extends StatelessWidget {
  const _ProjectNeedsFolder();

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      tr(context, '先为项目添加文件夹', 'Add a folder to this project first'),
      style: context.text.bodyLarge?.copyWith(
        color: context.colors.onSurfaceVariant,
      ),
    ),
  );
}

class _CompactTab extends StatelessWidget {
  const _CompactTab({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [Icon(icon, size: 19), const SizedBox(width: 6), Text(label)],
  );
}

class _SessionsPane extends ConsumerWidget {
  const _SessionsPane({required this.projectId});
  final String projectId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final ctl = ref.read(appControllerProvider.notifier);
    final sessions = state.sessions
        .where((s) => s['projectId'] == projectId && s['archivedAt'] == null)
        .toList();
    final archived = state.sessions
        .where((s) => s['projectId'] == projectId && s['archivedAt'] != null)
        .toList();
    final list = Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tr(context, '未归档会话', 'Unarchived sessions'),
                  style: context.text.titleMedium,
                ),
              ),
              IconButton(
                onPressed: () => ctl.createSession(),
                tooltip: tr(context, '新建', 'New'),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        Expanded(
          child: sessions.isEmpty && archived.isEmpty
              ? Center(
                  child: Text(
                    tr(context, '创建会话开始工作', 'Create a session to start'),
                  ),
                )
              : ListView(
                  children: [
                    for (final s in sessions)
                      ListTile(
                        selected: s['id'] == state.selectedSessionId,
                        leading: _StatusIcon(status: s['status'] as String),
                        title: Text(s['title'] as String),
                        subtitle: Text(
                          _statusLabel(context, s['status'] as String),
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'archive') {
                              ctl.archiveSession(s['id'], true);
                            }
                            if (v == 'delete') {
                              _confirmDeleteSession(context, ref, s);
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'archive',
                              child: Text(tr(context, '归档', 'Archive')),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text(tr(context, '删除', 'Delete')),
                            ),
                          ],
                        ),
                        onTap: () => ctl.selectSession(s['id'] as String),
                      ),
                    if (archived.isNotEmpty)
                      ExpansionTile(
                        leading: const Icon(Icons.archive_outlined),
                        title: Text(
                          '${tr(context, '已归档', 'Archived')} (${archived.length})',
                        ),
                        children: [
                          for (final s in archived)
                            ListTile(
                              leading: const Icon(Icons.chat_bubble_outline),
                              title: Text(s['title'] as String),
                              subtitle: Text(
                                _statusLabel(context, s['status'] as String),
                              ),
                              trailing: IconButton(
                                tooltip: tr(context, '恢复', 'Restore'),
                                onPressed: () =>
                                    ctl.archiveSession(s['id'], false),
                                icon: const Icon(Icons.unarchive_outlined),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
        ),
      ],
    );
    if (context.isExpanded) {
      return state.activeSession == null
          ? Center(child: Text(tr(context, '选择会话', 'Select a session')))
          : const _ChatView();
    }
    return state.activeSession == null ? list : const _ChatView();
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status, this.compact = false});
  final String status;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final running = [
      'running',
      'queued',
      'waiting_permission',
      'waiting_input',
    ].contains(status);
    return Icon(
      running
          ? Icons.pending_outlined
          : status == 'failed'
          ? Icons.error_outline
          : status == 'interrupted'
          ? Icons.warning_amber
          : Icons.check_circle_outline,
      color: running
          ? context.colors.primary
          : status == 'failed'
          ? context.colors.error
          : context.colors.outline,
      size: compact ? 18 : null,
    );
  }
}

String _statusLabel(BuildContext c, String s) => switch (s) {
  'queued' => tr(c, '已排队', 'Queued'),
  'running' => tr(c, '运行中', 'Running'),
  'waiting_permission' => tr(c, '等待授权', 'Waiting for permission'),
  'waiting_input' => tr(c, '等待输入', 'Waiting for input'),
  'failed' => tr(c, '失败', 'Failed'),
  'interrupted' => tr(c, '已中断', 'Interrupted'),
  'cancelled' => tr(c, '已取消', 'Cancelled'),
  _ => tr(c, '空闲', 'Idle'),
};

class _ChatView extends ConsumerStatefulWidget {
  const _ChatView();
  @override
  ConsumerState<_ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<_ChatView> {
  final composer = TextEditingController();
  final scroll = ScrollController();
  final attachments = <Map<String, dynamic>>[];
  final slashItems = <Map<String, dynamic>>[];
  final models = <Map<String, dynamic>>[];
  String delivery = 'queue';
  String? slashContext;
  String? optionSessionId;
  String? selectedModel;
  bool sending = false;
  bool modelsLoading = true;
  String? modelsError;
  Future<void>? modelLoad;

  @override
  void initState() {
    super.initState();
    composer.addListener(() => setState(() {}));
    Future.microtask(loadSlashItems);
  }

  Future<void> loadSlashItems() async {
    await Future.wait([loadCommands(), loadSkills(), loadModels()]);
  }

  Future<void> loadCommands() async {
    try {
      final commands = await ref
          .read(appControllerProvider.notifier)
          .request('provider.commands');
      slashItems
        ..removeWhere((item) => item['kind'] == 'command')
        ..addAll(
          (commands['commands'] as List).cast<Map>().map(
            (e) => {...e.cast<String, dynamic>(), 'kind': 'command'},
          ),
        );
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> loadSkills() async {
    try {
      final skills = await ref
          .read(appControllerProvider.notifier)
          .request('skill.list');
      slashItems
        ..removeWhere((item) => item['kind'] == 'skill')
        ..addAll(
          (skills['skills'] as List).cast<Map>().map(
            (e) => {...e.cast<String, dynamic>(), 'kind': 'skill'},
          ),
        );
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> loadModels() {
    final active = modelLoad;
    if (active != null) return active;
    late final Future<void> tracked;
    tracked = _loadModels().whenComplete(() {
      if (identical(modelLoad, tracked)) modelLoad = null;
    });
    modelLoad = tracked;
    return tracked;
  }

  Future<void> _loadModels() async {
    if (mounted) {
      setState(() {
        modelsLoading = true;
        modelsError = null;
      });
    }
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final response = await ref
            .read(appControllerProvider.notifier)
            .request('provider.models');
        final loaded = (response['models'] as List)
            .cast<Map>()
            .map((model) => model.cast<String, dynamic>())
            .toList();
        if (loaded.isEmpty) throw StateError('provider returned no models');
        models
          ..clear()
          ..addAll(loaded);
        if (mounted) {
          setState(() {
            modelsLoading = false;
            modelsError = null;
          });
        }
        return;
      } catch (error) {
        lastError = error;
      }
    }
    if (mounted) {
      setState(() {
        modelsLoading = false;
        modelsError = lastError.toString();
      });
    }
  }

  Future<void> openModelMenu(BuildContext anchorContext) async {
    if (models.isEmpty) await loadModels();
    if (!mounted || !anchorContext.mounted) return;

    final anchor = anchorContext.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (anchor == null || overlay == null) return;
    final offset = anchor.localToGlobal(Offset.zero, ancestor: overlay);
    final selection = await showMenu<String>(
      context: context,
      initialValue: selectedModel ?? '',
      position: RelativeRect.fromRect(
        offset & anchor.size,
        Offset.zero & overlay.size,
      ),
      items: [
        CheckedPopupMenuItem(
          value: '',
          checked: selectedModel == null,
          child: Text(tr(context, '默认模型', 'Default model')),
        ),
        for (final model in models)
          CheckedPopupMenuItem(
            value: model['id'] as String,
            checked: selectedModel == model['id'],
            child: Text(model['name'] as String),
          ),
        if (modelsError != null && models.isEmpty)
          PopupMenuItem<String>(
            value: '__retry__',
            child: Row(
              children: [
                const Icon(Icons.refresh, size: 18),
                const SizedBox(width: 10),
                Text(tr(context, '获取失败，重试', 'Failed, retry')),
              ],
            ),
          ),
      ],
    );
    if (!mounted || selection == null) return;
    if (selection == '__retry__') {
      await loadModels();
      if (anchorContext.mounted) await openModelMenu(anchorContext);
      return;
    }
    setState(() => selectedModel = selection.isEmpty ? null : selection);
  }

  @override
  void dispose() {
    composer.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> pickImage() async {
    final image = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 92,
    );
    if (image == null) return;
    final bytes = await image.readAsBytes();
    final state = ref.read(appControllerProvider);
    if (state.activeSession == null) return;
    setState(
      () => attachments.add({
        'name': image.name,
        'mimeType': image.mimeType ?? 'image/jpeg',
        'bytes': bytes,
        'size': bytes.length,
      }),
    );
  }

  Future<void> setPermissionMode(String mode) async {
    if (mode == 'full') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded),
          title: Text(tr(context, '启用完全访问？', 'Enable full access?')),
          content: Text(
            tr(
              context,
              'agy 将跳过所有权限确认，并能使用当前账户访问整台电脑。仅在你信任当前任务时启用。',
              'agy will skip every permission prompt and can access the computer as your current user. Only enable this for a task you trust.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, '取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, '启用完全访问', 'Enable full access')),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    try {
      await ref.read(appControllerProvider.notifier).setPermissionMode(mode);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              mode == 'full'
                  ? tr(context, '已启用完全访问', 'Full access enabled')
                  : tr(context, '权限模式已更新', 'Permission mode updated'),
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final ctl = ref.read(appControllerProvider.notifier);
    final session = state.activeSession!;
    if (optionSessionId != session['id']) {
      optionSessionId = session['id'] as String;
      selectedModel = null;
    }
    final nextSlashContext =
        '${state.activeConnectionId}:${state.connected}:${state.selectedProjectId}';
    if (slashContext != nextSlashContext) {
      slashContext = nextSlashContext;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) loadSlashItems();
      });
    }
    ref.listen(
      appControllerProvider.select(
        (value) => (value.selectedSessionId, value.messages.length),
      ),
      (_, _) => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !scroll.hasClients) return;
        scroll.animateTo(
          scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }),
    );
    final permissionMode = session['permissionMode']?.toString() ?? 'ask';
    final running = [
      'running',
      'queued',
      'waiting_permission',
      'waiting_input',
    ].contains(session['status']);
    return Column(
      children: [
        if (context.isExpanded)
          SizedBox(
            height: 44,
            child: Material(
              color: context.colors.surfaceContainerLow,
              child: Row(
                children: [
                  if (!context.isExpanded)
                    IconButton(
                      tooltip: tr(context, '返回会话列表', 'Back to sessions'),
                      onPressed: () => ctl.selectSession(null),
                      icon: const Icon(Icons.arrow_back),
                    )
                  else ...[
                    const SizedBox(width: 12),
                    const Icon(Icons.smart_toy_outlined, size: 20),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            session['title'],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.titleSmall,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _statusLabel(context, session['status']),
                          style: context.text.bodySmall?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (running)
                    IconButton(
                      tooltip: tr(context, '停止', 'Stop'),
                      onPressed: ctl.stopSession,
                      icon: const Icon(Icons.stop_circle_outlined),
                    ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        Expanded(
          child: state.sessionLoading
              ? const _SessionLoadingView()
              : state.messages.isEmpty
              ? Center(
                  child: Text(tr(context, '发送第一条消息', 'Send the first message')),
                )
              : ListView.builder(
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  itemCount: state.messages.length,
                  itemBuilder: (context, i) => Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1040),
                      child: _MessageEntrance(
                        key: ValueKey(state.messages[i]['id'] ?? i),
                        child: _MessageView(message: state.messages[i]),
                      ),
                    ),
                  ),
                ),
        ),
        if (state.pendingPermission case final permission?)
          Material(
            color: context.colors.tertiaryContainer,
            child: ExpansionTile(
              leading: const Icon(Icons.shield_outlined),
              title: Text(
                permission['question']?.toString() ??
                    tr(context, 'agy 请求执行工具操作', 'agy requests a tool action'),
              ),
              subtitle: Text(
                tr(
                  context,
                  '请检查详情后允许或拒绝',
                  'Review the details, then allow or deny',
                ),
              ),
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: SelectableText(
                      selectionControls: rizTextSelectionControls,
                      magnifierConfiguration: rizTextMagnifierConfiguration,
                      permission['detail']?.toString() ?? '',
                      style: context.text.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => ctl.respondPermission(false),
                        icon: const Icon(Icons.close),
                        label: Text(tr(context, '拒绝', 'Deny')),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: () => ctl.respondPermission(true),
                        icon: const Icon(Icons.check),
                        label: Text(tr(context, '允许', 'Allow')),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (state.pendingInput case final input?)
          _InputRequestPanel(input: input, onSubmit: ctl.respondInput),
        if (composer.text.startsWith('/'))
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: Material(
              color: context.colors.surfaceContainerHigh,
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final item in slashItems.where((item) {
                    final query = composer.text.substring(1).toLowerCase();
                    return item['name'].toString().toLowerCase().contains(
                      query,
                    );
                  }))
                    ListTile(
                      dense: true,
                      leading: Icon(
                        item['kind'] == 'skill'
                            ? Icons.extension_outlined
                            : Icons.keyboard_command_key,
                      ),
                      title: Text(item['name'].toString()),
                      subtitle: Text(item['description']?.toString() ?? ''),
                      onTap: () {
                        composer.text = item['kind'] == 'skill'
                            ? 'Use the "${item['name']}" skill to '
                            : '${item['name']} ';
                        composer.selection = TextSelection.collapsed(
                          offset: composer.text.length,
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Container(
                  decoration: BoxDecoration(
                    color: context.colors.surfaceContainerLow,
                    border: Border.all(color: context.colors.outlineVariant),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (attachments.isNotEmpty)
                        SizedBox(
                          height: 82,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
                            itemCount: attachments.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 8),
                            itemBuilder: (context, index) =>
                                _LocalAttachmentPreview(
                                  attachment: attachments[index],
                                  onRemove: () => setState(
                                    () => attachments.removeAt(index),
                                  ),
                                ),
                          ),
                        ),
                      AdaptiveComposerField(
                        controller: composer,
                        hintText: running
                            ? tr(context, '排队下一条消息…', 'Queue a follow-up…')
                            : tr(
                                context,
                                '发送消息或 / 命令…',
                                'Message or / command…',
                              ),
                      ),
                      Row(
                        children: [
                          IconButton(
                            tooltip: tr(context, '添加图片', 'Attach image'),
                            onPressed: pickImage,
                            icon: const Icon(
                              Icons.add_photo_alternate_outlined,
                            ),
                          ),
                          PopupMenuButton<String>(
                            tooltip: tr(context, '权限模式', 'Permission mode'),
                            initialValue: permissionMode,
                            onSelected: setPermissionMode,
                            icon: Icon(switch (permissionMode) {
                              'workspace' => Icons.shield_outlined,
                              'full' => Icons.gpp_maybe_outlined,
                              _ => Icons.pan_tool_outlined,
                            }),
                            itemBuilder: (context) => [
                              _permissionMenuItem(
                                context,
                                value: 'ask',
                                checked: permissionMode == 'ask',
                                icon: Icons.pan_tool_outlined,
                                title: tr(context, '请求批准', 'Ask for approval'),
                                subtitle: tr(
                                  context,
                                  '编辑外部文件和使用互联网前始终询问',
                                  'Always ask before external edits and network access',
                                ),
                              ),
                              _permissionMenuItem(
                                context,
                                value: 'workspace',
                                checked: permissionMode == 'workspace',
                                icon: Icons.shield_outlined,
                                title: tr(context, '替我批准', 'Approve for me'),
                                subtitle: tr(
                                  context,
                                  '自动批准项目内常规编辑，其他操作仍询问',
                                  'Approve routine project edits; ask for other actions',
                                ),
                              ),
                              _permissionMenuItem(
                                context,
                                value: 'full',
                                checked: permissionMode == 'full',
                                icon: Icons.gpp_maybe_outlined,
                                title: tr(context, '完全访问', 'Full access'),
                                subtitle: tr(
                                  context,
                                  '完全访问计算机（风险较高）',
                                  'Full computer access (higher risk)',
                                ),
                              ),
                            ],
                          ),
                          Builder(
                            builder: (buttonContext) => Tooltip(
                              message:
                                  selectedModel ??
                                  tr(context, '默认模型', 'Default model'),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => openModelMenu(buttonContext),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 190,
                                    minHeight: 48,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          selectedModel == null
                                              ? Icons.model_training_outlined
                                              : Icons.model_training,
                                          size: 20,
                                        ),
                                        const SizedBox(width: 6),
                                        Flexible(
                                          child: Text(
                                            selectedModel ??
                                                tr(
                                                  context,
                                                  '默认模型',
                                                  'Default model',
                                                ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: context.text.labelMedium,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        if (modelsLoading && models.isEmpty)
                                          const SizedBox.square(
                                            dimension: 14,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        else
                                          const Icon(
                                            Icons.arrow_drop_down,
                                            size: 18,
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const Spacer(),
                          if (running)
                            PopupMenuButton<String>(
                              tooltip: tr(context, '发送方式', 'Delivery mode'),
                              initialValue: delivery,
                              onSelected: (value) =>
                                  setState(() => delivery = value),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      delivery == 'queue'
                                          ? tr(context, '排队', 'Queue')
                                          : tr(context, '引导', 'Steer'),
                                      style: context.text.labelMedium,
                                    ),
                                    const Icon(Icons.arrow_drop_down, size: 18),
                                  ],
                                ),
                              ),
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  value: 'queue',
                                  child: Text(tr(context, '排队', 'Queue')),
                                ),
                                PopupMenuItem(
                                  value: 'steer',
                                  enabled: false,
                                  child: Text(
                                    tr(
                                      context,
                                      '引导（agy 不支持）',
                                      'Steer (unsupported by agy)',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          IconButton.filled(
                            tooltip: tr(context, '发送', 'Send'),
                            onPressed: sending
                                ? null
                                : () async {
                                    if (composer.text.trim().isEmpty &&
                                        attachments.isEmpty) {
                                      return;
                                    }
                                    setState(() => sending = true);
                                    final text = composer.text;
                                    composer.clear();
                                    final files = attachments
                                        .map((attachment) => {...attachment})
                                        .toList();
                                    attachments.clear();
                                    try {
                                      await ctl.sendMessage(
                                        text,
                                        attachments: files,
                                        mode: delivery,
                                        model: selectedModel,
                                      );
                                    } catch (error) {
                                      if (context.mounted) {
                                        composer.text = text;
                                        setState(
                                          () => attachments.insertAll(0, files),
                                        );
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(error.toString()),
                                          ),
                                        );
                                      }
                                    } finally {
                                      if (mounted) {
                                        setState(() => sending = false);
                                      }
                                    }
                                  },
                            icon: sending
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.arrow_upward),
                          ),
                          const SizedBox(width: 6),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SessionLoadingView extends StatelessWidget {
  const _SessionLoadingView();

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(height: 12),
        Text(
          tr(context, '正在载入会话…', 'Loading conversation…'),
          style: context.text.bodyMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

class _LocalAttachmentPreview extends StatelessWidget {
  const _LocalAttachmentPreview({
    required this.attachment,
    required this.onRemove,
  });

  final Map<String, dynamic> attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final bytes = attachment['bytes'] as Uint8List;
    return SizedBox(
      width: 150,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(6),
              ),
              child: Image.memory(
                bytes,
                width: 60,
                height: 68,
                fit: BoxFit.cover,
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  attachment['name']?.toString() ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.labelSmall,
                ),
              ),
            ),
            IconButton(
              tooltip: tr(context, '移除', 'Remove'),
              visualDensity: VisualDensity.compact,
              onPressed: onRemove,
              icon: const Icon(Icons.close, size: 16),
            ),
          ],
        ),
      ),
    );
  }
}

class _InputRequestPanel extends StatefulWidget {
  const _InputRequestPanel({required this.input, required this.onSubmit});

  final Map<String, dynamic> input;
  final Future<void> Function(List<int>) onSubmit;

  @override
  State<_InputRequestPanel> createState() => _InputRequestPanelState();
}

class _InputRequestPanelState extends State<_InputRequestPanel> {
  final selected = <int>{};
  bool submitting = false;

  @override
  Widget build(BuildContext context) {
    final options = (widget.input['options'] as List? ?? const [])
        .map((option) => option.toString())
        .toList();
    final multi = widget.input['multiSelect'] == true;
    return Material(
      color: context.colors.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.help_outline, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.input['question']?.toString() ?? '',
                    style: context.text.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (var index = 0; index < options.length; index++)
                  ChoiceChip(
                    label: Text(options[index]),
                    selected: selected.contains(index),
                    onSelected: (value) => setState(() {
                      if (!multi) selected.clear();
                      value ? selected.add(index) : selected.remove(index);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: selected.isEmpty || submitting
                    ? null
                    : () async {
                        setState(() => submitting = true);
                        try {
                          await widget.onSubmit(selected.toList()..sort());
                        } finally {
                          if (mounted) setState(() => submitting = false);
                        }
                      },
                child: submitting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(tr(context, '回答', 'Answer')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

CheckedPopupMenuItem<String> _permissionMenuItem(
  BuildContext context, {
  required String value,
  required bool checked,
  required IconData icon,
  required String title,
  required String subtitle,
}) => CheckedPopupMenuItem(
  value: value,
  checked: checked,
  child: ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
  ),
);

class _MessageView extends ConsumerWidget {
  const _MessageView({required this.message});
  final Map<String, dynamic> message;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = message['role'] == 'user';
    final content =
        (message['content'] as Map?)?.cast<String, dynamic>() ??
        {'text': message['content'].toString()};
    final text = content['text']?.toString() ?? '';
    final structured = (content['structuredEvents'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .where((e) => !const {'user', 'text', 'title'}.contains(e['type']))
        .toList();
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: user ? 720 : 1040),
        margin: const EdgeInsets.only(bottom: 12),
        padding: user
            ? const EdgeInsets.symmetric(horizontal: 14, vertical: 10)
            : const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: user ? context.colors.surfaceContainerHigh : null,
          borderRadius: user ? BorderRadius.circular(8) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!user) ...[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.smart_toy_outlined, size: 16),
                  const SizedBox(width: 6),
                  Text('agy', style: context.text.labelMedium),
                ],
              ),
              const SizedBox(height: 6),
            ],
            if (user)
              for (final attachment
                  in (content['attachments'] as List? ?? const [])
                      .whereType<Map>())
                _RemoteImageAttachment(
                  attachment: attachment.cast<String, dynamic>(),
                ),
            if (structured.isNotEmpty) _AgentActivityView(events: structured),
            MarkdownBody(data: text, selectable: true),
            if (content['diagnostic'] != null)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(tr(context, '诊断', 'Diagnostics')),
                children: [
                  SelectableText(
                    content['diagnostic'].toString(),
                    selectionControls: rizTextSelectionControls,
                    magnifierConfiguration: rizTextMagnifierConfiguration,
                  ),
                ],
              ),
            if (message['status'] == 'queued')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr(context, '等待处理', 'Waiting'),
                      style: context.text.labelSmall?.copyWith(
                        color: context.colors.primary,
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: tr(context, '撤回', 'Remove from queue'),
                      onPressed: () async {
                        await ref.read(appControllerProvider.notifier).request(
                          'session.queue.remove',
                          {'messageId': message['id']},
                        );
                        final sessionId = ref
                            .read(appControllerProvider)
                            .selectedSessionId;
                        if (sessionId != null) {
                          await ref
                              .read(appControllerProvider.notifier)
                              .selectSession(sessionId);
                        }
                      },
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MessageEntrance extends StatelessWidget {
  const _MessageEntrance({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - value)),
          child: Transform.scale(
            scale: .99 + (.01 * value),
            alignment: Alignment.bottomCenter,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _RemoteImageAttachment extends ConsumerStatefulWidget {
  const _RemoteImageAttachment({required this.attachment});

  final Map<String, dynamic> attachment;

  @override
  ConsumerState<_RemoteImageAttachment> createState() =>
      _RemoteImageAttachmentState();
}

class _RemoteImageAttachmentState
    extends ConsumerState<_RemoteImageAttachment> {
  Future<Uint8List?>? preview;

  @override
  void initState() {
    super.initState();
    preview = _load();
  }

  Future<Uint8List?> _load() async {
    final mime = widget.attachment['mimeType']?.toString() ?? '';
    final path = widget.attachment['path']?.toString();
    if (!mime.startsWith('image/') || path == null) return null;
    final response = await ref.read(appControllerProvider.notifier).request(
      'fs.read',
      {'path': path},
    );
    final encoded = response['base64']?.toString();
    return encoded == null ? null : base64Decode(encoded);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: preview,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes == null) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.attach_file, size: 16),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  widget.attachment['name']?.toString() ??
                      widget.attachment['path']?.toString() ??
                      '',
                  overflow: TextOverflow.ellipsis,
                  style: context.text.labelMedium,
                ),
              ),
            ],
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            bytes,
            width: 240,
            height: 180,
            fit: BoxFit.cover,
          ),
        ),
      );
    },
  );
}

class _AgentActivityView extends StatelessWidget {
  const _AgentActivityView({required this.events});

  final List<Map<String, dynamic>> events;

  @override
  Widget build(BuildContext context) {
    final completed = events
        .where((event) => _eventComplete(event['status']))
        .length;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: context.colors.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: ExpansionTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        minTileHeight: 38,
        tilePadding: const EdgeInsets.symmetric(horizontal: 10),
        childrenPadding: const EdgeInsets.only(bottom: 4),
        leading: const Icon(Icons.bolt_outlined, size: 18),
        title: Text(
          tr(context, '${events.length} 项活动', '${events.length} activities'),
          style: context.text.labelMedium,
        ),
        subtitle: completed == 0
            ? null
            : Text(
                tr(context, '$completed 项已完成', '$completed completed'),
                style: context.text.labelSmall,
              ),
        children: [
          for (final event in events) _StructuredEventView(event: event),
        ],
      ),
    );
  }
}

bool _eventComplete(dynamic status) {
  final value = status?.toString().toLowerCase() ?? '';
  return const {
    'done',
    'completed',
    'success',
    'succeeded',
    '9',
  }.contains(value);
}

class _StructuredEventView extends StatelessWidget {
  const _StructuredEventView({required this.event});
  final Map<String, dynamic> event;
  @override
  Widget build(BuildContext context) {
    final type = event['type']?.toString() ?? 'tool';
    final thinking = type == 'thinking' || type == 'reasoning';
    final edit = type == 'edit' || type == 'diff';
    final icon = thinking
        ? Icons.psychology_outlined
        : edit
        ? Icons.difference_outlined
        : type == 'command'
        ? Icons.terminal
        : Icons.build_outlined;
    final label = thinking
        ? tr(context, '思考', 'Thinking')
        : edit
        ? tr(context, '文件修改', 'File changes')
        : type == 'command'
        ? tr(context, '命令', 'Command')
        : tr(context, '工具调用', 'Tool call');
    final name = event['name']?.toString();
    final title = name?.isNotEmpty == true ? name! : label;
    return ExpansionTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      minTileHeight: 36,
      initiallyExpanded: false,
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      childrenPadding: const EdgeInsets.fromLTRB(32, 0, 8, 8),
      leading: Icon(icon, size: 18),
      title: Text(title, style: context.text.labelMedium),
      trailing: Icon(
        _eventComplete(event['status'])
            ? Icons.check_circle_outline
            : Icons.expand_more,
        size: 16,
        color: context.colors.onSurfaceVariant,
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(
            event['text']?.toString() ?? jsonEncode(event),
            selectionControls: rizTextSelectionControls,
            magnifierConfiguration: rizTextMagnifierConfiguration,
          ),
        ),
      ],
    );
  }
}

Future<void> _showRenameProjectDialog(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> project,
) async {
  final controller = TextEditingController(
    text: project['customName']?.toString() ?? '',
  );
  final name = await showDialog<String?>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(tr(context, '重命名项目', 'Rename project')),
      content: TextField(
        selectionControls: rizTextSelectionControls,
        magnifierConfiguration: rizTextMagnifierConfiguration,
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: tr(context, '项目名称', 'Project name'),
          hintText: project['name']?.toString(),
        ),
        onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(tr(context, '取消', 'Cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, ''),
          child: Text(tr(context, '跟随文件夹', 'Use folder name')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
          child: Text(tr(context, '保存', 'Save')),
        ),
      ],
    ),
  );
  controller.dispose();
  if (name == null || !context.mounted) return;
  await ref
      .read(appControllerProvider.notifier)
      .renameProject(project['id'] as String, name.isEmpty ? null : name);
}

Future<void> _showDeleteProjectDialog(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> project,
) async {
  final mode = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(tr(context, '删除项目', 'Delete project')),
      content: Text(
        tr(
          context,
          '可以仅删除项目并保留会话，或同时删除项目中的所有会话。绑定的文件夹不会被删除。',
          'Keep its sessions as quick chats, or delete every session in the project too. Bound folders are never deleted.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(tr(context, '取消', 'Cancel')),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(dialogContext, 'detach'),
          child: Text(tr(context, '保留会话', 'Keep sessions')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, 'delete'),
          child: Text(tr(context, '删除项目和会话', 'Delete project and sessions')),
        ),
      ],
    ),
  );
  if (mode == null || !context.mounted) return;
  await ref
      .read(appControllerProvider.notifier)
      .deleteProject(project['id'] as String, deleteSessions: mode == 'delete');
}

Future<void> _showMoveSessionDialog(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> session,
) async {
  final state = ref.read(appControllerProvider);
  final currentProjectId = session['projectId'] as String?;
  final target = await showDialog<String?>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(tr(context, '移动会话', 'Move session')),
      children: [
        if (currentProjectId != null)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, ''),
            child: ListTile(
              leading: const Icon(Icons.bolt_outlined),
              title: Text(tr(context, '移出项目', 'Move to quick chats')),
            ),
          ),
        for (final project in state.projects)
          if (project['id'] != currentProjectId)
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(dialogContext, project['id'] as String),
              child: ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(project['name'] as String),
                subtitle: Text(
                  _projectFolderSummary(context, project),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
      ],
    ),
  );
  if (target == null || !context.mounted) return;
  await ref
      .read(appControllerProvider.notifier)
      .moveSession(session['id'] as String, target.isEmpty ? null : target);
}

Future<void> _confirmDeleteSession(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> session,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(tr(context, '删除会话', 'Delete session')),
      content: Text(
        tr(
          context,
          '“${session['title']}” 的消息和运行时文件将被永久删除。',
          'Messages and runtime files for “${session['title']}” will be permanently deleted.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(tr(context, '取消', 'Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(tr(context, '删除', 'Delete')),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  await ref
      .read(appControllerProvider.notifier)
      .deleteSession(session['id'] as String);
}

class _RemoteFolderDialog extends ConsumerStatefulWidget {
  const _RemoteFolderDialog({this.projectId});
  final String? projectId;
  @override
  ConsumerState<_RemoteFolderDialog> createState() =>
      _RemoteFolderDialogState();
}

class _ProjectFoldersDialog extends ConsumerWidget {
  const _ProjectFoldersDialog({required this.project});

  final Map<String, dynamic> project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = (project['folders'] as List? ?? const [])
        .cast<Map>()
        .map((folder) => folder.cast<String, dynamic>())
        .toList();
    final projectId = project['id'] as String;
    return AlertDialog(
      title: Text(tr(context, '项目文件夹', 'Project folders')),
      content: SizedBox(
        width: 560,
        child: folders.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  tr(context, '这个项目尚未绑定文件夹', 'This project has no folders'),
                  textAlign: TextAlign.center,
                ),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: folders.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final folder = folders[index];
                  return ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(
                      folder['path'] as String,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: tr(context, '移除绑定', 'Remove binding'),
                      onPressed: () async {
                        await ref
                            .read(appControllerProvider.notifier)
                            .removeProjectFolder(
                              projectId,
                              folder['id'] as String,
                            );
                        if (context.mounted) Navigator.pop(context);
                      },
                      icon: const Icon(Icons.link_off),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, '关闭', 'Close')),
        ),
        FilledButton.icon(
          onPressed: () async {
            await showDialog(
              context: context,
              builder: (_) => _RemoteFolderDialog(projectId: projectId),
            );
            if (context.mounted) Navigator.pop(context);
          },
          icon: const Icon(Icons.add),
          label: Text(tr(context, '添加文件夹', 'Add folder')),
        ),
      ],
    );
  }
}

class _HistoryImportDialog extends ConsumerStatefulWidget {
  const _HistoryImportDialog({required this.projectId});
  final String projectId;
  @override
  ConsumerState<_HistoryImportDialog> createState() =>
      _HistoryImportDialogState();
}

class _HistoryImportDialogState extends ConsumerState<_HistoryImportDialog> {
  List<Map<String, dynamic>> conversations = [];
  bool loading = true;
  @override
  void initState() {
    super.initState();
    scan();
  }

  Future<void> scan() async {
    try {
      final value = await ref
          .read(appControllerProvider.notifier)
          .request('history.scan');
      conversations = (value['conversations'] as List)
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<String?> chooseProject(Map<String, dynamic> conversation) async {
    final suggested = conversation['suggestedProjectId'] as String?;
    if (suggested != null) return suggested;
    final projects = ref.read(appControllerProvider).projects;
    if (projects.isEmpty) return null;
    var selected = widget.projectId;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(tr(context, '选择目标项目', 'Choose target project')),
          content: DropdownButtonFormField<String>(
            initialValue: selected,
            decoration: InputDecoration(
              labelText: tr(context, '项目', 'Project'),
            ),
            items: [
              for (final project in projects)
                DropdownMenuItem(
                  value: project['id'] as String,
                  child: Text(project['name'] as String),
                ),
            ],
            onChanged: (value) => setDialogState(() => selected = value!),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(tr(context, '取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selected),
              child: Text(tr(context, '导入', 'Import')),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      tr(context, '导入 Antigravity 会话', 'Import Antigravity conversation'),
    ),
    content: SizedBox(
      width: 640,
      height: 480,
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : conversations.isEmpty
          ? _EmptyState(
              icon: Icons.history_toggle_off,
              label: tr(context, '没有可导入的会话', 'No conversations found'),
            )
          : ListView.builder(
              itemCount: conversations.length,
              itemBuilder: (context, i) {
                final c = conversations[i];
                final imported = c['importedSessionId'] != null;
                final suggestedName = c['suggestedProjectName']?.toString();
                final cwd = c['cwd']?.toString();
                return ListTile(
                  leading: Icon(
                    imported
                        ? Icons.check_circle_outline
                        : Icons.chat_bubble_outline,
                  ),
                  title: Text(c['title']?.toString() ?? c['conversationId']),
                  subtitle: Text(
                    imported
                        ? tr(context, '已导入', 'Already imported')
                        : suggestedName != null
                        ? '$cwd\n${tr(context, '匹配项目', 'Matched project')}: $suggestedName'
                        : cwd ??
                              tr(
                                context,
                                '无法匹配工作目录，导入时请选择项目',
                                'Working directory is unknown; choose a project when importing',
                              ),
                  ),
                  isThreeLine: !imported && suggestedName != null,
                  trailing: Icon(
                    imported ? Icons.check : Icons.file_download_outlined,
                  ),
                  onTap: () async {
                    if (imported) {
                      final projectId = c['importedProjectId'] as String?;
                      if (projectId != null) {
                        ref
                            .read(appControllerProvider.notifier)
                            .selectProject(projectId);
                      }
                      await ref
                          .read(appControllerProvider.notifier)
                          .selectSession(c['importedSessionId'] as String);
                      if (context.mounted) Navigator.pop(context);
                      return;
                    }
                    final projectId = await chooseProject(c);
                    if (projectId == null || !context.mounted) return;
                    final session = await ref
                        .read(appControllerProvider.notifier)
                        .request('history.import', {
                          'projectId': projectId,
                          'conversationId': c['conversationId'],
                          'title': c['title'] ?? 'Imported conversation',
                        });
                    await ref.read(appControllerProvider.notifier).refresh();
                    ref
                        .read(appControllerProvider.notifier)
                        .selectProject(projectId);
                    await ref
                        .read(appControllerProvider.notifier)
                        .selectSession(session['id'] as String);
                    if (context.mounted) Navigator.pop(context);
                  },
                );
              },
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr(context, '关闭', 'Close')),
      ),
    ],
  );
}

class _RemoteFolderDialogState extends ConsumerState<_RemoteFolderDialog> {
  String path = '';
  String homePath = '/';
  List<Map<String, dynamic>> entries = [];
  bool loading = true;
  bool showHidden = false;
  final name = TextEditingController();
  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    try {
      final info = await ref
          .read(appControllerProvider.notifier)
          .request('system.info');
      homePath = info['home']?.toString() ?? '/';
      path = homePath;
    } catch (_) {
      path = '/';
    }
    await load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    try {
      final v = await ref.read(appControllerProvider.notifier).request(
        'fs.list',
        {'path': path, 'limit': 300},
      );
      entries = (v['entries'] as List)
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .where((e) => e['isDirectory'] == true)
          .toList();
      path = v['path'];
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleEntries = showHidden
        ? entries
        : entries
              .where((entry) => !entry['name'].toString().startsWith('.'))
              .toList();
    return AlertDialog(
      title: Text(
        widget.projectId == null
            ? tr(context, '创建项目', 'Create project')
            : tr(context, '添加项目文件夹', 'Add project folder'),
      ),
      content: SizedBox(
        width: 560,
        height: 460,
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: tr(context, '主目录', 'Home'),
                  onPressed: path == homePath
                      ? null
                      : () {
                          path = homePath;
                          load();
                        },
                  icon: const Icon(Icons.home_outlined),
                ),
                IconButton(
                  onPressed: path == '/'
                      ? null
                      : () {
                          path =
                              path.substring(0, path.lastIndexOf('/')).isEmpty
                              ? '/'
                              : path.substring(0, path.lastIndexOf('/'));
                          load();
                        },
                  icon: const Icon(Icons.arrow_upward),
                ),
                Expanded(
                  child: SelectableText(
                    path,
                    maxLines: 1,
                    selectionControls: rizTextSelectionControls,
                    magnifierConfiguration: rizTextMagnifierConfiguration,
                  ),
                ),
                IconButton(
                  tooltip: showHidden
                      ? tr(context, '隐藏点文件', 'Hide hidden folders')
                      : tr(context, '显示点文件', 'Show hidden folders'),
                  onPressed: () => setState(() => showHidden = !showHidden),
                  icon: Icon(
                    showHidden
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
                IconButton(onPressed: load, icon: const Icon(Icons.refresh)),
              ],
            ),
            const Divider(),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: visibleEntries.length,
                      itemBuilder: (context, i) {
                        final e = visibleEntries[i];
                        return ListTile(
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(e['name']),
                          onTap: () {
                            path = e['path'];
                            load();
                          },
                        );
                      },
                    ),
            ),
            if (widget.projectId == null)
              TextField(
                selectionControls: rizTextSelectionControls,
                magnifierConfiguration: rizTextMagnifierConfiguration,
                controller: name,
                decoration: InputDecoration(
                  labelText: tr(context, '项目名称（可选）', 'Project name (optional)'),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, '取消', 'Cancel')),
        ),
        if (widget.projectId == null)
          FilledButton.tonal(
            onPressed: () async {
              await ref
                  .read(appControllerProvider.notifier)
                  .createEmptyProject(
                    name: name.text.trim().isEmpty ? null : name.text.trim(),
                  );
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(tr(context, '不绑定文件夹', 'Create without folder')),
          ),
        FilledButton.icon(
          onPressed: () async {
            final controller = ref.read(appControllerProvider.notifier);
            if (widget.projectId case final projectId?) {
              await controller.addProjectFolder(projectId, path);
            } else {
              await controller.addProject(
                path,
                name: name.text.trim().isEmpty ? null : name.text.trim(),
              );
            }
            if (context.mounted) Navigator.pop(context);
          },
          icon: const Icon(Icons.add),
          label: Text(
            widget.projectId == null
                ? tr(context, '创建', 'Create')
                : tr(context, '添加', 'Add'),
          ),
        ),
      ],
    );
  }
}

class _TasksView extends ConsumerWidget {
  const _TasksView();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final active = state.sessions
        .where(
          (s) => const {
            'queued',
            'running',
            'waiting_permission',
            'waiting_input',
          }.contains(s['status']),
        )
        .toList();
    return _PageFrame(
      title: tr(context, '运行中的任务', 'Running tasks'),
      child: active.isEmpty
          ? _EmptyState(
              icon: Icons.task_alt,
              label: tr(context, '当前没有运行中的任务', 'No tasks are running'),
            )
          : ListView.builder(
              itemCount: active.length,
              itemBuilder: (context, i) {
                final session = active[i];
                final project = state.projects
                    .where((p) => p['id'] == session['projectId'])
                    .firstOrNull;
                return ListTile(
                  leading: _StatusIcon(status: session['status'] as String),
                  title: Text(session['title'] as String),
                  subtitle: Text(
                    '${project?['name'] ?? ''} · ${_statusLabel(context, session['status'] as String)}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    ref.read(appControllerProvider.notifier).setNavigation(0);
                    ref
                        .read(appControllerProvider.notifier)
                        .selectProject(session['projectId'] as String);
                    await ref
                        .read(appControllerProvider.notifier)
                        .selectSession(session['id'] as String);
                  },
                );
              },
            ),
    );
  }
}

class _FilesPane extends ConsumerStatefulWidget {
  const _FilesPane({required this.root});
  final String root;
  @override
  ConsumerState<_FilesPane> createState() => _FilesPaneState();
}

class _FilesPaneState extends ConsumerState<_FilesPane> {
  late String path;
  List<Map<String, dynamic>> entries = [];
  Map<String, dynamic>? opened;
  CodeController? editor;
  final editorFocus = FocusNode(debugLabel: 'RizFileEditor');
  bool loading = true;
  bool dirty = false;
  bool transferring = false;
  bool showHidden = false;
  final search = TextEditingController();

  @override
  void initState() {
    super.initState();
    path = widget.root;
    load();
  }

  @override
  void dispose() {
    editor?.dispose();
    editorFocus.dispose();
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() => loading = true);
    try {
      final result = await ref.read(appControllerProvider.notifier).request(
        'fs.list',
        {'path': path, 'limit': 500},
      );
      entries = (result['entries'] as List)
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      path = result['path'] as String;
    } catch (e) {
      _error(e);
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> open(Map<String, dynamic> item) async {
    if (item['isDirectory'] == true) {
      path = item['path'] as String;
      opened = null;
      await load();
      return;
    }
    try {
      final value = await ref.read(appControllerProvider.notifier).request(
        'fs.read',
        {'path': item['path']},
      );
      editor?.dispose();
      editor = value['text'] == null
          ? null
          : CodeController(text: value['text'] as String);
      editor?.addListener(() {
        if (mounted) setState(() => dirty = true);
      });
      setState(() {
        opened = value;
        dirty = false;
      });
      if (editor != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) editorFocus.requestFocus();
        });
      }
    } catch (e) {
      _error(e);
    }
  }

  Future<void> save() async {
    if (opened == null || editor == null) return;
    try {
      final value = await ref
          .read(appControllerProvider.notifier)
          .request('fs.write', {
            'path': opened!['path'],
            'text': editor!.text,
            'expectedRevision': opened!['revision'],
          });
      setState(() {
        opened = {...opened!, ...value};
        dirty = false;
      });
    } catch (e) {
      _error(e);
    }
  }

  void _error(Object e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> searchFiles() async {
    if (search.text.trim().isEmpty) {
      await load();
      return;
    }
    try {
      final value = await ref.read(appControllerProvider.notifier).request(
        'fs.search',
        {'root': widget.root, 'query': search.text.trim(), 'limit': 200},
      );
      final items = (value['items'] as List).cast<Map>();
      setState(
        () => entries = items.map((raw) {
          final p = (raw['path'] as Map)['text'] as String;
          return <String, dynamic>{
            'name': p,
            'path': '${widget.root}/$p',
            'isDirectory': false,
            'searchText': (raw['lines'] as Map?)?['text'],
          };
        }).toList(),
      );
    } catch (e) {
      _error(e);
    }
  }

  Future<void> createItem(bool directory) async {
    final name = await _textPrompt(
      context,
      directory
          ? tr(context, '新文件夹', 'New folder')
          : tr(context, '新文件', 'New file'),
      tr(context, '名称', 'Name'),
    );
    if (name == null || name.isEmpty) return;
    final target = '$path/$name';
    try {
      await ref
          .read(appControllerProvider.notifier)
          .request(
            directory ? 'fs.mkdir' : 'fs.write',
            directory ? {'path': target} : {'path': target, 'text': ''},
          );
      await load();
    } catch (e) {
      _error(e);
    }
  }

  Future<void> renameItem(Map<String, dynamic> item) async {
    final oldName = item['name'].toString();
    final name = await _textPrompt(
      context,
      tr(context, '重命名', 'Rename'),
      tr(context, '新名称', 'New name'),
      initialValue: oldName,
    );
    if (name == null || name.isEmpty || name == oldName) return;
    try {
      await ref.read(appControllerProvider.notifier).request('fs.rename', {
        'from': item['path'],
        'to': '$path/$name',
      });
      if (opened?['path'] == item['path']) opened = null;
      await load();
    } catch (e) {
      _error(e);
    }
  }

  Future<void> uploadFiles() async {
    final picked = await pickLocalFiles();
    if (picked == null || !mounted) return;
    setState(() => transferring = true);
    var uploaded = 0;
    try {
      for (final file in picked) {
        final bytes = file.bytes;
        if (bytes.length > 25 * 1024 * 1024) {
          throw StateError('${file.name}: exceeds 25 MiB');
        }
        final exists = entries.any((e) => e['name'] == file.name);
        if (!mounted) return;
        if (exists &&
            !await _confirm(
              context,
              tr(context, '覆盖 ${file.name}？', 'Replace ${file.name}?'),
            )) {
          continue;
        }
        await ref
            .read(appControllerProvider.notifier)
            .uploadFile('$path/${file.name}', bytes);
        uploaded++;
      }
      await load();
      if (mounted && uploaded > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                context,
                '已上传 $uploaded 个文件',
                'Uploaded $uploaded file${uploaded == 1 ? '' : 's'}',
              ),
            ),
          ),
        );
      }
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => transferring = false);
    }
  }

  Future<void> downloadFile(Map<String, dynamic> item) async {
    setState(() => transferring = true);
    try {
      final result = await ref
          .read(appControllerProvider.notifier)
          .downloadFile(item['path'].toString());
      if (!mounted) return;
      final name =
          item['name']?.toString() ??
          result.metadata['name']?.toString() ??
          'download.bin';
      await saveLocalFile(name, result.bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(context, '已开始下载 $name', 'Download started: $name'),
            ),
          ),
        );
      }
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => transferring = false);
    }
  }

  Future<void> showDiff() async {
    try {
      final value = await ref.read(appControllerProvider.notifier).request(
        'fs.diff',
        {'root': widget.root, if (opened != null) 'path': opened!['path']},
      );
      if (!mounted) return;
      final diff = value['diff']?.toString() ?? '';
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr(context, 'Git 差异', 'Git diff')),
          content: SizedBox(
            width: 760,
            child: diff.isEmpty
                ? Text(tr(context, '没有未提交的差异', 'No uncommitted changes'))
                : SingleChildScrollView(
                    child: SelectableText(
                      selectionControls: rizTextSelectionControls,
                      magnifierConfiguration: rizTextMagnifierConfiguration,
                      diff,
                      style: context.text.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr(context, '关闭', 'Close')),
            ),
          ],
        ),
      );
    } catch (e) {
      _error(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleEntries = showHidden
        ? entries
        : entries.where((entry) {
            final name = entry['name']?.toString().split('/').last ?? '';
            return !name.startsWith('.');
          }).toList();
    final browser = Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              IconButton(
                tooltip: tr(context, '上一级', 'Parent'),
                onPressed: path == widget.root
                    ? null
                    : () {
                        final i = path.lastIndexOf('/');
                        path = i <= widget.root.length
                            ? widget.root
                            : path.substring(0, i);
                        opened = null;
                        load();
                      },
                icon: const Icon(Icons.arrow_upward),
              ),
              Expanded(
                child: TextField(
                  selectionControls: rizTextSelectionControls,
                  magnifierConfiguration: rizTextMagnifierConfiguration,
                  controller: search,
                  onSubmitted: (_) => searchFiles(),
                  decoration: InputDecoration(
                    hintText: tr(context, '在项目中搜索', 'Search project'),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      onPressed: searchFiles,
                      icon: const Icon(Icons.arrow_forward),
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: tr(context, 'Git 差异', 'Git diff'),
                onPressed: showDiff,
                icon: const Icon(Icons.difference_outlined),
              ),
              IconButton(
                tooltip: showHidden
                    ? tr(context, '隐藏点文件', 'Hide hidden files')
                    : tr(context, '显示点文件', 'Show hidden files'),
                onPressed: () => setState(() => showHidden = !showHidden),
                icon: Icon(
                  showHidden
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
              IconButton(
                tooltip: tr(context, '上传文件', 'Upload files'),
                onPressed: transferring ? null : uploadFiles,
                icon: transferring
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.upload_file_outlined),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.add),
                onSelected: (v) => createItem(v == 'dir'),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'file',
                    child: Text(tr(context, '新文件', 'New file')),
                  ),
                  PopupMenuItem(
                    value: 'dir',
                    child: Text(tr(context, '新文件夹', 'New folder')),
                  ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.labelMedium,
            ),
          ),
        ),
        const Divider(),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  itemCount: visibleEntries.length,
                  itemBuilder: (context, i) {
                    final e = visibleEntries[i];
                    return ListTile(
                      dense: true,
                      selected: opened?['path'] == e['path'],
                      leading: Icon(
                        e['isDirectory'] == true
                            ? Icons.folder_outlined
                            : Icons.description_outlined,
                      ),
                      title: Text(
                        e['name'].toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: e['searchText'] == null
                          ? null
                          : Text(e['searchText'].toString(), maxLines: 2),
                      onTap: () => open(e),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) async {
                          if (v == 'rename') {
                            await renameItem(e);
                          } else if (v == 'download') {
                            await downloadFile(e);
                          } else if (v == 'delete' &&
                              await _confirm(
                                context,
                                tr(
                                  context,
                                  '删除此文件或文件夹？',
                                  'Delete this file or folder?',
                                ),
                              )) {
                            try {
                              await ref
                                  .read(appControllerProvider.notifier)
                                  .request('fs.delete', {'path': e['path']});
                              opened = null;
                              await load();
                            } catch (err) {
                              _error(err);
                            }
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'rename',
                            child: Text(tr(context, '重命名', 'Rename')),
                          ),
                          if (e['isDirectory'] != true)
                            PopupMenuItem(
                              value: 'download',
                              child: Text(tr(context, '下载', 'Download')),
                            ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(tr(context, '删除', 'Delete')),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
    if (!context.isWide || opened == null) return browser;
    return Row(
      children: [
        SizedBox(width: 330, child: browser),
        const VerticalDivider(width: 1),
        Expanded(
          child: _FileEditor(
            opened: opened!,
            editor: editor,
            dirty: dirty,
            focusNode: editorFocus,
            onSave: save,
            onDownload: () => downloadFile(opened!),
            onDiff: showDiff,
          ),
        ),
      ],
    );
  }
}

class _FileEditor extends StatelessWidget {
  const _FileEditor({
    required this.opened,
    required this.editor,
    required this.dirty,
    required this.focusNode,
    required this.onSave,
    required this.onDownload,
    required this.onDiff,
  });
  final Map<String, dynamic> opened;
  final CodeController? editor;
  final bool dirty;
  final FocusNode focusNode;
  final VoidCallback onSave;
  final VoidCallback onDownload;
  final VoidCallback onDiff;
  @override
  Widget build(BuildContext context) {
    final mime = opened['mimeType']?.toString() ?? '';
    return Column(
      children: [
        ListTile(
          title: Text(opened['path'].toString().split('/').last),
          subtitle: Text('${opened['size']} bytes · $mime'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: tr(context, 'Git 差异', 'Git diff'),
                onPressed: onDiff,
                icon: const Icon(Icons.difference_outlined),
              ),
              IconButton(
                tooltip: tr(context, '下载', 'Download'),
                onPressed: onDownload,
                icon: const Icon(Icons.download_outlined),
              ),
              if (editor != null)
                IconButton.filledTonal(
                  tooltip: tr(context, '保存', 'Save'),
                  onPressed: dirty ? onSave : null,
                  icon: const Icon(Icons.save_outlined),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: mime.startsWith('image/') && opened['base64'] != null
              ? InteractiveViewer(
                  child: Center(
                    child: Image.memory(
                      base64Decode(opened['base64'] as String),
                    ),
                  ),
                )
              : editor != null
              ? Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => focusNode.requestFocus(),
                  child: CodeField(
                    selectionControls: rizTextSelectionControls,
                    controller: editor!,
                    focusNode: focusNode,
                    padding: const EdgeInsets.all(12),
                    expands: true,
                    wrap: false,
                  ),
                )
              : _EmptyState(
                  icon: Icons.download_outlined,
                  label: tr(
                    context,
                    '此文件不可在编辑器中打开',
                    'This file cannot be opened in the editor',
                  ),
                ),
        ),
      ],
    );
  }
}

class _TerminalPane extends ConsumerStatefulWidget {
  const _TerminalPane({this.projectId, required this.cwd});
  final String? projectId;
  final String cwd;
  @override
  ConsumerState<_TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalTab {
  _TerminalTab(this.id, this.terminal);
  final String id;
  final Terminal terminal;
}

class _TerminalPaneState extends ConsumerState<_TerminalPane> {
  final tabs = <_TerminalTab>[];
  late final AppController controller;
  int selected = 0;
  bool creating = false;

  @override
  void initState() {
    super.initState();
    controller = ref.read(appControllerProvider.notifier);
    restore();
  }

  Future<void> restore() async {
    final restored = <_TerminalTab>[];
    try {
      final value = await controller.request('terminal.list', {
        'cwd': widget.cwd,
      });
      for (final item in (value['terminals'] as List? ?? const [])) {
        final id = (item as Map)['id'] as String;
        restored.add(await attach(id));
      }
    } catch (_) {
      for (final tab in restored) {
        controller.detachTerminal(tab.id);
      }
      return;
    }
    if (!mounted) {
      for (final tab in restored) {
        controller.detachTerminal(tab.id);
      }
      return;
    }
    setState(() => tabs.addAll(restored));
  }

  Future<_TerminalTab> attach(String id) async {
    late final Terminal terminal;
    terminal = Terminal(
      maxLines: 10000,
      onOutput: (data) => controller.terminalInput(id, data),
      onResize: (cols, rows, _, _) => controller.terminalResize(id, cols, rows),
    );
    controller.attachTerminal(
      id,
      (bytes) => terminal.write(utf8.decode(bytes, allowMalformed: true)),
    );
    final replay = await controller.request('terminal.replay', {'id': id});
    terminal.write(
      utf8.decode(
        base64Decode(replay['base64'] as String),
        allowMalformed: true,
      ),
    );
    return _TerminalTab(id, terminal);
  }

  Future<void> create() async {
    setState(() => creating = true);
    try {
      final value = await controller.request('terminal.create', {
        'projectId': widget.projectId,
        'cwd': widget.cwd,
        'cols': 100,
        'rows': 30,
      });
      final id = value['id'] as String;
      final tab = await attach(id);
      if (!mounted) {
        controller.detachTerminal(id);
        return;
      }
      setState(() {
        tabs.add(tab);
        selected = tabs.length - 1;
      });
    } finally {
      if (mounted) setState(() => creating = false);
    }
  }

  Future<void> close(int index) async {
    final tab = tabs[index];
    controller.detachTerminal(tab.id);
    await controller.request('terminal.close', {'id': tab.id});
    if (!mounted) return;
    setState(() {
      tabs.removeAt(index);
      selected = tabs.isEmpty ? 0 : selected.clamp(0, tabs.length - 1);
    });
  }

  @override
  void dispose() {
    for (final tab in tabs) {
      controller.detachTerminal(tab.id);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SizedBox(
        height: 48,
        child: Row(
          children: [
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: tabs.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.all(4),
                  child: InputChip(
                    selected: i == selected,
                    label: Text('${tr(context, '终端', 'Terminal')} ${i + 1}'),
                    onPressed: () => setState(() => selected = i),
                    onDeleted: () => close(i),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: tr(context, '新终端', 'New terminal'),
              onPressed: creating ? null : create,
              icon: creating
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: tabs.isEmpty
            ? _EmptyState(
                icon: Icons.terminal,
                label: tr(context, '打开一个终端标签', 'Open a terminal tab'),
                action: FilledButton.icon(
                  onPressed: create,
                  icon: const Icon(Icons.add),
                  label: Text(tr(context, '新终端', 'New terminal')),
                ),
              )
            : ColoredBox(
                color: Colors.black,
                child: TerminalView(tabs[selected].terminal, autofocus: true),
              ),
      ),
    ],
  );
}

class _SkillsView extends ConsumerStatefulWidget {
  const _SkillsView({super.key, this.projectPath});
  final String? projectPath;
  @override
  ConsumerState<_SkillsView> createState() => _SkillsViewState();
}

class _SkillsViewState extends ConsumerState<_SkillsView> {
  List<Map<String, dynamic>> skills = [];
  bool loading = true;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    try {
      final v = await ref.read(appControllerProvider.notifier).request(
        'skill.list',
        {if (widget.projectPath != null) 'projectPath': widget.projectPath},
      );
      skills = (v['skills'] as List)
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .where(
            (e) => widget.projectPath == null
                ? e['scope'] == 'global'
                : e['scope'] == 'project',
          )
          .toList();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> edit([Map<String, dynamic>? skill]) async {
    final current = skill == null
        ? null
        : await ref.read(appControllerProvider.notifier).request('skill.read', {
            'path': skill['path'],
          });
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (_) =>
          _SkillEditorDialog(projectPath: widget.projectPath, skill: current),
    );
    await load();
  }

  Future<void> installGit() async {
    final url = await _textPrompt(
      context,
      tr(context, '从 Git 安装', 'Install from Git'),
      'Git URL',
    );
    if (url == null || url.isEmpty) return;
    final root = widget.projectPath == null
        ? '${await _home(ref)}/.gemini/config/skills'
        : '${widget.projectPath}/.agents/skills';
    try {
      await ref.read(appControllerProvider.notifier).request(
        'skill.git.install',
        {'targetRoot': root, 'url': url},
      );
      await load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => _PageFrame(
    title: widget.projectPath == null
        ? tr(context, '全局 Skills', 'Global skills')
        : tr(context, '项目 Skills', 'Project skills'),
    actions: [
      IconButton(
        tooltip: tr(context, '从 Git 安装', 'Install from Git'),
        onPressed: installGit,
        icon: const Icon(Icons.download_outlined),
      ),
      IconButton(
        tooltip: tr(context, '新建 Skill', 'New skill'),
        onPressed: edit,
        icon: const Icon(Icons.add),
      ),
    ],
    child: loading
        ? const Center(child: CircularProgressIndicator())
        : skills.isEmpty
        ? _EmptyState(
            icon: Icons.extension_off_outlined,
            label: tr(context, '还没有 Skills', 'No skills installed'),
          )
        : ListView.builder(
            itemCount: skills.length,
            itemBuilder: (context, i) {
              final s = skills[i];
              final enabled = s['enabled'] == true;
              return ListTile(
                leading: Icon(
                  enabled
                      ? Icons.extension_outlined
                      : Icons.extension_off_outlined,
                ),
                title: Text(
                  s['name'],
                  style: enabled
                      ? null
                      : TextStyle(color: context.colors.onSurfaceVariant),
                ),
                subtitle: Text(
                  s['description'] ?? '',
                  maxLines: 2,
                  style: enabled
                      ? null
                      : TextStyle(color: context.colors.outline),
                ),
                onTap: () => edit(s),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Tooltip(
                      message: enabled
                          ? tr(context, '停用', 'Disable')
                          : tr(context, '启用', 'Enable'),
                      child: Switch(
                        value: enabled,
                        onChanged: (value) async {
                          await ref
                              .read(appControllerProvider.notifier)
                              .request('skill.toggle', {
                                'path': s['path'],
                                'enabled': value,
                              });
                          await load();
                        },
                      ),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (v) async {
                        if (v == 'update') {
                          await ref
                              .read(appControllerProvider.notifier)
                              .request('skill.git.update', {'path': s['path']});
                          await load();
                        } else if (v == 'delete') {
                          if (!context.mounted) return;
                          final confirmed = await _confirm(
                            context,
                            tr(context, '删除此 Skill？', 'Delete this skill?'),
                          );
                          if (confirmed) {
                            await ref
                                .read(appControllerProvider.notifier)
                                .request('skill.delete', {'path': s['path']});
                            await load();
                          }
                        }
                      },
                      itemBuilder: (_) => [
                        if (s['source'] != null)
                          PopupMenuItem(
                            value: 'update',
                            child: Text(
                              tr(context, '从 Git 更新', 'Update from Git'),
                            ),
                          ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(tr(context, '删除', 'Delete')),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
  );
}

class _SkillEditorDialog extends ConsumerStatefulWidget {
  const _SkillEditorDialog({required this.projectPath, this.skill});
  final String? projectPath;
  final Map<String, dynamic>? skill;
  @override
  ConsumerState<_SkillEditorDialog> createState() => _SkillEditorDialogState();
}

class _SkillEditorDialogState extends ConsumerState<_SkillEditorDialog> {
  late final TextEditingController content = TextEditingController(
    text:
        widget.skill?['content'] as String? ??
        '---\nname: new-skill\ndescription: Describe this skill\n---\n\n# Instructions\n',
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.skill == null
          ? tr(context, '新建 Skill', 'New skill')
          : widget.skill!['name'],
    ),
    content: SizedBox(
      width: 680,
      height: 520,
      child: TextField(
        selectionControls: rizTextSelectionControls,
        magnifierConfiguration: rizTextMagnifierConfiguration,
        controller: content,
        expands: true,
        maxLines: null,
        minLines: null,
        textAlignVertical: TextAlignVertical.top,
        style: const TextStyle(fontFamily: 'monospace'),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr(context, '取消', 'Cancel')),
      ),
      FilledButton.icon(
        onPressed: () async {
          final match = RegExp(
            r'^---\s*\n(?:.|\n)*?^name:\s*([A-Za-z0-9_-]+)',
            multiLine: true,
          ).firstMatch(content.text);
          final name = match?.group(1);
          if (name == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  tr(
                    context,
                    '需要有效的 name frontmatter',
                    'Valid name frontmatter is required',
                  ),
                ),
              ),
            );
            return;
          }
          final base = widget.projectPath == null
              ? '${await _home(ref)}/.gemini/config/skills'
              : '${widget.projectPath}/.agents/skills';
          await ref.read(appControllerProvider.notifier).request(
            'skill.write',
            {
              'path': widget.skill?['path'] ?? '$base/$name',
              'content': content.text,
            },
          );
          if (context.mounted) Navigator.pop(context);
        },
        icon: const Icon(Icons.save_outlined),
        label: Text(tr(context, '保存', 'Save')),
      ),
    ],
  );
}

Future<String> _home(WidgetRef ref) async {
  final v = await ref
      .read(appControllerProvider.notifier)
      .request('system.info');
  return v['home'] as String;
}

class _QuotaView extends ConsumerStatefulWidget {
  const _QuotaView();
  @override
  ConsumerState<_QuotaView> createState() => _QuotaViewState();
}

class _QuotaViewState extends ConsumerState<_QuotaView> {
  bool refreshing = false;
  String? error;
  Future<void> refresh() async {
    setState(() {
      refreshing = true;
      error = null;
    });
    try {
      await ref.read(appControllerProvider.notifier).request('quota.get');
      await ref.read(appControllerProvider.notifier).refresh();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final quota = ref.watch(appControllerProvider).snapshot['quota'] as Map?;
    final snapshot = quota?['snapshot'] as Map?;
    final percentages = (snapshot?['remainingPercentages'] as List? ?? const [])
        .map((e) => (e as num).toDouble())
        .toList();
    final models = (snapshot?['models'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    return _PageFrame(
      title: tr(context, '配额', 'Quota'),
      actions: [
        IconButton(
          tooltip: tr(context, '刷新配额', 'Refresh quota'),
          onPressed: refreshing ? null : refresh,
          icon: refreshing
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        ),
      ],
      child: quota == null
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _EmptyState(
                  icon: Icons.data_usage_outlined,
                  label: tr(context, '尚未读取配额', 'Quota has not been fetched'),
                  action: FilledButton(
                    onPressed: refreshing ? null : refresh,
                    child: Text(tr(context, '读取配额', 'Fetch quota')),
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(
                      selectionControls: rizTextSelectionControls,
                      magnifierConfiguration: rizTextMagnifierConfiguration,
                      error!,
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.error,
                      ),
                    ),
                  ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (error != null) ...[
                  MaterialBanner(
                    content: Text(error!),
                    actions: [
                      TextButton(
                        onPressed: () => setState(() => error = null),
                        child: Text(tr(context, '关闭', 'Dismiss')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                Text(
                  '${tr(context, '上次成功', 'Last success')}: ${quota['fetchedAt']}',
                  style: context.text.bodyMedium,
                ),
                if (snapshot?['source'] != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${tr(context, '来源', 'Source')}: ${snapshot?['source']}',
                    style: context.text.bodySmall,
                  ),
                ],
                const SizedBox(height: 20),
                if (percentages.isEmpty)
                  SelectableText(
                    selectionControls: rizTextSelectionControls,
                    magnifierConfiguration: rizTextMagnifierConfiguration,
                    snapshot?['raw']?.toString() ?? jsonEncode(snapshot),
                  )
                else
                  for (var i = 0; i < percentages.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${i < models.length && models[i]['modelId'] != null ? models[i]['modelId'] : '${tr(context, '配额', 'Quota')} ${i + 1}'}: ${percentages[i].toStringAsFixed(0)}%',
                          ),
                          if (i < models.length &&
                              (models[i]['resetTime'] != null ||
                                  models[i]['refreshIn'] != null))
                            Text(
                              '${tr(context, '重置时间', 'Resets')}: ${models[i]['resetTime'] ?? models[i]['refreshIn']}',
                              style: context.text.bodySmall,
                            ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: (percentages[i] / 100).clamp(0, 1),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
    );
  }
}

class _SettingsView extends ConsumerStatefulWidget {
  const _SettingsView();

  @override
  ConsumerState<_SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends ConsumerState<_SettingsView> {
  String? _connectionId;
  String _channel = 'stable';
  Map<String, dynamic>? _updateStatus;
  Map<String, dynamic>? _updateResult;
  bool _checking = false;
  bool _installing = false;

  Future<void> _loadStatus(String connectionId) async {
    try {
      final value = await ref
          .read(appControllerProvider.notifier)
          .request('daemon.update.status');
      if (!mounted || _connectionId != connectionId) return;
      setState(() {
        _updateStatus = value;
        _channel = value['channel']?.toString() == 'prerelease'
            ? 'prerelease'
            : 'stable';
      });
    } catch (_) {}
  }

  Future<void> _checkUpdate([String? selectedChannel]) async {
    final channel = selectedChannel ?? _channel;
    setState(() {
      _channel = channel;
      _checking = true;
      _updateResult = null;
    });
    try {
      final value = await ref.read(appControllerProvider.notifier).request(
        'daemon.update.check',
        {'channel': channel},
      );
      if (!mounted) return;
      setState(() {
        _updateResult = value;
        _updateStatus = {
          ...?_updateStatus,
          'currentVersion': value['currentVersion'],
          'channel': channel,
        };
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _installUpdate() async {
    final result = _updateResult;
    if (result == null || result['available'] != true) return;
    final accepted = await _confirm(
      context,
      tr(
        context,
        '更新 rizd 到 ${result['targetVersion']}？daemon 将自动重启，连接会短暂中断。',
        'Update rizd to ${result['targetVersion']}? The daemon will restart and briefly disconnect.',
      ),
    );
    if (!accepted || !mounted) return;
    setState(() => _installing = true);
    try {
      final value = await ref.read(appControllerProvider.notifier).request(
        'daemon.update.install',
        {'channel': _channel},
      );
      if (!mounted) return;
      setState(() => _updateResult = value);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            value['restartScheduled'] == true
                ? tr(
                    context,
                    '更新已安装，daemon 正在重启',
                    'Update installed; daemon is restarting',
                  )
                : tr(
                    context,
                    '更新已安装，请手动重启 daemon',
                    'Update installed; restart the daemon manually',
                  ),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final ctl = ref.read(appControllerProvider.notifier);
    final active = state.connections
        .where((c) => c.id == state.activeConnectionId)
        .firstOrNull;
    if (_connectionId != active?.id) {
      _connectionId = active?.id;
      _updateStatus = null;
      _updateResult = null;
      if (active != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _loadStatus(active.id),
        );
      }
    }
    final currentVersion =
        _updateStatus?['currentVersion']?.toString() ?? '...';
    final available = _updateResult?['available'] == true;
    final compatible = _updateResult?['compatible'] != false;
    return _PageFrame(
      title: tr(context, '设置', 'Settings'),
      child: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(kIsWeb ? 'Riz Web' : 'Riz'),
            subtitle: const Text('Version $rizAppVersion'),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(tr(context, '主题', 'Theme')),
            trailing: DropdownButton<ThemeMode>(
              value: state.settings.themeMode,
              onChanged: (v) {
                if (v != null) ctl.updateTheme(v);
              },
              items: ThemeMode.values
                  .map(
                    (v) => DropdownMenuItem(
                      value: v,
                      child: Text(switch (v) {
                        ThemeMode.system => tr(context, '跟随系统', 'System'),
                        ThemeMode.light => tr(context, '浅色', 'Light'),
                        ThemeMode.dark => tr(context, '深色', 'Dark'),
                      }),
                    ),
                  )
                  .toList(),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(tr(context, '语言', 'Language')),
            trailing: DropdownButton<String>(
              value: state.settings.locale?.languageCode ?? 'system',
              onChanged: (v) =>
                  ctl.updateLocale(v == 'system' ? null : Locale(v!)),
              items: [
                DropdownMenuItem(
                  value: 'system',
                  child: Text(tr(context, '跟随系统', 'System')),
                ),
                const DropdownMenuItem(value: 'zh', child: Text('简体中文')),
                const DropdownMenuItem(value: 'en', child: Text('English')),
              ],
            ),
          ),
          const Divider(),
          if (active != null) ...[
            ListTile(
              leading: const Icon(Icons.system_update_alt),
              title: Text(tr(context, 'rizd 更新', 'rizd updates')),
              subtitle: Text(
                '${tr(context, '当前版本', 'Current version')}: $currentVersion',
              ),
              trailing: DropdownButton<String>(
                value: _channel,
                onChanged: _checking || _installing
                    ? null
                    : (value) {
                        if (value != null) _checkUpdate(value);
                      },
                items: [
                  DropdownMenuItem(
                    value: 'stable',
                    child: Text(tr(context, '正式版', 'Release')),
                  ),
                  DropdownMenuItem(
                    value: 'prerelease',
                    child: Text(tr(context, '预发布版', 'Prerelease')),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _checking || _installing ? null : _checkUpdate,
                    icon: _checking
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    label: Text(tr(context, '检查更新', 'Check for updates')),
                  ),
                  FilledButton.icon(
                    onPressed: available && compatible && !_installing
                        ? _installUpdate
                        : null,
                    icon: _installing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download),
                    label: Text(tr(context, '更新 rizd', 'Update rizd')),
                  ),
                ],
              ),
            ),
            if (_updateResult case final result?)
              ListTile(
                leading: Icon(
                  !compatible
                      ? Icons.warning_amber
                      : available
                      ? Icons.new_releases_outlined
                      : Icons.check_circle_outline,
                ),
                title: Text(
                  !compatible
                      ? tr(
                          context,
                          '没有适用于此平台的构建',
                          'No compatible build for this platform',
                        )
                      : available
                      ? '${tr(context, '可更新到', 'Update available')}: ${result['targetVersion']}'
                      : tr(
                          context,
                          '已经是所选通道的最新版本',
                          'Up to date on this channel',
                        ),
                ),
                subtitle: result['publishedAt'] == null
                    ? null
                    : Text(
                        '${tr(context, '发布时间', 'Published')}: ${result['publishedAt']}',
                      ),
              ),
            const Divider(),
          ],
          if (active != null)
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(active.name),
              subtitle: Text(active.url),
              trailing: IconButton(
                tooltip: tr(context, '移除连接', 'Remove connection'),
                onPressed: () async {
                  if (await _confirm(
                    context,
                    tr(
                      context,
                      '移除此 daemon 连接？',
                      'Remove this daemon connection?',
                    ),
                  )) {
                    ctl.removeConnection(active.id);
                  }
                },
                icon: const Icon(Icons.delete_outline),
              ),
            ),
          if (active != null)
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: Text(
                active.usesRelay
                    ? tr(context, '更新配对码', 'Update pairing code')
                    : tr(context, '更新 token', 'Update token'),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) => _TokenDialog(connection: active),
              ),
            ),
          if (active != null && isInsecureRemoteDaemonUrl(active.url))
            ListTile(
              leading: Icon(
                Icons.lock_open_outlined,
                color: context.colors.error,
              ),
              title: Text(
                tr(context, '远程连接未加密', 'Remote connection is unencrypted'),
              ),
              subtitle: Text(
                tr(
                  context,
                  '请将此 daemon 放在可信的 WSS tunnel 后面。',
                  'Put this daemon behind a trusted WSS tunnel.',
                ),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.add_link),
            title: Text(tr(context, '添加 daemon', 'Add daemon')),
            onTap: () => showDialog(
              context: context,
              builder: (_) => const _ConnectionDialog(),
            ),
          ),
          if (!kIsWeb)
            ListTile(
              leading: const Icon(Icons.install_mobile),
              title: Text(
                tr(context, '通过 SSH 安装 daemon', 'Install daemon over SSH'),
              ),
              onTap: () => showDialog(
                context: context,
                builder: (_) => const SshInstallDialog(),
              ),
            ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.warning_amber, color: context.colors.error),
            title: Text(
              tr(
                context,
                'Antigravity 第三方控制提示',
                'Antigravity third-party control notice',
              ),
            ),
            subtitle: Text(
              tr(
                context,
                '通过第三方工具控制 agy 可能违反 Google 的服务条款。Riz 在格式不兼容时会退回纯文本模式。',
                'Controlling agy through a third-party tool may violate Google terms. Riz falls back to plain text when formats are incompatible.',
              ),
            ),
          ),
          ListTile(
            leading: Icon(
              state.connected
                  ? Icons.monitor_heart_outlined
                  : Icons.error_outline,
              color: state.connected ? null : context.colors.error,
            ),
            title: Text(tr(context, '连接诊断', 'Connection diagnostics')),
            subtitle: Text(
              state.error ??
                  (state.connected
                      ? tr(
                          context,
                          '已连接 · ${state.connectionLogs.length} 条日志',
                          'Connected · ${state.connectionLogs.length} log entries',
                        )
                      : tr(
                          context,
                          '未连接 · ${state.connectionLogs.length} 条日志',
                          'Disconnected · ${state.connectionLogs.length} log entries',
                        )),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) => const _ConnectionDiagnosticsDialog(),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionDiagnosticsDialog extends ConsumerWidget {
  const _ConnectionDiagnosticsDialog();

  String _time(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    String three(int number) => number.toString().padLeft(3, '0');
    return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}.${three(value.millisecond)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);
    final active = state.connections
        .where((connection) => connection.id == state.activeConnectionId)
        .firstOrNull;
    final logs = state.connectionLogs.reversed.toList();
    final screen = MediaQuery.sizeOf(context);

    return Dialog(
      insetPadding: EdgeInsets.all(screen.width < 600 ? 12 : 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 760,
          maxHeight: screen.height * .86,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
              child: Row(
                children: [
                  Icon(
                    state.connected
                        ? Icons.monitor_heart_outlined
                        : Icons.error_outline,
                    color: state.connected ? null : context.colors.error,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr(context, '连接诊断', 'Connection diagnostics'),
                          style: context.text.titleMedium,
                        ),
                        Text(
                          '${active?.name ?? '-'} · ${state.connected ? tr(context, '已连接', 'Connected') : tr(context, '未连接', 'Disconnected')}',
                          style: context.text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: tr(context, '关闭', 'Close'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    active?.url ??
                        tr(context, '没有活动连接', 'No active connection'),
                    style: context.text.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                  if (state.error case final error?) ...[
                    const SizedBox(height: 6),
                    Text(
                      error,
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: logs.isEmpty
                  ? _EmptyState(
                      icon: Icons.receipt_long_outlined,
                      label: tr(context, '还没有连接日志', 'No connection logs yet'),
                    )
                  : SelectionArea(
                      selectionControls: rizTextSelectionControls,
                      magnifierConfiguration: rizTextMagnifierConfiguration,
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: logs.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final entry = logs[index];
                          final color = switch (entry.level) {
                            'error' => context.colors.error,
                            'warning' => context.colors.tertiary,
                            _ => context.colors.primary,
                          };
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 9,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 7,
                                  height: 7,
                                  margin: const EdgeInsets.only(top: 6),
                                  decoration: BoxDecoration(
                                    color: color,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                SizedBox(
                                  width: 88,
                                  child: Text(
                                    _time(entry.timestamp),
                                    style: context.text.bodySmall?.copyWith(
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        entry.event,
                                        style: context.text.bodyMedium
                                            ?.copyWith(
                                              fontFamily: 'monospace',
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                      if (entry.detail case final detail?)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 2,
                                          ),
                                          child: Text(
                                            detail,
                                            style: context.text.bodySmall
                                                ?.copyWith(
                                                  fontFamily: 'monospace',
                                                ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: logs.isEmpty
                        ? null
                        : controller.clearConnectionLogs,
                    icon: const Icon(Icons.delete_sweep_outlined),
                    label: Text(tr(context, '清空', 'Clear')),
                  ),
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed: logs.isEmpty
                        ? null
                        : () async {
                            await Clipboard.setData(
                              ClipboardData(
                                text: state.connectionLogs
                                    .map((entry) => entry.copyText)
                                    .join('\n'),
                              ),
                            );
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  tr(
                                    context,
                                    '诊断日志已复制',
                                    'Diagnostic log copied',
                                  ),
                                ),
                              ),
                            );
                          },
                    icon: const Icon(Icons.copy_all_outlined),
                    label: Text(tr(context, '复制日志', 'Copy log')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({
    required this.title,
    required this.child,
    this.actions = const [],
  });
  final String title;
  final Widget child;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
        child: Row(
          children: [
            Expanded(child: Text(title, style: context.text.titleLarge)),
            ...actions,
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(child: child),
    ],
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.label, this.action});
  final IconData icon;
  final String label;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 48, color: context.colors.outline),
        const SizedBox(height: 12),
        Text(label, style: context.text.titleMedium),
        if (action != null) ...[const SizedBox(height: 16), action!],
      ],
    ),
  );
}

Future<String?> _textPrompt(
  BuildContext context,
  String title,
  String label, {
  String initialValue = '',
}) async {
  final ctl = TextEditingController(text: initialValue);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        selectionControls: rizTextSelectionControls,
        magnifierConfiguration: rizTextMagnifierConfiguration,
        controller: ctl,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, '取消', 'Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, ctl.text.trim()),
          child: Text(tr(context, '确定', 'OK')),
        ),
      ],
    ),
  );
}

Future<bool> _confirm(BuildContext context, String message) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, '取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, '确定', 'OK')),
          ),
        ],
      ),
    ) ??
    false;
