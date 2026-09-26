import 'dart:async';

import 'package:fl_clash/core/controller.dart';
import 'package:flutter/foundation.dart';

class SseHistory extends ChangeNotifier {
  static final instance = SseHistory();
  static const samples = 3;
  List<Map<String, dynamic>> nodes = [];
  Map<String, dynamic> history = {};
  List<Map<String, dynamic>> issues = [];
  Map<String, dynamic> tournament = {};
  Map<String, dynamic> failover = {};
  bool running = false;
  String error = '';
  int elapsedMs = 0;
  Set<String> attemptedKeys = {};
  String? activeKey;
  Duration pollInterval = const Duration(seconds: 3);
  int _revision = 0;

  static Map<String, dynamic> object(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};

  static List<Map<String, dynamic>> objects(dynamic value) =>
      value is List ? value.map(object).toList() : [];

  static Map<String, dynamic>? success(dynamic record) {
    final value = object(object(record)['latest']);
    final latency = value['latencyMs'];
    return value['status'] == 'done' &&
            value['samples'] == samples &&
            latency is num &&
            latency.isFinite &&
            latency > 0
        ? value
        : null;
  }

  /// PING plus the colo's edge-to-origin median, falling back to the raw 401.
  static num? latency(dynamic record) {
    final value = success(record);
    final estimate = value?['estimateMs'];
    return estimate is num && estimate > 0
        ? estimate
        : value?['latencyMs'] as num?;
  }

  static double score(dynamic record) =>
      (object(record)['score'] as num?)?.toDouble() ?? 0;

  static String points(num value) => value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1);

  /// 403 exits stay unusable even with points from an earlier tournament.
  static bool unusable(dynamic record) => const [
    'blocked',
    'unsupported',
  ].contains(object(object(record)['latest'])['status']);

  bool get tournamentRunning => tournament['running'] == true;

  int _rank(Map<String, dynamic> a, Map<String, dynamic> b) {
    final x = object(history[a['key']]);
    final y = object(history[b['key']]);
    final points = score(y).compareTo(score(x));
    if (points != 0) return points;
    final awarded = ((y['lastAwardAt'] as num?) ?? 0).compareTo(
      (x['lastAwardAt'] as num?) ?? 0,
    );
    if (awarded != 0) return awarded;
    final speed = (latency(x) ?? double.infinity).compareTo(
      latency(y) ?? double.infinity,
    );
    if (speed != 0) return speed;
    final name = '${a['name']}'.compareTo('${b['name']}');
    return name != 0 ? name : '${a['key']}'.compareTo('${b['key']}');
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
      history[entry.key] = object(entry.value);
    }
    if (value.containsKey('tournament')) {
      tournament = object(value['tournament']);
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
    // Follow a tournament started elsewhere without blocking the caller.
    if (tournamentRunning) unawaited(_guard(() => _follow(core, profiles)));
  }

  Future<void> run(
    CoreController core,
    List<int> profiles, {
    String? name,
    int? profileId,
  }) async {
    if (running) return;
    _revision++;
    attemptedKeys = {};
    elapsedMs = 0;
    await _guard(() async {
      final result = await core.sseBatch(
        profiles,
        name: name,
        profileId: profileId,
      );
      if (result.isEmpty) throw StateError('SSE core returned no result');
      accept(result, replaceNodes: name == null);
      if (name == null && tournamentRunning) await _follow(core, profiles);
    });
  }

  Future<void> _guard(Future<void> Function() body) async {
    running = true;
    error = '';
    notifyListeners();
    try {
      await body();
    } catch (e) {
      error = '本轮未取得结果，上次成绩保留：$e';
    } finally {
      running = false;
      notifyListeners();
    }
  }

  Future<void> _follow(CoreController core, List<int> profiles) async {
    final startedAt = (tournament['startedAt'] as num?)?.toInt() ?? 0;
    final limitMs = (tournament['limitMs'] as num?)?.toInt() ?? 0;
    final deadline = DateTime.fromMillisecondsSinceEpoch(
      startedAt + limitMs,
    ).add(const Duration(minutes: 2));
    while (tournamentRunning) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('淘汰赛超时未返回结果');
      }
      await Future<void>.delayed(pollInterval);
      try {
        final value = await core.sseCatalog(profiles);
        if (value.isNotEmpty) accept(value, measurement: false);
      } catch (_) {
        continue;
      }
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
    matches.sort(_rank);
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

  Map<String, dynamic>? _entry(
    Map<String, dynamic> node,
    Set<int> available,
  ) {
    for (final alias in objects(node['aliases'])) {
      if (available.contains(alias['profileId'])) {
        return {...alias, 'key': node['key']};
      }
    }
    return null;
  }

  /// Scored nodes first, then the remaining reachable ones by latency.
  List<Map<String, dynamic>> ranking(Iterable<int> profileIds) {
    final available = profileIds.toSet();
    final ordered =
        nodes.where((node) {
          final record = history[node['key']];
          return !unusable(record) &&
              (score(record) > 0 || success(record) != null);
        }).toList()..sort(_rank);
    return ordered.map((node) => _entry(node, available)).nonNulls.toList();
  }

  Map<String, dynamic>? candidate(Iterable<int> profileIds) {
    final best = ranking(profileIds).firstOrNull;
    return best != null && score(history[best['key']]) > 0 ? best : null;
  }

  /// The node after [currentKey] in the ranking, wrapping to the top.
  Map<String, dynamic>? next(String? currentKey, Iterable<int> profileIds) {
    final ranked = ranking(profileIds);
    final index = ranked.indexWhere((entry) => entry['key'] == currentKey);
    if (index < 0) return ranked.firstOrNull;
    if (ranked.length < 2) return null;
    return ranked[(index + 1) % ranked.length];
  }

  /// The GLOBAL path wins over the last explicit choice, which may be stale.
  String? currentKey(int? profileId, Map<String, String> selectedMap) {
    final selected = selectedMap['GLOBAL'];
    for (final node in nodes) {
      for (final alias in objects(node['aliases'])) {
        if (alias['profileId'] == profileId &&
            object(alias['selections'])['GLOBAL'] == selected) {
          return node['key'] as String?;
        }
      }
    }
    return nodes.any((node) => node['key'] == activeKey) ? activeKey : null;
  }

  void recordFailover(Map<String, dynamic> event) {
    failover = event;
    notifyListeners();
  }
}
