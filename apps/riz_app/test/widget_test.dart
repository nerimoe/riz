import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riz_app/models.dart';
import 'package:riz_app/providers/app_controller.dart';
import 'package:riz_app/ui/riz_home.dart';

class _ResponsiveController extends AppController {
  @override
  RizState build() => const RizState(
    loading: false,
    connections: [
      DaemonConnection(id: 'd1', name: 'My Mac', url: 'wss://mac.example/ws'),
    ],
    activeConnectionId: 'd1',
    connected: true,
    daemonStatuses: {'d1': true},
    selectedProjectId: 'p1',
    selectedSessionId: 's1',
    snapshot: {
      'projects': [
        {
          'id': 'p1',
          'name': 'Riz',
          'runtimePath': '/Users/test/.riz/projects/p1/runtime',
          'folders': [
            {'id': 'f1', 'path': '/Users/test/riz'},
          ],
        },
      ],
      'sessions': [
        {
          'id': 's1',
          'projectId': 'p1',
          'title': 'Responsive session',
          'status': 'completed',
          'permissionMode': 'workspace',
          'workspacePath': '/Users/test/.riz/sessions/s1',
          'archivedAt': null,
        },
      ],
    },
    messages: [
      {
        'id': 'm1',
        'role': 'assistant',
        'status': 'completed',
        'content': {'text': 'Responsive message'},
      },
    ],
  );
}

class _LoadingSessionController extends _ResponsiveController {
  @override
  RizState build() =>
      super.build().copyWith(sessionLoading: true, messages: const []);
}

class _QuestionController extends _ResponsiveController {
  @override
  RizState build() => super.build().copyWith(
    pendingInput: const {
      'question': 'Choose a target',
      'options': ['Frontend', 'Backend'],
      'multiSelect': false,
    },
  );
}

class _BackgroundTaskController extends _ResponsiveController {
  final stoppedTasks = <String>[];

  @override
  RizState build() => super.build().copyWith(
    messages: const [
      {
        'id': 'task-message',
        'sessionId': 's1',
        'role': 'assistant',
        'status': 'running',
        'content': {
          'text': '',
          'structuredEvents': [
            {
              'index': 3,
              'type': 'tool_result',
              'name': 'run_command',
              'status': 'RUNNING',
              'task': {
                'id': '00000000-0000-0000-0000-000000000003/task-3',
                'description': 'clone repositories',
                'status': 'RUNNING',
                'logTail': 'Cloning riz...\n',
                'supportsInput': false,
              },
            },
          ],
        },
      },
    ],
  );

  @override
  Future<void> stopTask(String sessionId, String taskId) async {
    stoppedTasks.add('$sessionId:$taskId');
  }
}

class _EmptyProjectController extends AppController {
  @override
  RizState build() => const RizState(
    loading: false,
    connections: [
      DaemonConnection(id: 'd1', name: 'My Mac', url: 'wss://mac.example/ws'),
    ],
    activeConnectionId: 'd1',
    connected: true,
    daemonStatuses: {'d1': true},
    snapshot: {
      'projects': [
        {
          'id': 'p1',
          'name': 'Riz',
          'runtimePath': '/Users/test/.riz/projects/p1/runtime',
          'folders': [],
        },
      ],
      'sessions': [],
    },
  );
}

class _ProjectOnlyController extends AppController {
  @override
  RizState build() => const RizState(
    loading: false,
    connections: [
      DaemonConnection(id: 'd1', name: 'My Mac', url: 'wss://mac.example/ws'),
    ],
    activeConnectionId: 'd1',
    connected: true,
    daemonStatuses: {'d1': true},
    selectedProjectId: 'p1',
    snapshot: {
      'projects': [
        {
          'id': 'p1',
          'name': 'Riz',
          'runtimePath': '/tmp/.riz/projects/p1/runtime',
          'folders': [],
        },
      ],
      'sessions': [],
    },
  );
}

class _DraftController extends _ProjectOnlyController {
  @override
  RizState build() => super.build().copyWith(
    draftSession: const {
      'id': 'draft:one',
      'projectId': 'p1',
      'title': 'New session',
      'status': 'completed',
      'permissionMode': 'workspace',
    },
  );
}

