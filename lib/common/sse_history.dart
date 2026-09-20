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
  int _revision = 0;

  static Map<String, dynamic> object(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};

  static List<Map<String, dynamic>> objects(dynamic value) =>
      value is List ? value.map(object).toList() : [];

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

  void accept(
    Map<String, dynamic> value, {
    bool replaceNodes = true,
    bool measurement = true,
  }) {
    if (value['nodes'] is List) {
      final incoming = objects(value['nodes']);
      if (measurement) {
        attemptedKeys = incoming.map((n) => n['key'].toString()).toSet();
      }
      if (replaceNodes) {
        nodes = incoming;
      } else {
        String identity(Map<String, dynamic> alias) =>
            '${alias['profileId']}\u0000${alias['name']}';
        final updated = incoming
            .expand((n) => objects(n['aliases']))
            .map(identity)
            .toSet();
        final merged = <dynamic, Map<String, dynamic>>{};
        for (final node in nodes) {
          final aliases = objects(node['aliases'])
              .where((a) => !updated.contains(identity(a)))
              .toList();
          if (aliases.isNotEmpty)
            merged[node['key']] = {...node, 'aliases': aliases};
        }
        for (final node in incoming) {
          merged[node['key']] = {
            ...node,
            'aliases': [
              ...objects(merged[node['key']]?['aliases']),
              ...objects(node['aliases']),
            ],
          };
        }
        nodes = merged.values.toList();
      }
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
    if (measurement) elapsedMs = (value['elapsedMs'] as num?)?.toInt() ?? 0;
    notifyListeners();
  }

  Future<void> load(CoreController core, List<int> profiles) async {
    if (running) return;
    final revision = ++_revision;
    final value = await core.sseCatalog(profiles);
    // A slow catalog must not replace a newer measurement or subscription list.
    if (revision != _revision || running) return;
    accept(value, measurement: false);
  }

  Future<void> run(
    CoreController core,
    List<int> profiles, {
    String? name,
    int? profileId,
  }) async {
    if (running) return;
    _revision++;
    running = true;
    error = '';
    attemptedKeys = {};
    elapsedMs = 0;
    notifyListeners();
    try {
      final result = await core.sseBatch(
        profiles,
        name: name,
        profileId: profileId,
      );
      if (result.isEmpty) throw StateError('SSE core returned no result');
      accept(result, replaceNodes: name == null);
    } catch (e) {
      error = '本轮未取得有效结果，历史成绩保留：$e';
    } finally {
      running = false;
      notifyListeners();
    }
  }

  /// One connection per subscription; aliases across subscriptions remain visible.
  List<Map<String, dynamic>> entriesFor(int profileId, {String query = ''}) {
    final matches = <Map<String, dynamic>>[];
    for (final node in nodes) {
      for (final alias in objects(node['aliases'])) {
        if (alias['profileId'] != profileId) continue;
        if (!'${alias['name']}'.toLowerCase().contains(query.toLowerCase()))
          continue;
        matches.add({...node, ...alias});
        break;
      }
    }
    matches.sort((a, b) {
      final x = success(history[a['key']])?['tokPerSec'] as num?;
      final y = success(history[b['key']])?['tokPerSec'] as num?;
      final speed = (y ?? -1).compareTo(x ?? -1);
      if (speed != 0) return speed;
      final name = '${a['name']}'.compareTo('${b['name']}');
      return name != 0 ? name : '${a['key']}'.compareTo('${b['key']}');
    });
    return matches;
  }

  Map<String, dynamic>? recordFor(int? profileId, String name) {
    for (final node in nodes) {
      if (objects(node['aliases']).any(
        (alias) => alias['profileId'] == profileId && alias['name'] == name,
      )) {
        return object(history[node['key']]);
      }
    }
    return null;
  }

  Map<String, dynamic>? candidate(Iterable<int> profileIds) {
    final available = profileIds.toSet();
    final sorted = [...nodes]
      ..sort((a, b) {
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
