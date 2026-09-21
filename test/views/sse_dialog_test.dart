import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/common/sse_history.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/proxies/proxies.dart';
import 'package:fl_clash/views/proxies/sse.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

class _PendingCore extends Mock implements CoreHandlerInterface {
  late Completer<Map<String, dynamic>> reply;
  int calls = 0;
  Object? arguments;
  bool catalogFails = false;
  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async {
    if (method == CoreMethod.sseCatalog) {
      if (catalogFails) throw StateError('catalog unavailable');
      return fixture() as T;
    }
    expect(method, CoreMethod.sseBatch);
    this.arguments = arguments;
    calls++;
    return (await reply.future) as T;
  }
}

Map<String, dynamic> fixture() => {
  'nodes': [
    for (final (key, name, ids) in [
      ('slow', '香港 · HK 01', [1, 2]),
      ('fast', '新加坡 · SG 02', [1]),
      ('new', '日本 · JP 03', [1]),
    ])
      {
        'key': key,
        'name': name,
        'aliases': [
          for (final id in ids)
            {
              'profileId': id,
              'name': name,
              'selections': {'GLOBAL': name, '节点选择': name},
            },
        ],
      },
  ],
  'history': {
    for (final (key, rate) in [('slow', 17.3), ('fast', 19.8)])
      key: {
        'measuredAt': 1790000000000,
        'lastSuccess': {
          'status': 'done',
          'tokens': 161,
          'tokPerSec': rate,
          'flowPass': true,
        },
        'latest': {'status': 'done'},
      },
  },
  'elapsedMs': 8473,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final capture =
      Platform.isWindows && Platform.environment['SSE_CAPTURE_UI'] == 'true';
  setUpAll(() async {
    if (!capture) return;
    // Widget tests otherwise substitute Ahem squares for bundled icon fonts.
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final family in manifest) {
      final loader = FontLoader(family['family'] as String);
      for (final font in family['fonts'] as List) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
    final font = File('${Platform.environment['WINDIR']}/Fonts/msyh.ttc');
    if (await font.exists()) {
      await (FontLoader(
        'SseAcceptance',
      )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  late ProviderContainer container;
  late _PendingCore native;
  final imageKey = GlobalKey();
  setUp(() {
    final store = SseHistory.instance;
    store.running = false;
    store.nodes = [];
    store.history = {};
    store.attemptedKeys = {};
    store.accept(fixture(), measurement: false);
    native = _PendingCore();
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(
          () => TestProfiles([
            Profile.normal(label: '主力订阅')
                .copyWith(id: 1, selectedMap: {'GLOBAL': '新加坡 · SG 02'}),
            Profile.normal(label: '备用订阅').copyWith(id: 2),
          ]),
        ),
        currentProfileIdProvider.overrideWithBuild((_, _) => 1),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(native)),
        groupsProvider.overrideWithValue([
          const Group(
            name: '国外媒体',
            type: GroupType.Selector,
            hidden: false,
            all: [],
          ),
        ]),
      ],
    );
    globalState.container = container;
  });
  tearDown(() => container.dispose());

  Future<void> captureUi(WidgetTester tester, String name) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final image =
          await (imageKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('test-output').createSync(recursive: true);
      File('test-output/$name.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> open(WidgetTester tester, {bool expand = true}) async {
    native.reply = Completer<Map<String, dynamic>>();
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    container
        .read(viewSizeProvider.notifier)
        .update((_) => const Size(1100, 850));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: imageKey,
          child: TestApp(
            child: Theme(
              data: ThemeData(
                colorSchemeSeed: const Color(0xff496b39),
                fontFamily: capture ? 'SseAcceptance' : null,
              ),
              child: const ProxiesView(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (expand) {
      for (final id in [1, 2]) {
        await tester.tap(find.byKey(ValueKey('sse-group-$id')));
        await tester.pumpAndSettle();
      }
    }
  }

  testWidgets(
    'all groups start collapsed; current subscription and node stay visible',
    (tester) async {
      await open(tester, expand: false);
      expect(find.byKey(const ValueKey('sse-node-1-fast')), findsNothing);
      expect(find.byKey(const ValueKey('sse-node-2-slow')), findsNothing);
      expect(find.text('主力订阅 / 新加坡 · SG 02'), findsOneWidget);
      await captureUi(tester, 'sse-collapsed');
      await tester.tap(find.byKey(const ValueKey('sse-group-1')));
      await tester.pumpAndSettle();
      final node = find.byKey(const ValueKey('sse-node-1-fast'));
      expect(node, findsOneWidget);
      expect(tester.getSize(node).height, 36);
      final icons = tester.widgetList<Icon>(
        find.descendant(of: node, matching: find.byType(Icon)),
      );
      expect(icons.every((icon) => icon.size! <= 15), isTrue);
      expect(find.byKey(const ValueKey('sse-node-2-slow')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('sse-group-1')));
      await tester.pumpAndSettle();
      expect(node, findsNothing);
      expect(find.text('主力订阅 / 新加坡 · SG 02'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search reveals matches temporarily and clearing restores folds',
    (tester) async {
      await open(tester, expand: false);
      container.read(queryProvider(QueryTag.proxies).notifier).value = 'HK';
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sse-node-2-slow')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sse-group-2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sse-node-2-slow')), findsNothing);
      container.read(queryProvider(QueryTag.proxies).notifier).value = '';
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sse-node-1-slow')), findsNothing);
      expect(find.byKey(const ValueKey('sse-node-2-slow')), findsNothing);
      expect(find.text('主力订阅 / 新加坡 · SG 02'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact layout supports narrow windows and large text', (
    tester,
  ) async {
    await open(tester);
    tester.view.physicalSize = const Size(360, 800);
    container
        .read(viewSizeProvider.notifier)
        .update((_) => const Size(360, 800));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(find.text('主力订阅 / 新加坡 · SG 02'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await captureUi(tester, 'sse-narrow');
  });

  testWidgets(
    'all subscriptions replace rule groups and sort descending by tok/s',
    (tester) async {
      // Persisted upstream list/name preferences must not restore the old rule UI.
      container
          .read(proxiesStyleSettingProvider.notifier)
          .update((s) => s.copyWith(type: ProxiesType.list));
      await open(tester);
      expect(find.text('主力订阅'), findsOneWidget);
      expect(find.text('备用订阅'), findsOneWidget);
      expect(find.text('国外媒体'), findsNothing);
      expect(find.text('节点选择'), findsNothing);
      expect(find.byType(TabBar), findsNothing);
      final a = tester.getTopLeft(
        find.byKey(const ValueKey('sse-node-1-fast')),
      );
      final b = tester.getTopLeft(
        find.byKey(const ValueKey('sse-node-1-slow')),
      );
      final c = tester.getTopLeft(find.byKey(const ValueKey('sse-node-1-new')));
      expect(a.dy < b.dy || (a.dy == b.dy && a.dx < b.dx), isTrue);
      expect(b.dy < c.dy || (b.dy == c.dy && b.dx < c.dx), isTrue);
      expect(find.byKey(const ValueKey('sse-node-2-slow')), findsOneWidget);
      expect(native.calls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'background probe has no dialog, blocks duplicates and preserves failed scores',
    (tester) async {
      await open(tester);
      // Flutter's root MaterialPageRoute already owns a barrier BELOW its page.
      // A background probe must not add another route or barrier above it.
      final barriers = find.byType(ModalBarrier).evaluate().length;
      await tester.tap(find.text('全部测速'));
      await tester.pump();
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(ModalBarrier), findsNWidgets(barriers));
      expect(
        Navigator.of(tester.element(find.byType(ProxiesView))).canPop(),
        isFalse,
      );
      expect(find.text('19.8 tok/s'), findsOneWidget);
      expect(SseHistory.instance.running, isTrue);
      final ctx = tester.element(find.byType(ProxiesView));
      unawaited(runSseTest(ctx));
      expect(native.calls, 1);
      native.reply.complete({
        ...fixture(),
        'history': {
          'fast': {
            'latest': {'status': 'timeout', 'error': '本轮测试超时'},
          },
          'slow': {
            'latest': {'status': 'failed'},
          },
          'new': {
            'latest': {'status': 'unmeasured'},
          },
        },
        'issues': [
          {'profileId': 2, 'error': '缓存未更新'},
        ],
      });
      await tester.pumpAndSettle();
      expect(find.text('19.8 tok/s'), findsOneWidget);
      expect(find.textContaining('本轮成功 0/3'), findsOneWidget);
      expect(find.textContaining('项未覆盖'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await captureUi(tester, 'sse-subscriptions');
    },
  );

  testWidgets(
    'probe continues after leaving the page and completed scores re-sort',
    (tester) async {
      await open(tester);
      await tester.tap(find.text('全部测速'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      expect(SseHistory.instance.running, isTrue);
      native.reply.complete({
        ...fixture(),
        'history': {
          'slow': {
            'lastSuccess': {
              'status': 'done',
              'tokens': 161,
              'tokPerSec': 20.0,
              'flowPass': true,
            },
          },
        },
      });
      await tester.pump();
      expect(SseHistory.instance.running, isFalse);
      expect(SseHistory.instance.entriesFor(1).first['key'], 'slow');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selection remains usable during a probe and changes subscription paths',
    (tester) async {
      await open(tester);
      await tester.tap(find.text('全部测速'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('sse-node-2-slow')));
      await tester.pump();
      expect(container.read(currentProfileIdProvider), 2);
      expect(container.read(profilesProvider).last.selectedMap, {
        'GLOBAL': '香港 · HK 01',
        '节点选择': '香港 · HK 01',
      });
      expect(SseHistory.instance.running, isTrue);
      expect(native.calls, 1);
      expect(find.text('备用订阅 / 香港 · HK 01'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sse-group-2')));
      await tester.pump();
      expect(find.byKey(const ValueKey('sse-node-2-slow')), findsNothing);
      expect(find.text('备用订阅 / 香港 · HK 01'), findsOneWidget);
      native.reply.complete(fixture());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('single-node retest uses that subscription, not the active one', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('sse-node-2-slow')),
        matching: find.byTooltip('重测此节点'),
      ),
    );
    await tester.pump();
    expect(native.arguments, containsPair('profileId', 2));
    expect(native.arguments, containsPair('name', '香港 · HK 01'));
    expect(container.read(currentProfileIdProvider), 1);
    native.reply.completeError(StateError('test connection refused'));
    await tester.pumpAndSettle();
    expect(find.textContaining('历史成绩保留'), findsOneWidget);
    expect(find.text('19.8 tok/s'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'search filters both subscriptions and nodes, catalog errors stay inline',
    (tester) async {
      await open(tester);
      container.read(queryProvider(QueryTag.proxies).notifier).value = '备用';
      await tester.pumpAndSettle();
      expect(find.text('备用订阅'), findsOneWidget);
      expect(find.text('主力订阅'), findsNothing);
      container.read(queryProvider(QueryTag.proxies).notifier).value = 'JP 03';
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sse-node-1-new')), findsOneWidget);
      expect(find.byKey(const ValueKey('sse-node-1-fast')), findsNothing);
      native.catalogFails = true;
      await tester.tap(find.byTooltip('刷新订阅节点'));
      await tester.pumpAndSettle();
      expect(find.textContaining('节点目录读取失败'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
