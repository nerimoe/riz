import 'package:flutter/material.dart';

class DaemonConnection {
  const DaemonConnection({
    required this.id,
    required this.name,
    required this.url,
    this.usesRelay = false,
  });
  final String id;
  final String name;
  final String url;
  final bool usesRelay;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'usesRelay': usesRelay,
  };
  factory DaemonConnection.fromJson(Map<String, dynamic> json) {
    final url = json['url'] as String;
    return DaemonConnection(
      id: json['id'] as String,
      name: json['name'] as String,
      url: url,
      usesRelay:
          json['usesRelay'] as bool? ??
          RegExp(r'/v1/relay/[^/]+/client/?$').hasMatch(Uri.parse(url).path),
    );
  }
}

class RizSettings {
  const RizSettings({
    this.themeMode = ThemeMode.system,
    this.locale,
    this.defaultModel,
  });
  final ThemeMode themeMode;
  final Locale? locale;
  final String? defaultModel;
  RizSettings copyWith({
    ThemeMode? themeMode,
    Locale? locale,
    bool systemLocale = false,
    String? defaultModel,
    bool clearDefaultModel = false,
  }) => RizSettings(
    themeMode: themeMode ?? this.themeMode,
    locale: systemLocale ? null : locale ?? this.locale,
    defaultModel: clearDefaultModel ? null : defaultModel ?? this.defaultModel,
  );
}

class ConnectionLogEntry {
  const ConnectionLogEntry({
    required this.timestamp,
    required this.connectionId,
    required this.level,
    required this.event,
    this.detail,
  });

  final DateTime timestamp;
  final String connectionId;
  final String level;
  final String event;
  final String? detail;

  String get copyText {
    final suffix = detail == null || detail!.isEmpty ? '' : ' - $detail';
    return '${timestamp.toIso8601String()} [$level] $connectionId $event$suffix';
  }
}

class DaemonGlobalData {
  const DaemonGlobalData({
    this.loading = false,
    this.loaded = false,
    this.models = const [],
    this.commands = const [],
    this.globalSkills = const [],
    this.providers = const [],
    this.providerAuth,
    this.quota,
    this.error,
  });

  final bool loading;
  final bool loaded;
  final List<Map<String, dynamic>> models;
  final List<Map<String, dynamic>> commands;
  final List<Map<String, dynamic>> globalSkills;
  final List<Map<String, dynamic>> providers;
  final Map<String, dynamic>? providerAuth;
  final Map<String, dynamic>? quota;
  final String? error;

  DaemonGlobalData copyWith({
    bool? loading,
    bool? loaded,
    List<Map<String, dynamic>>? models,
    List<Map<String, dynamic>>? commands,
    List<Map<String, dynamic>>? globalSkills,
    List<Map<String, dynamic>>? providers,
    Map<String, dynamic>? providerAuth,
    bool clearProviderAuth = false,
    Map<String, dynamic>? quota,
    bool clearQuota = false,
    String? error,
    bool clearError = false,
  }) => DaemonGlobalData(
    loading: loading ?? this.loading,
    loaded: loaded ?? this.loaded,
    models: models ?? this.models,
    commands: commands ?? this.commands,
    globalSkills: globalSkills ?? this.globalSkills,
    providers: providers ?? this.providers,
    providerAuth: clearProviderAuth ? null : providerAuth ?? this.providerAuth,
    quota: clearQuota ? null : quota ?? this.quota,
    error: clearError ? null : error ?? this.error,
  );
}

