import 'package:fl_clash/core/controller.dart';
import 'package:flutter/foundation.dart';

class SseHistory extends ChangeNotifier {
  static final instance = SseHistory();
  List<Map<String, dynamic>> nodes = [];
  Map<String, dynamic> history = {};
  List<Map<String, dynamic>> issues = [];
  bool running = false;
  String error = '';
  int elapsedMs = 0;
  Set<String> attemptedKeys = {};

  static Map<String, dynamic> object(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};

  static List<Map<String, dynamic>> objects(dynamic value) => value is List
      ? value.map(object).toList()
      : [];

  static Map<String, dynamic>? success(dynamic record) {
    final value = object(object(record)['lastSuccess']);
    final speed = value['tokPerSec'];
    return value['status'] == 'done' &&
            value['tokens'] == 161 &&
            speed is num &&
            speed.isFinite &&
            speed > 0 &&
            speed < 100000
        ? value
        : null;
  }

  void accept(Map<String, dynamic> value, {bool replaceNodes = true}) {
    if (value['nodes'] is List) {
      final incoming = objects(value['nodes']);
      attemptedKeys = incoming.map((n) => n['key'].toString()).toSet();
      nodes = replaceNodes ? incoming : {
        for (final n in [...nodes, ...incoming]) n['key']: n,
      }.values.toList();
    }
    for (final entry in object(value['history']).entries) {
      final next = object(entry.value);
      final previous = object(history[entry.key]);
      if (success(next) == null && success(previous) != null) {
        next['lastSuccess'] = previous['lastSuccess'];
        next['measuredAt'] = previous['measuredAt'];
      }
      history[entry.key] = next;
    }
    issues = objects(value['issues']);
    error = value['error']?.toString() ?? '';
    elapsedMs = (value['elapsedMs'] as num?)?.toInt() ?? 0;
    notifyListeners();
  }

  Future<void> load(CoreController core, List<int> profiles) async {
    accept(await core.sseCatalog(profiles));
  }

  Future<void> run(CoreController core, List<int> profiles, {
    String? name,
    int? profileId,
  }) async {
    if (running) return;
    running = true;
    error = '';
    notifyListeners();
    try {
      final result = await core.sseBatch(profiles, name: name, profileId: profileId);
      if (result.isEmpty) throw StateError('SSE core returned no result');
      accept(result, replaceNodes: name == null);
    } catch (e) {
      error = '本轮未取得有效结果，历史成绩保留：$e';
    } finally {
      running = false;
      notifyListeners();
    }
  }

  Map<String, dynamic>? recordFor(int? profileId, String name) {
    for (final node in nodes) {
      if (objects(node['aliases']).any((alias) =>
          alias['profileId'] == profileId && alias['name'] == name)) {
        return object(history[node['key']]);
      }
    }
    return null;
  }

  Map<String, dynamic>? candidate(Iterable<int> profileIds) {
    final available = profileIds.toSet();
    final sorted = [...nodes]..sort((a, b) {
      final x = success(history[a['key']]);
      final y = success(history[b['key']]);
      return ((y?['tokPerSec'] as num?) ?? 0).compareTo(
        (x?['tokPerSec'] as num?) ?? 0,
      );
    });
    for (final node in sorted) {
      final result = success(history[node['key']]);
      if (result == null || result['flowPass'] != true) continue;
      for (final alias in objects(node['aliases'])) {
        if (available.contains(alias['profileId'])) {
          return {...alias, 'key': node['key']};
        }
      }
    }
    return null;
  }
}
