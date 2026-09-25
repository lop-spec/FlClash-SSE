import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/sse_failover.dart';
import 'package:flutter_test/flutter_test.dart';

String apiError(Map<String, dynamic> error) => jsonEncode({
  'type': 'system',
  'subtype': 'api_error',
  'level': 'error',
  'error': error,
  'timestamp': '2026-09-26T01:00:00.000Z',
});

void main() {
  test('Claude transcripts count only connection-level failures', () {
    expect(
      parseClaudeLine(
        apiError({
          'message': 'Connection error.',
          'connection': {'code': 'ECONNRESET'},
        }),
      )?.detail,
      'ECONNRESET',
    );
    expect(
      parseClaudeLine(apiError({'message': 'Request timed out.'}))?.source,
      'Claude',
    );
    expect(
      parseClaudeLine(
        apiError({
          'message': 'Connection error.',
          'connection': {'code': 'ConnectionRefused'},
        }),
      ),
      isNull,
    );
    expect(
      parseClaudeLine(apiError({'message': '529 overloaded', 'status': 529})),
      isNull,
    );
    expect(parseClaudeLine('{"type":"assistant","message":"api_error"}'), isNull);
    expect(parseClaudeLine('not json "api_error"'), isNull);
  });

  test('the GPT bridge counts only failures on this proxy port', () {
    const line =
        '[2026/9/25 14:03:23] 连接层失败（ECONNRESET：Client network socket disconnected before secure TLS connection was established）egress=127.0.0.1:7890 host=chatgpt.com，300ms 后重试 1/2';
    expect(parseBridgeLine(line, 7890)?.detail, 'ECONNRESET');
    expect(parseBridgeLine(line, 17896), isNull);
    expect(
      parseBridgeLine(line.replaceFirst(':7890', ':57905'), 7890),
      isNull,
    );
    expect(
      parseBridgeLine('[2026/9/25 14:03:23] <- POST /v1/responses', 7890),
      isNull,
    );
  });

  test('log tails skip existing content, wait for whole lines and survive rotation', () {
    final dir = Directory.systemTemp.createTempSync('sse-tail-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/log.txt')..writeAsStringSync('old\n');
    final tail = SseLogTail(file.path);
    expect(tail.read(), isEmpty);
    file.writeAsStringSync('first\npart', mode: FileMode.append);
    expect(tail.read(), ['first']);
    file.writeAsStringSync('ial\n', mode: FileMode.append);
    expect(tail.read(), ['partial']);
    file.writeAsStringSync('new\n');
    expect(tail.read(), ['new']);
    expect(SseLogTail('${dir.path}/missing').read(), isEmpty);
  });

  test('failover fires once per cooldown and ignores the start-up minute', () async {
    final dir = Directory.systemTemp.createTempSync('sse-failover-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final project = Directory('${dir.path}/projects/p')..createSync(recursive: true);
    final existing = File('${project.path}/old.jsonl')
      ..writeAsStringSync(
        '${apiError({
          'message': 'Connection error.',
          'connection': {'code': 'ECONNRESET'},
        })}\n',
      );
    final bridge = File('${dir.path}/bridge.log')..writeAsStringSync('');
    var now = DateTime(2026, 9, 26, 9);
    final fired = <String>[];
    final quiet = <String>[];
    final monitor = SseFailover(
      claudeProjects: '${dir.path}/projects',
      bridgeLog: bridge.path,
      port: () => 7890,
      clock: () => now,
      onFailure: (failure) async => fired.add(failure.toString()),
      onSuppressed: (failure) => quiet.add(failure.toString()),
    );
    await monitor.poll();
    expect(fired, isEmpty, reason: 'history before start must not replay');
    final reset = apiError({
      'message': 'Connection error.',
      'connection': {'code': 'ECONNRESET'},
    });
    existing.writeAsStringSync('$reset\n', mode: FileMode.append);
    await monitor.poll();
    expect(fired, isEmpty);
    expect(quiet, ['Claude ECONNRESET']);
    now = now.add(const Duration(seconds: 61));
    File('${project.path}/new.jsonl').writeAsStringSync('$reset\n');
    await monitor.poll();
    expect(fired, ['Claude ECONNRESET']);
    bridge.writeAsStringSync(
      '[x] 连接层失败（ETIMEDOUT：timeout）egress=127.0.0.1:7890 host=chatgpt.com\n',
      mode: FileMode.append,
    );
    now = now.add(const Duration(seconds: 30));
    await monitor.poll();
    expect(fired.length, 1);
    now = now.add(const Duration(seconds: 31));
    bridge.writeAsStringSync(
      '[x] 连接层失败（ETIMEDOUT：timeout）egress=127.0.0.1:7890 host=chatgpt.com\n',
      mode: FileMode.append,
    );
    await monitor.poll();
    expect(fired, ['Claude ECONNRESET', 'ChatGPT ETIMEDOUT']);
    monitor.stop();
  });
}