class RizState {
  const RizState({
    this.loading = true,
    this.connections = const [],
    this.activeConnectionId,
    this.connected = false,
    this.error,
    this.snapshot = const {},
    this.selectedProjectId,
    this.selectedSessionId,
    this.draftSession,
    this.sessionLoading = false,
    this.messages = const [],
    this.pendingPermission,
    this.pendingInput,
    this.settings = const RizSettings(),
    this.navigationIndex = 0,
    this.daemonStatuses = const {},
    this.daemonGlobals = const {},
    this.connectionLogs = const [],
  });
  final bool loading;
  final List<DaemonConnection> connections;
  final String? activeConnectionId;
  final bool connected;
  final String? error;
  final Map<String, dynamic> snapshot;
  final String? selectedProjectId;
  final String? selectedSessionId;
  final Map<String, dynamic>? draftSession;
  final bool sessionLoading;
  final List<Map<String, dynamic>> messages;
  final Map<String, dynamic>? pendingPermission;
  final Map<String, dynamic>? pendingInput;
  final RizSettings settings;
  final int navigationIndex;
  final Map<String, bool> daemonStatuses;
  final Map<String, DaemonGlobalData> daemonGlobals;
  final List<ConnectionLogEntry> connectionLogs;

  DaemonGlobalData? get activeDaemonGlobals =>
      activeConnectionId == null ? null : daemonGlobals[activeConnectionId];

  List<Map<String, dynamic>> get allProjects =>
      (snapshot['projects'] as List? ?? const [])
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
  List<Map<String, dynamic>> get projects => allProjects;
  List<Map<String, dynamic>> get sessions =>
      (snapshot['sessions'] as List? ?? const [])
          .cast<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
  Map<String, dynamic>? get selectedProject =>
      allProjects.where((p) => p['id'] == selectedProjectId).firstOrNull;
  Map<String, dynamic>? get selectedSession =>
      sessions.where((s) => s['id'] == selectedSessionId).firstOrNull;
  Map<String, dynamic>? get activeSession => draftSession ?? selectedSession;
  bool get isDraftSession => draftSession != null;
  bool get isUnboundSession =>
      activeSession != null && activeSession?['projectId'] == null;
  List<Map<String, dynamic>> get quickChatSessions =>
      sessions.where((session) => session['projectId'] == null).toList();

  RizState copyWith({
    bool? loading,
    List<DaemonConnection>? connections,
    String? activeConnectionId,
    bool clearActiveConnection = false,
    bool? connected,
    String? error,
    bool clearError = false,
    Map<String, dynamic>? snapshot,
    String? selectedProjectId,
    bool clearProject = false,
    String? selectedSessionId,
    bool clearSession = false,
    Map<String, dynamic>? draftSession,
    bool clearDraftSession = false,
    bool? sessionLoading,
    List<Map<String, dynamic>>? messages,
    Map<String, dynamic>? pendingPermission,
    bool clearPendingPermission = false,
    Map<String, dynamic>? pendingInput,
    bool clearPendingInput = false,
    RizSettings? settings,
    int? navigationIndex,
    Map<String, bool>? daemonStatuses,
    Map<String, DaemonGlobalData>? daemonGlobals,
    List<ConnectionLogEntry>? connectionLogs,
  }) => RizState(
    loading: loading ?? this.loading,
    connections: connections ?? this.connections,
    activeConnectionId: clearActiveConnection
        ? null
        : activeConnectionId ?? this.activeConnectionId,
    connected: connected ?? this.connected,
    error: clearError ? null : error ?? this.error,
    snapshot: snapshot ?? this.snapshot,
    selectedProjectId: clearProject
        ? null
        : selectedProjectId ?? this.selectedProjectId,
    selectedSessionId: clearSession
        ? null
        : selectedSessionId ?? this.selectedSessionId,
    draftSession: clearDraftSession ? null : draftSession ?? this.draftSession,
    sessionLoading: sessionLoading ?? this.sessionLoading,
    messages: messages ?? this.messages,
    pendingPermission: clearPendingPermission
        ? null
        : pendingPermission ?? this.pendingPermission,
    pendingInput: clearPendingInput ? null : pendingInput ?? this.pendingInput,
    settings: settings ?? this.settings,
    navigationIndex: navigationIndex ?? this.navigationIndex,
    daemonStatuses: daemonStatuses ?? this.daemonStatuses,
    daemonGlobals: daemonGlobals ?? this.daemonGlobals,
    connectionLogs: connectionLogs ?? this.connectionLogs,
  );
}

extension FirstOrNullX<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
