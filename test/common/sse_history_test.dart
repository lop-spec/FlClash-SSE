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
  test('failed, pending and zero scores never erase valid displayed toks', () {
    final store = SseHistory();
    store.accept({'history': {'node': {'lastSuccess': good(19.1), 'measuredAt': 123}}});
    for (final state in ['running', 'failed', 'timeout', 'unmeasured', 'endpoint', 'done']) {
      store.accept({'history': {'node': {'latest': {'status': state}, 'lastSuccess': good(0)}}});
      expect(SseHistory.success(store.history['node'])?['tokPerSec'], 19.1);
      expect(SseHistory.object(store.history['node'])['measuredAt'], 123);
    }
    store.accept({'history': {'node': {'lastSuccess': good(19.5), 'measuredAt': 456}}});
    expect(SseHistory.success(store.history['node'])?['tokPerSec'], 19.5);
    store.dispose();
  });

  test('startup candidate must still exist and preserve subscription membership', () {
    final store = SseHistory();
    store.accept({
      'nodes': [
        {'key': 'old', 'aliases': [{'profileId': 1, 'name': 'fast'}]},
        {'key': 'present', 'aliases': [{'profileId': 2, 'name': 'same-name'}, {'profileId': 3, 'name': 'renamed'}]},
      ],
      'history': {'old': {'lastSuccess': good(20)}, 'present': {'lastSuccess': good(19)}},
    });
    expect(store.candidate([3])?['name'], 'renamed');
    expect(store.candidate([3])?['profileId'], 3);
    expect(store.candidate([4]), isNull);
    expect(SseHistory.success(store.recordFor(2, 'same-name'))?['tokPerSec'], 19);
    store.accept({'nodes': [], 'history': {}});
    expect(store.candidate([1, 2, 3]), isNull);
    expect(SseHistory.success(store.history['old']), isNotNull);
    store.dispose();
  });

  test('invalid non-finite or incomplete measurements cannot select a node', () {
    for (final speed in [double.nan, double.infinity, -1.0, 0.0]) {
      expect(SseHistory.success({'lastSuccess': good(speed)}), isNull);
    }
    expect(SseHistory.success({'lastSuccess': {...good(19), 'tokens': 160}}), isNull);
  });
}
