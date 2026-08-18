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
import '../services/pairing_code.dart';

final appControllerProvider = NotifierProvider<AppController, RizState>(
  AppController.new,
);

class _SessionMemoryCache {
  _SessionMemoryCache({
    required this.messages,
    this.pendingPermission,
    this.pendingInput,
  });

  List<Map<String, dynamic>> messages;
  Map<String, dynamic>? pendingPermission;
  Map<String, dynamic>? pendingInput;
  bool dirty = false;
}

class AppController extends Notifier<RizState> {
  static const _connectionsKey = 'riz.connections';
  static const _activeKey = 'riz.activeConnection';
  static const _themeKey = 'riz.theme';
  static const _localeKey = 'riz.locale';
  static const _defaultModelKey = 'riz.defaultModel';
  final _secure = const FlutterSecureStorage();
  final _clients = <String, DaemonClient>{};
  final _reconnectTimers = <String, Timer>{};
  final _terminalListeners = <String, void Function(Uint8List)>{};
  final _globalLoads = <String, Future<void>>{};
  final _sessionCaches = <String, Map<String, _SessionMemoryCache>>{};
  final _sessionLoads = <String, Future<void>>{};
  final _sessionVersions = <String, int>{};
  Timer? _refreshTimer;
  Timer? _sessionRefreshTimer;

