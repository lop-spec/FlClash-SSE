import 'dart:async';

import 'package:fl_clash/common/sse_history.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

import '../helpers/test_profiles.dart';

class _Core extends CoreHandlerInterface {
  final calls = <CoreMethod>[];
  Map<String, dynamic> response = {};
  final queue = <Map<String, dynamic>>[];
  bool fail = false;
  Completer<Map<String, dynamic>>? pendingCatalog;

  @override
  Future<CoreLifecycleResult> start() async => const CoreLifecycleResult(
    revision: 1,
    outcome: CoreLifecycleOutcome.applied,
  );
  @override
  Future<CoreLifecycleResult> restart() => start();
  @override
  Future<CoreLifecycleResult> stop() => start();
  @override
  Future<CoreLifecycleResult> close() => start();
  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async {
    calls.add(method);
    if (fail) throw StateError('test transport failure');
    if (method == CoreMethod.sseCatalog && pendingCatalog != null) {
      return (await pendingCatalog!.future) as T;
    }
    if (queue.isNotEmpty) return queue.removeAt(0) as T;
    return response as T;
  }
}

class _Setup extends SetupAction {
  int applies = 0;
  bool applySuccess = true;

  @override
  Future<bool> fullSetup() async {
    applies++;
    return applySuccess;
  }

  @override
  Future<bool> setRunning(bool running, {bool initialize = false}) async =>
      true;
  @override
  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    Future<void> Function()? preloadInvoke,
  }) async {
    await preloadInvoke?.call();
    return true;
  }
}

Map<String, dynamic> catalog() => {
  'nodes': [
    {
      'key': 'old',
      'aliases': [
        {
          'profileId': 404,
          'name': 'removed',
          'selections': {'GLOBAL': 'removed'},
        },
      ],
    },
    {
      'key': 'buffered',
      'aliases': [
        {
          'profileId': 1,
          'name': 'buffered',
          'selections': {'GLOBAL': 'buffered'},
        },
      ],
    },
    {
      'key': 'good',
      'aliases': [
        {
          'profileId': 2,
          'name': 'winner',
          'selections': {'GLOBAL': 'winner', 'Select': 'winner'},
        },
      ],
    },
  ],
  'history': {
    'old': {'score': 20, 'latest': done(120)},
    'buffered': {
      'score': 9,
      'latest': {'status': 'blocked', 'error': 'Claude: HTTP 403'},
    },
    'good': {'score': 5, 'latest': done(180)},
  },
};

