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
  bool fail = false;

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
    return response as T;
  }
}

class _Setup extends SetupAction {
  @override
  Future<bool> setRunning(bool running, {bool initialize = false}) async =>
      true;
  @override
  Future<bool> applyProfile({bool silence = false, bool force = false}) async =>
      true;
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
    for (final (key, speed, pass) in [
      ('old', 99, true),
      ('buffered', 40, false),
      ('good', 19, true),
    ])
      key: {
        'lastSuccess': {
          'status': 'done',
          'tokens': 161,
          'tokPerSec': speed,
          'flowPass': pass,
        },
      },
  },
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

  test('startup selects a surviving flow-passing history candidate without measuring', () async {
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
      expect(SseHistory.success(store.history['good'])?['tokPerSec'], 19);
      await pending;
      expect(store.running, isFalse);
      native.fail = true;
      await store.run(core, [1, 2], profileId: 2, name: 'winner');
      expect(store.error, contains('历史成绩保留'));
      expect(store.running, isFalse);
      expect(SseHistory.success(store.history['good'])?['tokPerSec'], 19);
      native.fail = false;
      native.response = {};
      await store.run(core, [1, 2]);
      expect(store.error, contains('no result'));
      store.dispose();
    },
  );
}
