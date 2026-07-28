import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models.dart';
import '../services/connection_url.dart';
import '../services/daemon_client.dart';

final appControllerProvider = NotifierProvider<AppController, RizState>(
  AppController.new,
);

class AppController extends Notifier<RizState> {
  static const _connectionsKey = 'riz.connections';
  static const _activeKey = 'riz.activeConnection';
  static const _themeKey = 'riz.theme';
  static const _localeKey = 'riz.locale';
  final _secure = const FlutterSecureStorage();
  final _clients = <String, DaemonClient>{};
  final _reconnectTimers = <String, Timer>{};
  final _terminalListeners = <String, void Function(Uint8List)>{};
  Timer? _refreshTimer;

  @override
  RizState build() {
    ref.onDispose(() {
      for (final client in _clients.values) {
        unawaited(client.close());
      }
      _refreshTimer?.cancel();
      for (final timer in _reconnectTimers.values) {
        timer.cancel();
      }
    });
    Future.microtask(_load);
    return const RizState();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_connectionsKey);
    final connections = raw == null
        ? <DaemonConnection>[]
        : (jsonDecode(raw) as List)
              .map(
                (e) => DaemonConnection.fromJson(
                  (e as Map).cast<String, dynamic>(),
                ),
              )
              .toList();
    final themeName = prefs.getString(_themeKey) ?? 'system';
    final localeName = prefs.getString(_localeKey);
    final settings = RizSettings(
      themeMode: ThemeMode.values.firstWhere(
        (v) => v.name == themeName,
        orElse: () => ThemeMode.system,
      ),
      locale: localeName == null ? null : Locale(localeName),
    );
    final active = prefs.getString(_activeKey) ?? connections.firstOrNull?.id;
    state = state.copyWith(
      loading: false,
      connections: connections,
      activeConnectionId: active,
      settings: settings,
    );
    await Future.wait(connections.map(_connectOne));
  }

  DaemonClient? get client => state.activeConnectionId == null
      ? null
      : _clients[state.activeConnectionId];

  Future<void> _connectOne(DaemonConnection connection) async {
    final token = await _secure.read(key: 'riz.token.${connection.id}');
    if (token == null) {
      _connectionLog(
        connection.id,
        'token.missing',
        'error',
        'No saved bearer token',
      );
      return;
    }
    _connectionLog(connection.id, 'client.create', 'info', connection.url);
    late final DaemonClient daemon;
    daemon = DaemonClient(
      url: connection.url,
      token: token,
      onEvent: (topic, data, seq) => _event(connection.id, topic, data),
      onBinary: (channel, id, data) {
        if (channel == 3) _terminalListeners[id]?.call(data);
      },
      onStatus: (connected, error) {
        _connectionLog(
          connection.id,
          connected ? 'status.connected' : 'status.disconnected',
          connected ? 'info' : 'warning',
          error,
        );
        if (connected) {
          _reconnectTimers.remove(connection.id)?.cancel();
        } else if (_clients[connection.id] == daemon &&
            !_reconnectTimers.containsKey(connection.id)) {
          _reconnectTimers[connection.id] = Timer(
            const Duration(seconds: 3),
            () async {
              _reconnectTimers.remove(connection.id);
              if (_clients[connection.id] == daemon) {
                _connectionLog(
                  connection.id,
                  'reconnect.attempt',
                  'info',
                  connection.url,
                );
                try {
                  await daemon.connect();
                } catch (_) {}
              }
            },
          );
          _connectionLog(
            connection.id,
            'reconnect.scheduled',
            'info',
            'retry in 3 seconds',
          );
        }
        final statuses = {...state.daemonStatuses, connection.id: connected};
        state = state.copyWith(
          daemonStatuses: statuses,
          connected: connection.id == state.activeConnectionId
              ? connected
              : state.connected,
          error: connection.id == state.activeConnectionId
              ? error
              : state.error,
          clearError: connected && connection.id == state.activeConnectionId,
        );
        if (connected && connection.id == state.activeConnectionId) {
          unawaited(refresh());
        }
      },
      onDebug: (event, level, detail) =>
          _connectionLog(connection.id, event, level, detail),
    );
    _clients[connection.id] = daemon;
    try {
      await daemon.connect();
    } catch (_) {}
  }

  void _event(String connectionId, String topic, dynamic data) {
    if (connectionId != state.activeConnectionId) return;
    if (topic == 'snapshot' && data is Map) {
      state = state.copyWith(snapshot: data.cast<String, dynamic>());
      return;
    }
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 120), () async {
      await refresh();
      if (state.selectedSessionId != null) {
        await selectSession(state.selectedSessionId);
      }
    });
  }

  Future<void> refresh() async {
    final c = client;
    if (c == null ||
        !(state.daemonStatuses[state.activeConnectionId] ?? false)) {
      return;
    }
    try {
      final value = await c.request('snapshot.get');
      state = state.copyWith(
        snapshot: value,
        connected: true,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> refreshOrReconnect() async {
    if (state.connected) {
      await refresh();
      return;
    }
    final id = state.activeConnectionId;
    if (id == null) return;
    _connectionLog(id, 'reconnect.manual', 'info', null);
    _reconnectTimers.remove(id)?.cancel();
    final daemon = _clients[id];
    if (daemon == null) {
      final connection = state.connections.where((item) => item.id == id).first;
      await _connectOne(connection);
      return;
    }
    try {
      await daemon.connect();
    } catch (error) {
      state = state.copyWith(error: error.toString());
    }
  }

  void _connectionLog(
    String connectionId,
    String event,
    String level,
    String? detail,
  ) {
    final entries = [
      ...state.connectionLogs,
      ConnectionLogEntry(
        timestamp: DateTime.now(),
        connectionId: connectionId,
        level: level,
        event: event,
        detail: detail,
      ),
    ];
    state = state.copyWith(
      connectionLogs: entries.length > 200
          ? entries.sublist(entries.length - 200)
          : entries,
    );
  }

  void clearConnectionLogs() {
    state = state.copyWith(connectionLogs: const []);
  }

  Future<void> addConnection({
    required String name,
    required String url,
    required String token,
  }) async {
    final normalizedToken = token.trim();
    if (normalizedToken.isEmpty) throw ArgumentError('Token cannot be empty');
    final normalized = normalizeDaemonUrl(
      url,
      requireSecureWebSocket: kIsWeb && Uri.base.scheme == 'https',
    );
    final connection = DaemonConnection(
      id: const Uuid().v4(),
      name: name.trim().isEmpty ? 'Mac' : name.trim(),
      url: normalized,
    );
    final connections = [...state.connections, connection];
    await _secure.write(
      key: 'riz.token.${connection.id}',
      value: normalizedToken,
    );
    await _saveConnections(connections, connection.id);
    state = state.copyWith(
      connections: connections,
      activeConnectionId: connection.id,
      connected: false,
      snapshot: const {},
      clearProject: true,
      clearSession: true,
      clearDraftSession: true,
    );
    await _connectOne(connection);
  }

  Future<void> updateConnectionToken(String id, String token) async {
    final value = token.trim();
    if (value.isEmpty) throw ArgumentError('Token cannot be empty');
    final connection = state.connections.where((item) => item.id == id).first;
    _reconnectTimers.remove(id)?.cancel();
    await _clients.remove(id)?.close();
    await _secure.write(key: 'riz.token.$id', value: value);
    _connectionLog(id, 'token.updated', 'info', null);
    state = state.copyWith(
      daemonStatuses: {...state.daemonStatuses, id: false},
      connected: id == state.activeConnectionId ? false : state.connected,
      clearError: id == state.activeConnectionId,
    );
    await _connectOne(connection);
  }

  Future<void> removeConnection(String id) async {
    _reconnectTimers.remove(id)?.cancel();
    await _clients.remove(id)?.close();
    await _secure.delete(key: 'riz.token.$id');
    final connections = state.connections.where((c) => c.id != id).toList();
    final active = connections.firstOrNull?.id;
    await _saveConnections(connections, active);
    state = state.copyWith(
      connections: connections,
      activeConnectionId: active,
      clearActiveConnection: active == null,
      connected: false,
      snapshot: const {},
      clearProject: true,
      clearSession: true,
      clearDraftSession: true,
    );
    if (active != null && (_clients[active] == null)) {
      await _connectOne(connections.first);
    }
  }

  Future<void> activateConnection(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, id);
    state = state.copyWith(
      activeConnectionId: id,
      connected: state.daemonStatuses[id] ?? false,
      snapshot: const {},
      clearProject: true,
      clearSession: true,
      clearDraftSession: true,
      messages: const [],
      clearError: true,
    );
    if (_clients[id] == null) {
      final connection = state.connections.where((c) => c.id == id).first;
      await _connectOne(connection);
    }
    await refresh();
  }

  Future<void> _saveConnections(
    List<DaemonConnection> connections,
    String? active,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _connectionsKey,
      jsonEncode(connections.map((e) => e.toJson()).toList()),
    );
    if (active == null) {
      await prefs.remove(_activeKey);
    } else {
      await prefs.setString(_activeKey, active);
    }
  }

  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async => (client ?? (throw StateError('No daemon selected'))).request(
    method,
    params,
  );

  Future<void> addProject(String path, {String? name}) async {
    final project = await request('project.create', {
      'folders': [path],
      'name': ?name,
    });
    await refresh();
    selectProject(project['id'] as String);
  }

  Future<void> createEmptyProject({String? name}) async {
    final project = await request('project.create', {
      'folders': const <String>[],
      'name': ?name,
    });
    await refresh();
    selectProject(project['id'] as String);
  }

  Future<void> renameProject(String projectId, String? name) async {
    await request('project.rename', {'projectId': projectId, 'name': ?name});
    await refresh();
  }

  Future<void> addProjectFolder(String projectId, String path) async {
    await request('project.folder.add', {'projectId': projectId, 'path': path});
    await refresh();
  }

  Future<void> removeProjectFolder(String projectId, String folderId) async {
    await request('project.folder.remove', {
      'projectId': projectId,
      'folderId': folderId,
    });
    await refresh();
  }

  Future<void> deleteProject(
    String projectId, {
    required bool deleteSessions,
  }) async {
    await request('project.remove', {
      'projectId': projectId,
      'mode': deleteSessions ? 'delete_sessions' : 'detach_sessions',
    });
    await refresh();
    if (state.selectedProjectId == projectId) {
      state = state.copyWith(
        clearProject: true,
        clearSession: true,
        clearDraftSession: true,
        messages: const [],
      );
    }
  }

  Future<void> deleteSession(String id) async {
    await request('session.delete', {'sessionId': id});
    await refresh();
    if (state.selectedSessionId == id) await selectSession(null);
  }

  Future<void> moveSession(String sessionId, String? projectId) async {
    await request('session.move', {
      'sessionId': sessionId,
      'projectId': ?projectId,
    });
    await refresh();
    state = state.copyWith(
      selectedProjectId: projectId,
      clearProject: projectId == null,
      selectedSessionId: sessionId,
    );
    await selectSession(sessionId);
  }

  void selectProject(String? id) => state = state.copyWith(
    selectedProjectId: id,
    clearProject: id == null,
    clearSession: true,
    clearDraftSession: true,
    messages: const [],
  );

  void createSession({String? title, bool quickChat = false}) {
    final projectId = quickChat ? null : state.selectedProjectId;
    if (!quickChat && projectId == null) return;
    state = state.copyWith(
      clearSession: true,
      draftSession: {
        'id': 'draft:${const Uuid().v4()}',
        'projectId': projectId,
        'provider': 'agy',
        'title': title ?? (quickChat ? 'Quick chat' : 'New session'),
        'status': 'completed',
        'permissionMode': 'workspace',
      },
      sessionLoading: false,
      messages: const [],
      clearPendingPermission: true,
      clearPendingInput: true,
      navigationIndex: 0,
    );
  }

  Future<void> selectSession(String? id) async {
    if (id == null) {
      state = state.copyWith(
        clearSession: true,
        clearDraftSession: true,
        sessionLoading: false,
        messages: const [],
        clearPendingPermission: true,
        clearPendingInput: true,
      );
      return;
    }
    state = state.copyWith(
      selectedSessionId: id,
      clearDraftSession: true,
      sessionLoading: true,
      messages: const [],
      clearPendingPermission: true,
      clearPendingInput: true,
    );
    try {
      final data = await request('session.get', {'id': id});
      if (state.selectedSessionId != id) return;
      state = state.copyWith(
        sessionLoading: false,
        messages: (data['messages'] as List? ?? const [])
            .cast<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList(),
        pendingPermission: (data['pendingPermission'] as Map?)
            ?.cast<String, dynamic>(),
        clearPendingPermission: data['pendingPermission'] == null,
        pendingInput: (data['pendingInput'] as Map?)?.cast<String, dynamic>(),
        clearPendingInput: data['pendingInput'] == null,
      );
    } catch (error) {
      if (state.selectedSessionId == id) {
        state = state.copyWith(sessionLoading: false, error: error.toString());
      }
    }
  }

  Future<void> sendMessage(
    String text, {
    List<Map<String, dynamic>> attachments = const [],
    String mode = 'queue',
    String? model,
  }) async {
    if (text.trim().isEmpty && attachments.isEmpty) return;
    var id = state.selectedSessionId;
    Map<String, dynamic>? materializedSession;
    final draft = state.draftSession;
    if (draft != null) {
      final session = await request('session.create', {
        'projectId': ?draft['projectId'],
        'title': draft['title'],
        'provider': draft['provider'] ?? 'agy',
        'permissionMode': draft['permissionMode'] ?? 'workspace',
      });
      materializedSession = session;
      id = session['id'] as String;
    }
    if (id == null) return;
    final session = materializedSession ?? state.selectedSession;
    try {
      final remoteAttachments = <Map<String, dynamic>>[];
      for (final attachment in attachments) {
        var path = attachment['path']?.toString();
        if (attachment['bytes'] case final Uint8List bytes) {
          final workspacePath = session?['workspacePath']?.toString();
          if (workspacePath == null) {
            throw StateError('Session workspace not found');
          }
          final name = attachment['name'].toString().replaceAll(
            RegExp(r'[/\\]'),
            '_',
          );
          path = '$workspacePath/attachments/$name';
          await uploadFile(path, bytes);
        }
        if (path == null) continue;
        remoteAttachments.add({
          'path': path,
          'name': attachment['name'],
          'mimeType': attachment['mimeType'],
        });
      }
      await request('session.send', {
        'sessionId': id,
        'delivery': mode,
        'content': {
          'text': text.trim(),
          'attachments': remoteAttachments,
          'model': ?model,
        },
      });
    } catch (_) {
      if (materializedSession != null) {
        try {
          await request('session.delete', {'sessionId': id});
          await refresh();
        } catch (_) {}
      }
      rethrow;
    }
    if (materializedSession != null) {
      await refresh();
      state = state.copyWith(
        selectedProjectId: session?['projectId'] as String?,
        clearProject: session?['projectId'] == null,
        selectedSessionId: id,
        clearDraftSession: true,
        messages: const [],
      );
    }
    await selectSession(id);
  }

  Future<void> archiveSession(String id, bool archived) async {
    await request('session.archive', {'id': id, 'archived': archived});
    await refresh();
    if (archived && id == state.selectedSessionId) await selectSession(null);
  }

  Future<void> stopSession() async {
    final id = state.selectedSessionId;
    if (id != null) await request('session.cancel', {'sessionId': id});
  }

  Future<void> respondPermission(bool allow) async {
    final id = state.selectedSessionId;
    if (id == null) return;
    await request('session.permission.respond', {
      'sessionId': id,
      'allow': allow,
    });
    state = state.copyWith(clearPendingPermission: true);
    await refresh();
    await selectSession(id);
  }

  Future<void> respondInput(List<int> selectedIndices) async {
    final id = state.selectedSessionId;
    if (id == null || selectedIndices.isEmpty) return;
    await request('session.input.respond', {
      'sessionId': id,
      'selectedIndices': selectedIndices,
    });
    state = state.copyWith(clearPendingInput: true);
    await refresh();
    await selectSession(id);
  }

  Future<void> setPermissionMode(String mode) async {
    if (!const {'ask', 'workspace', 'full'}.contains(mode)) return;
    if (state.draftSession case final draft?) {
      state = state.copyWith(draftSession: {...draft, 'permissionMode': mode});
      return;
    }
    final id = state.selectedSessionId;
    if (id == null) return;
    final session = await request('session.permissions.set', {
      'sessionId': id,
      'mode': mode,
    });
    final snapshot = {...state.snapshot};
    snapshot['sessions'] = state.sessions
        .map((item) => item['id'] == id ? session : item)
        .toList();
    state = state.copyWith(snapshot: snapshot, clearError: true);
  }

  void setNavigation(int index) =>
      state = state.copyWith(navigationIndex: index);

  Future<void> updateTheme(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, mode.name);
    state = state.copyWith(settings: state.settings.copyWith(themeMode: mode));
  }

  Future<void> updateLocale(Locale? locale) async {
    final prefs = await SharedPreferences.getInstance();
    if (locale == null) {
      await prefs.remove(_localeKey);
    } else {
      await prefs.setString(_localeKey, locale.languageCode);
    }
    state = state.copyWith(
      settings: state.settings.copyWith(
        locale: locale,
        systemLocale: locale == null,
      ),
    );
  }

  void attachTerminal(String id, void Function(Uint8List) listener) =>
      _terminalListeners[id] = listener;
  void detachTerminal(String id) => _terminalListeners.remove(id);
  void terminalInput(String id, String data) =>
      client?.sendTerminal(id, utf8.encode(data));
  void terminalResize(String id, int cols, int rows) {
    unawaited(
      request('terminal.resize', {'id': id, 'cols': cols, 'rows': rows}),
    );
  }

  Future<Map<String, dynamic>> uploadFile(String path, Uint8List bytes) =>
      (client ?? (throw StateError('No daemon selected'))).uploadFile(
        path,
        bytes,
      );

  Future<({Map<String, dynamic> metadata, Uint8List bytes})> downloadFile(
    String path,
  ) => (client ?? (throw StateError('No daemon selected'))).downloadFile(path);
}
