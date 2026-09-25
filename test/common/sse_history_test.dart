import 'package:fl_clash/common/sse_history.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> done(num latency) => {
  'status': 'done',
  'samples': SseHistory.samples,
  'latencyMs': latency,
};

Map<String, dynamic> node(String key, List<int> profiles) => {
  'key': key,
  'aliases': [
    for (final id in profiles)
      {
        'profileId': id,
        'name': '$key@$id',
        'selections': {'GLOBAL': '$key@$id'},
      },
  ],
};

void main() {
  test('single-node retest keeps other subscriptions and retires changed connection aliases', () {
    final store = SseHistory();
    final a = {'profileId': 1, 'name': 'same'};
    final b = {'profileId': 2, 'name': 'other'};
    store.accept({
      'nodes': [
        {
          'key': 'shared',
          'aliases': [a, b],
        },
      ],
    });
    store.accept({
      'nodes': [
        {
          'key': 'shared',
          'aliases': [a],
        },
      ],
    }, replaceNodes: false);
    expect(store.entriesFor(1).single['key'], 'shared');
    expect(store.entriesFor(2).single['key'], 'shared');
    store.accept({
      'nodes': [
        {
          'key': 'changed',
          'aliases': [a],
        },
      ],
    }, replaceNodes: false);
    expect(store.entriesFor(1).single['key'], 'changed');
    expect(store.entriesFor(2).single['key'], 'shared');
    expect(store.attemptedKeys, {'changed'});
    store.dispose();
  });

  test('subscriptions sort by score, then latest latency; untested nodes last', () {
    final store = SseHistory();
    store.accept({
      'nodes': [
        for (final key in ['untested', 'fast', 'champion', 'runner', 'tie'])
          {
            'key': key,
            'aliases': [
              {'profileId': 1, 'name': key},
              {'profileId': 1, 'name': '$key copy'},
              {'profileId': 2, 'name': '$key alias'},
            ],
          },
      ],
      'history': {
        'champion': {'score': 8, 'latest': done(240)},
        'runner': {'score': 3, 'latest': done(130)},
        'tie': {'score': 3, 'latest': done(120)},
        'fast': {'score': 0, 'latest': done(90)},
      },
      'elapsedMs': 8512,
    });
    expect(store.entriesFor(1).map((n) => n['key']), [
      'champion',
      'tie',
      'runner',
      'fast',
      'untested',
    ]);
    expect(store.entriesFor(2, query: 'FAST').single['name'], 'fast alias');
    expect(store.entriesFor(1, query: 'copy').length, 5);
    expect(store.entriesFor(3), isEmpty);
    store.accept({'nodes': store.nodes, 'elapsedMs': 0}, measurement: false);
    expect(store.elapsedMs, 8512);
    expect(store.attemptedKeys.length, 5);
    store.dispose();
  });

  test('a fresh failure replaces the latency but never the score', () {
    final store = SseHistory();
    store.accept({
      'history': {
        'node': {'score': 7, 'latest': done(180), 'measuredAt': 123},
      },
    });
    expect(SseHistory.latency(store.history['node']), 180);
    store.accept({
      'history': {
        'node': {
          'score': 7,
          'latest': {'status': 'timeout'},
          'measuredAt': 456,
        },
      },
    });
    expect(SseHistory.latency(store.history['node']), isNull);
    expect(SseHistory.score(store.history['node']), 7);
    store.dispose();
  });

  test('startup candidate is the top score that still exists and is not blocked', () {
    final store = SseHistory();
    store.accept({
      'nodes': [
        node('removed', [404]),
        node('blocked', [1]),
        node('winner', [2, 3]),
        node('unscored', [2]),
      ],
      'history': {
        'removed': {'score': 30, 'latest': done(100)},
        'blocked': {
          'score': 20,
          'latest': {'status': 'blocked', 'error': 'Claude: HTTP 403'},
        },
        'winner': {'score': 4, 'latest': done(300)},
        'unscored': {'latest': done(90)},
      },
    });
    expect(store.candidate([1, 2, 3])?['key'], 'winner');
    expect(store.candidate([3])?['profileId'], 3);
    expect(store.candidate([4]), isNull);
    store.accept({
      'history': {
        'winner': {'score': 0, 'latest': done(300)},
      },
    });
    expect(store.candidate([1, 2, 3]), isNull);
    store.dispose();
  });

  test('failover walks the ranking in order and wraps to the top', () {
    final store = SseHistory();
    store.accept({
      'nodes': [
        node('first', [1]),
        node('second', [1]),
        node('third', [1]),
        node('down', [1]),
      ],
      'history': {
        'first': {'score': 9, 'lastAwardAt': 1, 'latest': done(200)},
        'second': {'score': 4, 'latest': done(150)},
        'third': {'latest': done(120)},
        'down': {
          'score': 12,
          'latest': {'status': 'blocked'},
        },
      },
    });
    expect(store.ranking([1]).map((e) => e['key']), [
      'first',
      'second',
      'third',
    ]);
    expect(store.next('first', [1])?['key'], 'second');
    expect(store.next('third', [1])?['key'], 'first');
    expect(store.next('down', [1])?['key'], 'first');
    expect(store.next(null, [1])?['key'], 'first');
    expect(store.next('first', [2]), isNull);
    store.dispose();
  });

  test('the current node follows the GLOBAL path before the last choice', () {
    final store = SseHistory();
    store.accept({
      'nodes': [
        node('a', [1]),
        node('b', [1]),
      ],
    });
    store.activeKey = 'b';
    expect(store.currentKey(1, {'GLOBAL': 'a@1'}), 'a');
    expect(store.currentKey(1, {'GLOBAL': 'gone'}), 'b');
    store.activeKey = 'missing';
    expect(store.currentKey(1, {}), isNull);
    store.dispose();
  });

  test('invalid or incomplete measurements have no latency', () {
    for (final latency in [double.nan, double.infinity, -1.0, 0.0]) {
      expect(SseHistory.latency({'latest': done(latency)}), isNull);
    }
    expect(
      SseHistory.latency({
        'latest': {...done(120), 'samples': 4},
      }),
      isNull,
    );
  });
}
