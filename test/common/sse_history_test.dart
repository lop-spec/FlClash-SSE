import 'package:fl_clash/common/sse_history.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> good(double speed) => {
  'status': 'done',
  'tokens': 161,
  'tokPerSec': speed,
  'elapsedMs': 8400,
  'flowPass': true,
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
  test('subscription memberships are deduplicated, searched and sorted by valid history', () {
    final store = SseHistory();
    store.accept({
      'nodes': [
        for (final key in ['unmeasured', 'slow', 'fast', 'tie'])
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
        'fast': {'lastSuccess': good(19.8)},
        'slow': {'lastSuccess': good(17.0)},
        'tie': {'lastSuccess': good(17.0)},
        'unmeasured': {'lastSuccess': good(0)},
      },
      'elapsedMs': 8512,
    });
    expect(store.entriesFor(1).map((n) => n['key']), [
      'fast',
      'slow',
      'tie',
      'unmeasured',
    ]);
    expect(store.entriesFor(2, query: 'FAST').single['name'], 'fast alias');
    expect(store.entriesFor(1, query: 'copy').length, 4);
    expect(store.entriesFor(3), isEmpty);
    store.accept({'nodes': store.nodes, 'elapsedMs': 0}, measurement: false);
    expect(store.elapsedMs, 8512);
    expect(store.attemptedKeys.length, 4);
    store.dispose();
  });

  test('failed, pending and zero scores never erase valid displayed toks', () {
    final store = SseHistory();
    store.accept({
      'history': {
        'node': {'lastSuccess': good(19.1), 'measuredAt': 123},
      },
    });
    for (final state in [
      'running',
      'failed',
      'timeout',
      'unmeasured',
      'endpoint',
      'done',
    ]) {
      store.accept({
        'history': {
          'node': {
            'latest': {'status': state},
            'lastSuccess': good(0),
          },
        },
      });
      expect(SseHistory.success(store.history['node'])?['tokPerSec'], 19.1);
      expect(SseHistory.object(store.history['node'])['measuredAt'], 123);
    }
    store.accept({
      'history': {
        'node': {'lastSuccess': good(19.5), 'measuredAt': 456},
      },
    });
    expect(SseHistory.success(store.history['node'])?['tokPerSec'], 19.5);
    store.dispose();
  });

  test(
    'startup candidate must still exist and preserve subscription membership',
    () {
      final store = SseHistory();
      store.accept({
        'nodes': [
          {
            'key': 'old',
            'aliases': [
              {'profileId': 1, 'name': 'fast'},
            ],
          },
          {
            'key': 'present',
            'aliases': [
              {'profileId': 2, 'name': 'same-name'},
              {'profileId': 3, 'name': 'renamed'},
            ],
          },
        ],
        'history': {
          'old': {'lastSuccess': good(20)},
          'present': {'lastSuccess': good(19)},
        },
      });
      expect(store.candidate([3])?['name'], 'renamed');
      expect(store.candidate([3])?['profileId'], 3);
      expect(store.candidate([4]), isNull);
      expect(
        SseHistory.success(store.recordFor(2, 'same-name'))?['tokPerSec'],
        19,
      );
      store.accept({'nodes': [], 'history': {}});
      expect(store.candidate([1, 2, 3]), isNull);
      expect(SseHistory.success(store.history['old']), isNotNull);
      store.dispose();
    },
  );

  test(
    'invalid non-finite or incomplete measurements cannot select a node',
    () {
      for (final speed in [double.nan, double.infinity, -1.0, 0.0]) {
        expect(SseHistory.success({'lastSuccess': good(speed)}), isNull);
      }
      expect(
        SseHistory.success({
          'lastSuccess': {...good(19), 'tokens': 160},
        }),
        isNull,
      );
    },
  );
}
