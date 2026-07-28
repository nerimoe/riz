import 'package:flutter/material.dart';

class DaemonConnection {
  const DaemonConnection({
    required this.id,
    required this.name,
    required this.url,
  });
  final String id;
  final String name;
  final String url;
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'url': url};
  factory DaemonConnection.fromJson(Map<String, dynamic> json) =>
      DaemonConnection(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
      );
}

class RizSettings {
  const RizSettings({this.themeMode = ThemeMode.system, this.locale});
  final ThemeMode themeMode;
  final Locale? locale;
  RizSettings copyWith({
    ThemeMode? themeMode,
    Locale? locale,
    bool systemLocale = false,
  }) => RizSettings(
    themeMode: themeMode ?? this.themeMode,
    locale: systemLocale ? null : locale ?? this.locale,
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
  );
}

extension FirstOrNullX<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