Map<String, dynamic> done(num latency) => {
  'status': 'done',
  'samples': SseHistory.samples,
  'latencyMs': latency,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Core native;
  late CoreController core;
  late ProviderContainer container;

  setUp(() {
    SseHistory.instance.nodes = [];
    SseHistory.instance.history = {};
    SseHistory.instance.attemptedKeys = {};
    SseHistory.instance.tournament = {};
    native = _Core()..response = catalog();
    core = CoreController.scoped(native);
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(
          () => TestProfiles([
            Profile.normal(label: 'one').copyWith(id: 1),
            Profile.normal(label: 'two')
                .copyWith(id: 2, selectedMap: {'Unrelated': 'keep'}),
          ]),
        ),
        currentProfileIdProvider.overrideWithBuild((_, _) => 1),
        coreHandlerProvider.overrideWithValue(core),
        setupActionProvider.overrideWith(_Setup.new),
      ],
    );
    globalState.container = container;
    globalState.needInitStatus = true;
  });
  tearDown(() {
    container.dispose();
    globalState.needInitStatus = true;
  });

  test(
    'late catalog cannot roll back a completed background measurement',
    () async {
      final store = SseHistory();
      native.pendingCatalog = Completer<Map<String, dynamic>>();
      final loading = store.load(core, [1, 2]);
      await store.run(core, [1, 2]);
      expect(store.nodes, isNotEmpty);
      final keys = store.attemptedKeys;
      native.pendingCatalog!.complete({'nodes': [], 'history': {}});
      await loading;
      expect(store.nodes, isNotEmpty);
      expect(store.attemptedKeys, keys);
      store.dispose();
    },
  );

  test('same subscription applies selection paths; invalid and failed choices are reported', () async {
    final action = container.read(profilesActionProvider.notifier);
    final setup = container.read(setupActionProvider.notifier) as _Setup;
    await action.selectSseNode({
      'profileId': 1,
      'selections': {'GLOBAL': 'chosen', 'Select': 'chosen'},
    });
    expect(container.read(currentProfileIdProvider), 1);
    expect(
      container.read(profilesProvider).first.selectedMap['Select'],
      'chosen',
    );
    expect(setup.applies, 1);
    expect(native.calls, isEmpty);
    await expectLater(
      action.selectSseNode({'profileId': 404}),
      throwsStateError,
    );
    await expectLater(action.selectSseNode({'profileId': 1}), throwsStateError);
    setup.applySuccess = false;
    await expectLater(
      action.selectSseNode({
        'profileId': 1,
        'selections': {'GLOBAL': 'bad'},
      }),
      throwsStateError,
    );
  });

  test(
    'another subscription retains unrelated routes before switching',
    () async {
      await container.read(profilesActionProvider.notifier).selectSseNode({
        'profileId': 2,
        'selections': {'GLOBAL': 'chosen', 'Select': 'chosen'},
      });
      expect(container.read(currentProfileIdProvider), 2);
      expect(container.read(profilesProvider).last.selectedMap, {
        'Unrelated': 'keep',
        'GLOBAL': 'chosen',
        'Select': 'chosen',
      });
      expect(
        (container.read(setupActionProvider.notifier) as _Setup).applies,
        0,
      );
      expect(native.calls, isEmpty);
    },
  );

  test('startup selects the top-scoring surviving usable node without measuring', () async {
    await container.read(setupActionProvider.notifier).initStatus();
    expect(container.read(currentProfileIdProvider), 2);
    expect(container.read(profilesProvider).last.selectedMap, {
      'Unrelated': 'keep',
      'GLOBAL': 'winner',
      'Select': 'winner',
    });
    expect(native.calls, [CoreMethod.sseCatalog]);
    await container.read(setupActionProvider.notifier).initStatus();
    expect(native.calls, [CoreMethod.sseCatalog]);
  });

  test(
    'startup with no imported subscriptions does not invoke the core',
    () async {
      (container.read(profilesProvider.notifier) as TestProfiles).replace([]);
      await container.read(setupActionProvider.notifier).initStatus();
      expect(native.calls, isEmpty);
      expect(container.read(currentProfileIdProvider), 1);
    },
  );

  test(
    'missing or unavailable history preserves the existing choice',
    () async {
      native.response = {'nodes': [], 'history': {}};
      await container.read(setupActionProvider.notifier).initStatus();
      expect(container.read(currentProfileIdProvider), 1);
      expect(native.calls, [CoreMethod.sseCatalog]);
    },
  );

  test('catalog transport failure preserves the existing choice', () async {
    native.fail = true;
    await container.read(setupActionProvider.notifier).initStatus();
    expect(container.read(currentProfileIdProvider), 1);
    expect(native.calls, [CoreMethod.sseCatalog]);
  });

  test(
    'manual measurement keeps scores during transport and after failure',
    () async {
      final store = SseHistory();
      await store.load(core, [1, 2]);
      final pending = store.run(core, [1, 2]);
      expect(store.running, isTrue);
      expect(SseHistory.latency(store.history['good']), 180);
      await pending;
      expect(store.running, isFalse);
      native.fail = true;
      await store.run(core, [1, 2], profileId: 2, name: 'winner');
      expect(store.error, contains('上次成绩保留'));
      expect(store.running, isFalse);
      expect(SseHistory.latency(store.history['good']), 180);
      expect(SseHistory.score(store.history['good']), 5);
      native.fail = false;
      native.response = {};
      await store.run(core, [1, 2]);
      expect(store.error, contains('no result'));
      store.dispose();
    },
  );

  test(
    'a full run follows the background tournament until it has scored',
    () async {
      final store = SseHistory()..pollInterval = Duration.zero;
      Map<String, dynamic> withTournament(bool running, int score) => {
        ...catalog(),
        'history': {
          ...catalog()['history'] as Map,
          'good': {'score': score, 'latest': done(180)},
        },
        'tournament': {
          'running': running,
          'startedAt': DateTime.now().millisecondsSinceEpoch,
          'limitMs': 60000,
          'podium': running ? [] : ['good'],
        },
      };
      native.queue.addAll([
        withTournament(true, 5),
        withTournament(true, 5),
        withTournament(false, 9),
      ]);
      await store.run(core, [1, 2]);
      expect(store.running, isFalse);
      expect(store.tournamentRunning, isFalse);
      expect(SseHistory.score(store.history['good']), 9);
      expect(native.calls, [
        CoreMethod.sseBatch,
        CoreMethod.sseCatalog,
        CoreMethod.sseCatalog,
      ]);
      store.dispose();
    },
  );
}