class _DelayedModelsController extends _DraftController {
  final models = Completer<Map<String, dynamic>>();
  var modelRequests = 0;

  @override
  Future<void> loadDaemonGlobals({
    String? connectionId,
    bool force = false,
  }) async {
    modelRequests++;
    final response = await models.future;
    state = state.copyWith(
      daemonGlobals: {
        'd1': DaemonGlobalData(
          loaded: true,
          models: (response['models'] as List)
              .cast<Map>()
              .map((model) => model.cast<String, dynamic>())
              .toList(),
        ),
      },
    );
  }
}

class _SessionCacheController extends _ResponsiveController {
  var sessionRequests = 0;

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (method != 'session.get') {
      throw StateError('unexpected request: $method');
    }
    sessionRequests++;
    return {
      'messages': [
        {
          'id': 'cached-$sessionRequests',
          'sessionId': params['id'],
          'role': 'assistant',
          'content': {'text': 'Cached response $sessionRequests'},
        },
      ],
      'pendingPermission': null,
      'pendingInput': null,
    };
  }
}

class _FailedFirstSendController extends _DraftController {
  final calls = <String>[];

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add(method);
    if (method == 'session.create') {
      return {
        'id': 'materialized-one',
        'projectId': 'p1',
        'workspacePath': '/tmp/.riz/sessions/materialized-one',
        'title': 'New session',
      };
    }
    if (method == 'session.send') throw StateError('send failed');
    if (method == 'session.delete') return {'removed': true};
    throw StateError('unexpected request: $method');
  }
}

class _UnboundSessionController extends AppController {
  @override
  RizState build() => const RizState(
    loading: false,
    selectedSessionId: 's1',
    snapshot: {
      'projects': [],
      'sessions': [
        {
          'id': 's1',
          'projectId': null,
          'title': 'Quick question',
          'status': 'completed',
          'archivedAt': null,
          'workspacePath': '/tmp/.riz/sessions/s1',
        },
      ],
    },
  );
}

class _ConnectedUnboundSessionController extends _UnboundSessionController {
  @override
  RizState build() => super.build().copyWith(
    connections: const [
      DaemonConnection(id: 'd1', name: 'My Mac', url: 'wss://mac.example/ws'),
    ],
    activeConnectionId: 'd1',
    connected: true,
    daemonStatuses: const {'d1': true},
  );
}

class _SettingsController extends _EmptyProjectController {
  @override
  RizState build() => super.build().copyWith(
    navigationIndex: 3,
    connected: false,
    error: 'WebSocketException: handshake failed',
    daemonStatuses: const {'d1': false},
    connectionLogs: [
      ConnectionLogEntry(
        timestamp: DateTime(2026, 7, 28, 17, 4, 3, 12),
        connectionId: 'd1',
        level: 'error',
        event: 'connect.failed',
        detail: 'WebSocketException: handshake failed',
      ),
    ],
  );

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async => switch (method) {
    'daemon.update.status' => {
      'currentVersion': '0.1.0',
      'channel': 'stable',
      'repository': 'nerimoe/riz',
    },
    'daemon.update.check' => {
      'currentVersion': '0.1.0',
      'targetVersion': '0.1.1',
      'channel': params['channel'],
      'available': true,
      'compatible': true,
      'publishedAt': '2026-07-28T00:00:00Z',
    },
    _ => throw StateError('unexpected request: $method'),
  };
}

