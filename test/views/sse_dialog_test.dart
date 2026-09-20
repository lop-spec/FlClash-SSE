import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fl_clash/common/sse_history.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/state.dart';
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
  final reply = Completer<Map<String, dynamic>>();
  int calls = 0;
  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async {
    expect(method, CoreMethod.sseBatch);
    calls++;
    return (await reply.future) as T;
  }
}

Map<String, dynamic> fixture() => {
  'nodes': [
    {
      'key': 'one',
      'name': '香港 · 测试节点',
      'aliases': [
        {'profileId': 1, 'name': '香港 · 测试节点'},
      ],
    },
  ],
  'history': {
    'one': {
      'measuredAt': 1790000000000,
      'lastSuccess': {
        'status': 'done',
        'tokens': 161,
        'tokPerSec': 19.0,
        'flowPass': true,
        'firstMs': 281,
        'maxGapMs': 12,
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
    final font = File('${Platform.environment['WINDIR']}/Fonts/msyh.ttc');
    if (await font.exists()) {
      final loader = FontLoader('SseAcceptance')
        ..addFont(font.readAsBytes().then(ByteData.sublistView));
      await loader.load();
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
    store.accept(fixture());
    native = _PendingCore();
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(
          () => TestProfiles([Profile.normal(label: '测试订阅').copyWith(id: 1)]),
        ),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(native)),
      ],
    );
    globalState.container = container;
  });
  tearDown(() => container.dispose());

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: imageKey,
          child: TestApp(
            child: Theme(
              data: ThemeData(fontFamily: capture ? 'SseAcceptance' : null),
              child: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showSseTest(context),
                    child: const Text('打开测速'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开测速'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('old scores remain visible while measuring and after failure', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('19.0 tok/s'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(native.calls, 1);
    native.reply.complete({
      ...fixture(),
      'history': {
        'one': {
          'latest': {'status': 'timeout', 'error': '本轮测试超时'},
        },
      },
      'issues': [
        {'profileId': 1, 'error': '一个未更新的测试订阅未覆盖'},
      ],
    });
    await tester.pumpAndSettle();
    expect(find.text('19.0 tok/s'), findsOneWidget);
    expect(find.textContaining('完整成功 0'), findsOneWidget);
    expect(find.textContaining('未覆盖'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (capture) {
      await tester.runAsync(() async {
        final boundary =
            imageKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory('test-output').createSync(recursive: true);
        File('test-output/sse-history-retained.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.byType(SseTestDialog), findsNothing);
  });

  testWidgets(
    'empty catalog and transport failure give a recoverable import message',
    (tester) async {
      SseHistory.instance.accept({'nodes': [], 'history': {}});
      await open(tester);
      expect(find.textContaining('正在收集'), findsOneWidget);
      native.reply.completeError(StateError('test connection refused'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不会读取原版'), findsOneWidget);
      expect(find.textContaining('历史成绩保留'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
    },
  );
}