  @override
  RizState build() {
    ref.onDispose(() {
      for (final client in _clients.values) {
        unawaited(client.close());
      }
      _refreshTimer?.cancel();
      _sessionRefreshTimer?.cancel();
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
    final defaultModel = prefs.getString(_defaultModelKey);
    final settings = RizSettings(
      themeMode: ThemeMode.values.firstWhere(
        (v) => v.name == themeName,
        orElse: () => ThemeMode.system,
      ),
      locale: localeName == null ? null : Locale(localeName),
      defaultModel: defaultModel,
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

  Future<void> loadDaemonGlobals({String? connectionId, bool force = false}) {
    final id = connectionId ?? state.activeConnectionId;
    if (id == null) return Future.value();
    final existing = state.daemonGlobals[id];
    if (!force && existing?.loaded == true) return Future.value();
    final active = _globalLoads[id];
    if (active != null) return active;

    late final Future<void> tracked;
    tracked = _loadDaemonGlobals(id).whenComplete(() {
      if (identical(_globalLoads[id], tracked)) _globalLoads.remove(id);
    });
    _globalLoads[id] = tracked;
    return tracked;
  }

  Future<void> _loadDaemonGlobals(String connectionId) async {
    final daemon = _clients[connectionId];
    if (daemon == null) return;
    final previous =
        state.daemonGlobals[connectionId] ?? const DaemonGlobalData();
    _setDaemonGlobals(
      connectionId,
      previous.copyWith(loading: true, clearError: true),
    );

    Map<String, dynamic>? providerAuth;
    Object? authError;
    try {
      final response = await daemon.request('provider.auth.status');
      providerAuth = (response['auth'] as Map? ?? const {})
          .cast<String, dynamic>();
    } catch (error) {
      authError = error;
    }
    if (_clients[connectionId] != daemon) return;
    final authenticated = providerAuth?['state'] == 'authenticated';
    final results = await Future.wait([
      _loadGlobalList(daemon, 'provider.list', 'providers'),
      if (authenticated) _loadGlobalList(daemon, 'provider.models', 'models'),
      _loadGlobalList(daemon, 'provider.commands', 'commands'),
      _loadGlobalList(daemon, 'skill.list', 'skills'),
    ]);
    if (_clients[connectionId] != daemon) return;

    List<Map<String, dynamic>>? models;
    List<Map<String, dynamic>>? providers;
    List<Map<String, dynamic>>? commands;
    List<Map<String, dynamic>>? skills;
    final errors = <String>[if (authError != null) 'provider.auth: $authError'];
    for (final result in results) {
      if (result.error != null) {
        errors.add('${result.key}: ${result.error}');
      } else if (result.key == 'providers') {
        providers = result.values;
      } else if (result.key == 'models') {
        models = result.values;
      } else if (result.key == 'commands') {
        commands = result.values;
      } else if (result.key == 'skills') {
        skills = result.values
            .where((skill) => skill['scope'] == 'global')
            .toList();
      }
    }
    final current = state.daemonGlobals[connectionId] ?? previous;
    _setDaemonGlobals(
      connectionId,
      current.copyWith(
        loading: false,
        loaded: errors.isEmpty,
        models: models,
        providers: providers,
        providerAuth: providerAuth,
        commands: commands,
        globalSkills: skills,
        error: errors.isEmpty ? null : errors.join('\n'),
        clearError: errors.isEmpty,
      ),
    );
  }

  Future<({String key, List<Map<String, dynamic>> values, Object? error})>
  _loadGlobalList(DaemonClient daemon, String method, String key) async {
    try {
      final response = await daemon.request(method);
      return (
        key: key,
        values: (response[key] as List? ?? const [])
            .cast<Map>()
            .map((value) => value.cast<String, dynamic>())
            .toList(),
        error: null,
      );
    } catch (error) {
      return (key: key, values: const <Map<String, dynamic>>[], error: error);
    }
  }

  void _setDaemonGlobals(String connectionId, DaemonGlobalData data) {
    state = state.copyWith(
      daemonGlobals: {...state.daemonGlobals, connectionId: data},
    );
  }

  Future<Map<String, dynamic>> startProviderAuth() async {
    final response = await request('provider.auth.start');
    return (response['auth'] as Map).cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> providerAuthFlow(String sessionId) async {
    final response = await request('provider.auth.flow', {
      'sessionId': sessionId,
    });
    return (response['auth'] as Map).cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> submitProviderAuthCode(
    String sessionId,
    String code,
  ) async {
    final response = await request('provider.auth.submit', {
      'sessionId': sessionId,
      'code': code,
    });
    return (response['auth'] as Map).cast<String, dynamic>();
  }

  Future<void> cancelProviderAuth(String sessionId) async {
    await request('provider.auth.cancel', {'sessionId': sessionId});
  }

  Future<void> _connectOne(DaemonConnection connection) async {
    final token = await _secure.read(key: 'riz.token.${connection.id}');
    final relayToken = await _secure.read(
      key: 'riz.relayToken.${connection.id}',
    );
    if (token == null) {
      _connectionLog(
        connection.id,
        'token.missing',
        'error',
        'No saved bearer token',
      );
      return;
    }
    if (connection.usesRelay && relayToken == null) {
      const error =
          'Relay credential missing. Update this connection with its pairing code.';
      _connectionLog(connection.id, 'relay_token.missing', 'error', error);
      state = state.copyWith(
        daemonStatuses: {...state.daemonStatuses, connection.id: false},
        connected: connection.id == state.activeConnectionId
            ? false
            : state.connected,
        error: connection.id == state.activeConnectionId ? error : state.error,
      );
      return;
    }
    _connectionLog(connection.id, 'client.create', 'info', connection.url);
    late final DaemonClient daemon;
    daemon = DaemonClient(
      url: connection.url,
      token: token,
      protocols: relayToken == null ? null : ['riz-relay-v1.$relayToken'],
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
          unawaited(
            loadDaemonGlobals(connectionId: connection.id, force: true),
          );
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
    try {
      if (topic == 'snapshot' && data is Map) {
        for (final cache
            in _sessionCaches[connectionId]?.values ??
                const <_SessionMemoryCache>[]) {
          cache.dirty = true;
        }
        if (connectionId == state.activeConnectionId) {
          final snapshot = data.cast<String, dynamic>();
          state = state.copyWith(snapshot: snapshot);
          _cacheQuota(connectionId, snapshot['quota']);
          final selected = state.selectedSessionId;
          if (selected != null) {
            markSessionDirty(selected, connectionId: connectionId);
          }
        }
        return;
      }
      _applySessionEvent(connectionId, topic, data);
      if (connectionId != state.activeConnectionId) return;
      _refreshTimer?.cancel();
      _refreshTimer = Timer(const Duration(milliseconds: 120), () async {
        await refresh();
      });
    } catch (error) {
      _connectionLog(connectionId, 'event.failed', 'error', '$topic: $error');
    }
  }

  void _applySessionEvent(String connectionId, String topic, dynamic data) {
    if (data is! Map) return;
    final value = data.cast<String, dynamic>();
    if (topic == 'message.changed') {
      final sessionId = value['sessionId'] as String?;
      final cache = sessionId == null
          ? null
          : _sessionCaches[connectionId]?[sessionId];
      if (cache == null) return;
      final index = cache.messages.indexWhere(
        (message) => message['id'] == value['id'],
      );
      if (index < 0) {
        cache.messages = [...cache.messages, value];
      } else {
        cache.messages = [
          ...cache.messages.where((message) => message['id'] != value['id']),
          value,
        ];
      }
      _showCachedSession(connectionId, sessionId!, cache);
      return;
    }
    if (topic == 'message.removed') {
      final messageId = value['id'];
      for (final entry
          in _sessionCaches[connectionId]?.entries ??
              const <MapEntry<String, _SessionMemoryCache>>[]) {
        if (entry.value.messages.any((message) => message['id'] == messageId)) {
          entry.value.messages = entry.value.messages
              .where((message) => message['id'] != messageId)
              .toList();
          _showCachedSession(connectionId, entry.key, entry.value);
          break;
        }
      }
      return;
    }
    final sessionId =
        (value['sessionId'] ??
                (topic.startsWith('session.') ? value['id'] : null))
            as String?;
    if (sessionId == null) return;
    final cache = _sessionCaches[connectionId]?[sessionId];
    if (topic == 'permission.requested' && cache != null) {
      cache.pendingPermission = value;
      _showCachedSession(connectionId, sessionId, cache);
      return;
    }
    if (topic == 'input.requested' && cache != null) {
      cache.pendingInput = (value['input'] as Map?)?.cast<String, dynamic>();
      _showCachedSession(connectionId, sessionId, cache);
      return;
    }
    if (topic == 'turn.changed' || topic == 'session.status') {
      markSessionDirty(sessionId, connectionId: connectionId);
    }
  }

  Future<void> refresh() async {
    final c = client;
    final connectionId = state.activeConnectionId;
    if (c == null ||
        connectionId == null ||
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
      _cacheQuota(connectionId, value['quota']);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  void _cacheQuota(String connectionId, dynamic quota) {
    final data = state.daemonGlobals[connectionId] ?? const DaemonGlobalData();
    _setDaemonGlobals(
      connectionId,
      quota is Map
          ? data.copyWith(quota: quota.cast<String, dynamic>())
          : data.copyWith(clearQuota: true),
    );
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
    String? relayToken,
  }) async {
    final normalizedToken = token.trim();
    if (normalizedToken.isEmpty) throw ArgumentError('Token cannot be empty');
    final normalizedRelayToken = relayToken?.trim();
    if (normalizedRelayToken != null &&
        !RegExp(r'^[A-Za-z0-9_-]{32,256}$').hasMatch(normalizedRelayToken)) {
      throw ArgumentError('Invalid relay token');
    }
    final normalized = normalizeDaemonUrl(
      url,
      requireSecureWebSocket: kIsWeb && Uri.base.scheme == 'https',
    );
    final connection = DaemonConnection(
      id: const Uuid().v4(),
      name: name.trim().isEmpty ? 'Mac' : name.trim(),
      url: normalized,
      usesRelay: normalizedRelayToken != null,
    );
    final connections = [...state.connections, connection];
    await _secure.write(
      key: 'riz.token.${connection.id}',
      value: normalizedToken,
    );
    if (normalizedRelayToken != null) {
      await _secure.write(
        key: 'riz.relayToken.${connection.id}',
        value: normalizedRelayToken,
      );
    }
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

  Future<void> updateConnectionPairing(
    String id,
    RizPairingCode pairing,
  ) async {
    final normalizedUrl = normalizeDaemonUrl(
      pairing.url,
      requireSecureWebSocket: kIsWeb && Uri.base.scheme == 'https',
    );
    final previous = state.connections.where((item) => item.id == id).first;
    final connection = DaemonConnection(
      id: previous.id,
      name: pairing.name,
      url: normalizedUrl,
      usesRelay: true,
    );
    final connections = state.connections
        .map((item) => item.id == id ? connection : item)
        .toList();
    _reconnectTimers.remove(id)?.cancel();
    await _clients.remove(id)?.close();
    await _secure.write(key: 'riz.token.$id', value: pairing.token);
    await _secure.write(key: 'riz.relayToken.$id', value: pairing.relayToken);
    await _saveConnections(connections, state.activeConnectionId);
    _connectionLog(id, 'pairing.updated', 'info', normalizedUrl);
    state = state.copyWith(
      connections: connections,
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
    await _secure.delete(key: 'riz.relayToken.$id');
    _globalLoads.remove(id);
    _sessionCaches.remove(id);
    _sessionLoads.removeWhere((key, _) => key.startsWith('$id:'));
    _sessionVersions.removeWhere((key, _) => key.startsWith('$id:'));
    final connections = state.connections.where((c) => c.id != id).toList();
    final active = connections.firstOrNull?.id;
    await _saveConnections(connections, active);
    state = state.copyWith(
      connections: connections,
      activeConnectionId: active,
      clearActiveConnection: active == null,
      connected: false,
      snapshot: const {},
      daemonGlobals: {...state.daemonGlobals}..remove(id),
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
    final connectionId = state.activeConnectionId;
    if (connectionId != null) _sessionCaches[connectionId]?.remove(id);
    if (connectionId != null) _sessionVersions.remove('$connectionId:$id');
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
    final connectionId = state.activeConnectionId;
    if (connectionId == null) return;
    final cache = _sessionCaches[connectionId]?[id];
    state = state.copyWith(
      selectedSessionId: id,
      clearDraftSession: true,
      sessionLoading: cache == null,
      messages: cache?.messages ?? const [],
      pendingPermission: cache?.pendingPermission,
      clearPendingPermission: cache?.pendingPermission == null,
      pendingInput: cache?.pendingInput,
      clearPendingInput: cache?.pendingInput == null,
    );
    if (cache != null && !cache.dirty) return;
    await _loadSession(connectionId, id);
  }

  Future<void> _loadSession(String connectionId, String sessionId) {
    final key = '$connectionId:$sessionId';
    final active = _sessionLoads[key];
    if (active != null) return active;
    late final Future<void> tracked;
    tracked = _fetchSession(connectionId, sessionId).whenComplete(() {
      if (identical(_sessionLoads[key], tracked)) {
        _sessionLoads.remove(key);
        final cache = _sessionCaches[connectionId]?[sessionId];
        if (cache?.dirty == true &&
            state.activeConnectionId == connectionId &&
            state.selectedSessionId == sessionId) {
          Future.microtask(() => _loadSession(connectionId, sessionId));
        }
      }
    });
    _sessionLoads[key] = tracked;
    return tracked;
  }

  Future<void> _fetchSession(String connectionId, String id) async {
    final daemon = _clients[connectionId];
    final cacheKey = '$connectionId:$id';
    final version = _sessionVersions[cacheKey] ?? 0;
    try {
      final data = connectionId == state.activeConnectionId
          ? await request('session.get', {'id': id})
          : await (daemon ?? (throw StateError('Daemon is not connected')))
                .request('session.get', {'id': id});
      final cache = _SessionMemoryCache(
        messages: (data['messages'] as List? ?? const [])
            .cast<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList(),
        pendingPermission: (data['pendingPermission'] as Map?)
            ?.cast<String, dynamic>(),
        pendingInput: (data['pendingInput'] as Map?)?.cast<String, dynamic>(),
      );
      cache.dirty = (_sessionVersions[cacheKey] ?? 0) != version;
      (_sessionCaches[connectionId] ??= {})[id] = cache;
      _showCachedSession(connectionId, id, cache);
    } catch (error) {
      if (state.activeConnectionId == connectionId &&
          state.selectedSessionId == id) {
        state = state.copyWith(sessionLoading: false, error: error.toString());
      }
    }
  }

  void markSessionDirty(String sessionId, {String? connectionId}) {
    final daemonId = connectionId ?? state.activeConnectionId;
    if (daemonId == null) return;
    final key = '$daemonId:$sessionId';
    _sessionVersions[key] = (_sessionVersions[key] ?? 0) + 1;
    final cache = _sessionCaches[daemonId]?[sessionId];
    if (cache == null) return;
    cache.dirty = true;
    if (daemonId != state.activeConnectionId ||
        sessionId != state.selectedSessionId) {
      return;
    }
    _sessionRefreshTimer?.cancel();
    _sessionRefreshTimer = Timer(const Duration(milliseconds: 120), () {
      if (state.activeConnectionId == daemonId &&
          state.selectedSessionId == sessionId) {
        unawaited(_loadSession(daemonId, sessionId));
      }
    });
  }

  void _showCachedSession(
    String connectionId,
    String sessionId,
    _SessionMemoryCache cache,
  ) {
    if (state.activeConnectionId != connectionId ||
        state.selectedSessionId != sessionId) {
      return;
    }
    state = state.copyWith(
      sessionLoading: false,
      messages: cache.messages,
      pendingPermission: cache.pendingPermission,
      clearPendingPermission: cache.pendingPermission == null,
      pendingInput: cache.pendingInput,
      clearPendingInput: cache.pendingInput == null,
      clearError: true,
    );
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
      final initialModel =
          model ?? draft['model']?.toString() ?? state.settings.defaultModel;
      final session = await request('session.create', {
        'projectId': ?draft['projectId'],
        'title': draft['title'],
        'provider': draft['provider'] ?? 'agy',
        'permissionMode': draft['permissionMode'] ?? 'workspace',
        'model': ?initialModel,
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
      final effectiveModel =
          model ?? session?['model']?.toString() ?? state.settings.defaultModel;
      await request('session.send', {
        'sessionId': id,
        'delivery': mode,
        'content': {
          'text': text.trim(),
          'attachments': remoteAttachments,
          'model': ?effectiveModel,
        },
      });
      markSessionDirty(id);
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

  Future<void> stopTask(String sessionId, String taskId) async {
    await request('session.task.stop', {
      'sessionId': sessionId,
      'taskId': taskId,
    });
  }

  Future<void> respondPermission(bool allow) async {
    final id = state.selectedSessionId;
    if (id == null) return;
    await request('session.permission.respond', {
      'sessionId': id,
      'allow': allow,
    });
    final connectionId = state.activeConnectionId;
    final cache = connectionId == null
        ? null
        : _sessionCaches[connectionId]?[id];
    if (cache != null) cache.pendingPermission = null;
    markSessionDirty(id);
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
    final connectionId = state.activeConnectionId;
    final cache = connectionId == null
        ? null
        : _sessionCaches[connectionId]?[id];
    if (cache != null) cache.pendingInput = null;
    markSessionDirty(id);
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

  Future<void> updateDefaultModel(String? model) async {
    final prefs = await SharedPreferences.getInstance();
    if (model == null || model.isEmpty) {
      await prefs.remove(_defaultModelKey);
      state = state.copyWith(
        settings: state.settings.copyWith(clearDefaultModel: true),
      );
    } else {
      await prefs.setString(_defaultModelKey, model);
      state = state.copyWith(
        settings: state.settings.copyWith(defaultModel: model),
      );
    }
  }

  Future<void> setSessionModel(String id, String? model) async {
    if (state.isDraftSession) {
      final draft = state.draftSession;
      if (draft != null) {
        state = state.copyWith(
          draftSession: {
            ...draft,
            if (model != null) 'model': model else ...{'model': null},
          },
        );
      }
      return;
    }
    final session = await request('session.model.set', {
      'sessionId': id,
      'model': ?model,
    });
    final snapshot = {...state.snapshot};
    snapshot['sessions'] = state.sessions
        .map((item) => item['id'] == id ? session : item)
        .toList();
    state = state.copyWith(snapshot: snapshot, clearError: true);
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