void main() {
  test('state preserves the daemon-project-session hierarchy', () {
    final state = RizState(
      loading: false,
      snapshot: const {
        'projects': [
          {
            'id': 'p1',
            'name': 'Riz',
            'runtimePath': '/tmp/.riz/projects/p1/runtime',
            'folders': [],
          },
        ],
        'sessions': [
          {
            'id': 's1',
            'projectId': 'p1',
            'title': 'Build',
            'status': 'running',
          },
        ],
      },
      selectedProjectId: 'p1',
      selectedSessionId: 's1',
    );
    expect(
      state.selectedProject?['runtimePath'],
      '/tmp/.riz/projects/p1/runtime',
    );
    expect(state.selectedSession?['projectId'], state.selectedProject?['id']);
  });

  test('state exposes unbound sessions as quick-chat history', () {
    final state = RizState(
      loading: false,
      snapshot: const {
        'projects': [
          {'id': 'p1', 'name': 'Riz', 'folders': []},
        ],
        'sessions': [
          {'id': 's1', 'projectId': null, 'title': 'Quick question'},
        ],
      },
    );
    expect(state.projects.map((project) => project['id']), ['p1']);
    expect(state.quickChatSessions.single['id'], 's1');
  });

  test('empty selection is not treated as an unbound session', () {
    const state = RizState(loading: false);
    expect(state.activeSession, isNull);
    expect(state.isUnboundSession, isFalse);
  });

  test('new sessions remain local drafts until the first send', () async {
    final container = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(_ProjectOnlyController.new),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(appControllerProvider.notifier);

    controller.createSession();
    expect(container.read(appControllerProvider).isDraftSession, isTrue);
    expect(container.read(appControllerProvider).sessions, isEmpty);
    await controller.setPermissionMode('full');
    expect(
      container.read(appControllerProvider).draftSession?['permissionMode'],
      'full',
    );
    controller.selectProject('p1');
    expect(container.read(appControllerProvider).draftSession, isNull);
  });

  test(
    'failed first send removes the materialized session and keeps draft',
    () async {
      final controller = _FailedFirstSendController();
      final container = ProviderContainer(
        overrides: [appControllerProvider.overrideWith(() => controller)],
      );
      addTearDown(container.dispose);
      container.read(appControllerProvider);

      await expectLater(
        container
            .read(appControllerProvider.notifier)
            .sendMessage('retry this'),
        throwsA(isA<StateError>()),
      );

      expect(controller.calls, [
        'session.create',
        'session.send',
        'session.delete',
      ]);
      expect(container.read(appControllerProvider).isDraftSession, isTrue);
      expect(container.read(appControllerProvider).selectedSessionId, isNull);
    },
  );

  test('leaving an unbound chat keeps project selection empty', () async {
    final container = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(_UnboundSessionController.new),
      ],
    );
    addTearDown(container.dispose);

    await container.read(appControllerProvider.notifier).selectSession(null);
    final state = container.read(appControllerProvider);
    expect(state.selectedSessionId, isNull);
    expect(state.selectedProjectId, isNull);
  });

  testWidgets('draft chat opens immediately and shows the current model', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith(_DraftController.new)],
        child: const MaterialApp(home: RizHome()),
      ),
    );
    await tester.pump();
    expect(find.text('Send the first message'), findsOneWidget);
    expect(find.text('Default model'), findsOneWidget);
  });

  testWidgets('model menu waits for models before it opens', (tester) async {
    final controller = _DelayedModelsController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith(() => controller)],
        child: const MaterialApp(home: RizHome()),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Default model'));
    await tester.pump();
    expect(find.byType(CheckedPopupMenuItem<String>), findsNothing);

    controller.models.complete({
      'models': [
        {'id': 'gemini-test', 'name': 'Gemini Test'},
      ],
    });
    await tester.pumpAndSettle();

    expect(find.text('Gemini Test'), findsOneWidget);
    expect(controller.modelRequests, 1);

    await tester.tap(find.byType(CheckedPopupMenuItem<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('gemini-test'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckedPopupMenuItem<String>), findsWidgets);
    expect(controller.modelRequests, 1);
  });

  test('session history only refetches after its cache is dirty', () async {
    final controller = _SessionCacheController();
    final container = ProviderContainer(
      overrides: [appControllerProvider.overrideWith(() => controller)],
    );
    addTearDown(container.dispose);
    container.read(appControllerProvider);

    await controller.selectSession('s1');
    await controller.selectSession(null);
    await controller.selectSession('s1');
    expect(controller.sessionRequests, 1);
    expect(
      container.read(appControllerProvider).messages.single['id'],
      'cached-1',
    );

    await controller.selectSession(null);
    controller.markSessionDirty('s1', connectionId: 'd1');
    await controller.selectSession('s1');
    expect(controller.sessionRequests, 2);
    expect(
      container.read(appControllerProvider).messages.single['id'],
      'cached-2',
    );
  });

  testWidgets('first screen starts in a loading state', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: RizHome())),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('session loading replaces stale content with feedback', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(_LoadingSessionController.new),
        ],
        child: const MaterialApp(home: RizHome()),
      ),
    );
    expect(find.text('Loading conversation…'), findsOneWidget);
    expect(find.text('Responsive message'), findsNothing);
  });

  testWidgets('pending model question exposes selectable answers', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(_QuestionController.new),
        ],
        child: const MaterialApp(home: RizHome()),
      ),
    );
    expect(find.text('Choose a target'), findsOneWidget);
    expect(find.text('Frontend'), findsOneWidget);
    await tester.tap(find.text('Frontend'));
    await tester.pump();
    final answer = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Answer'),
    );
    expect(answer.onPressed, isNotNull);
  });

  for (final width in [390.0, 600.0, 840.0, 1440.0]) {
    testWidgets('project chat has no layout exceptions at ${width.toInt()}px', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appControllerProvider.overrideWith(_ResponsiveController.new),
          ],
          child: const MaterialApp(home: RizHome()),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Responsive session'), findsWidgets);
      expect(find.text('Responsive message'), findsOneWidget);
    });
  }

  testWidgets('wide shell merges navigation into the project sidebar', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(_EmptyProjectController.new),
        ],
        child: const MaterialApp(home: RizHome()),
      ),
    );

    expect(find.byType(NavigationRail), findsNothing);
    expect(find.text('Projects'), findsWidgets);
    expect(find.text('Running tasks'), findsOneWidget);
    expect(find.text('Global skills'), findsOneWidget);
    expect(find.text('Quota'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone shell uses a drawer without rail or bottom navigation', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(_EmptyProjectController.new),
        ],
        child: const MaterialApp(home: RizHome()),
      ),
    );

    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).drawer, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone settings checks and presents daemon updates', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(_SettingsController.new),
        ],
        child: const MaterialApp(home: RizHome()),
      ),
    );
    await tester.pump();

    expect(find.text('Version 1.0.0+12'), findsOneWidget);
    expect(find.text('Current version: 0.1.0'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Check for updates'));
    await tester.pump();
    expect(find.text('Update available: 0.1.1'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Update rizd'),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone settings opens and clears connection diagnostics', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(_SettingsController.new),
        ],
        child: const MaterialApp(home: RizHome()),
      ),
    );
    await tester.pump();

    final diagnostics = find.text('Connection diagnostics');
    await tester.scrollUntilVisible(
      diagnostics,
      240,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -80));
    await tester.pump();
    await tester.tap(diagnostics);
    await tester.pumpAndSettle();

    expect(find.text('connect.failed'), findsOneWidget);
    expect(
      find.text('WebSocketException: handshake failed'),
      findsAtLeastNWidgets(1),
    );
    expect(find.widgetWithText(OutlinedButton, 'Copy log'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Clear'));
    await tester.pump();
    expect(find.text('No connection logs yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty project keeps Files and Terminal on its runtime', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(_ProjectOnlyController.new),
        ],
        child: const MaterialApp(home: RizHome()),
      ),
    );

    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    await tester.tap(find.text('Files'));
    await tester.pump();
    expect(find.text('Add a folder to this project first'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('materialized quick chat exposes its runtime workspace', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(
            _ConnectedUnboundSessionController.new,
          ),
        ],
        child: const MaterialApp(home: RizHome()),
      ),
    );

    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('running background task shows live output and can be stopped', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final controller = _BackgroundTaskController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith(() => controller)],
        child: const MaterialApp(home: RizHome()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('clone repositories'), findsOneWidget);
    expect(find.text('Cloning riz...\n'), findsOneWidget);
    final stop = find.byTooltip('Stop background task');
    expect(stop, findsOneWidget);
    await tester.tap(stop);
    await tester.pump();
    expect(controller.stoppedTasks, [
      's1:00000000-0000-0000-0000-000000000003/task-3',
    ]);
    expect(tester.takeException(), isNull);
  });
}
