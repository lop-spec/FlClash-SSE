import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A connection-level failure a real client hit through this proxy.
class SseFailure {
  const SseFailure(this.source, this.detail);

  final String source;
  final String detail;

  @override
  String toString() => '$source $detail';
}

const _networkCodes = {
  'ECONNRESET',
  'ETIMEDOUT',
  'ECONNABORTED',
  'EPIPE',
  'ENETUNREACH',
  'EHOSTUNREACH',
  'UND_ERR_SOCKET',
  'UND_ERR_CONNECT_TIMEOUT',
  'UND_ERR_HEADERS_TIMEOUT',
  'UND_ERR_BODY_TIMEOUT',
};
final _timeout = RegExp(r'timed? ?out|timeout', caseSensitive: false);

/// Claude Code logs failed requests as `api_error`; ConnectionRefused means
/// the local proxy port was closed, which a node switch cannot fix.
SseFailure? parseClaudeLine(String line) {
  if (!line.contains('"api_error"')) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded['subtype'] != 'api_error') return null;
  final error = decoded['error'];
  if (error is! Map || error['status'] != null) return null;
  final connection = error['connection'];
  final code = connection is Map ? '${connection['code'] ?? ''}' : '';
  final message = '${error['message'] ?? ''}';
  if (_networkCodes.contains(code)) return SseFailure('Claude', code);
  if (code.isEmpty && _timeout.hasMatch(message)) {
    return SseFailure('Claude', message);
  }
  return null;
}

/// Only GPT-bridge failures on this proxy's egress port implicate the node.
SseFailure? parseBridgeLine(String line, int port) {
  if (!line.contains('连接层失败') || !line.contains('egress=127.0.0.1:$port ')) {
    return null;
  }
  final start = line.indexOf('（');
  final end = line.indexOf('：', start + 1);
  final code = start >= 0 && end > start ? line.substring(start + 1, end) : '';
  return SseFailure('ChatGPT', code.isEmpty ? 'connection failure' : code);
}

/// Complete lines appended since the last read; truncation restarts at zero.
class SseLogTail {
  SseLogTail(this.path, {bool fromStart = false}) {
    if (!fromStart) {
      final file = File(path);
      _offset = file.existsSync() ? file.lengthSync() : 0;
    }
  }

  final String path;
  int _offset = 0;

  List<String> read() {
    final file = File(path);
    if (!file.existsSync()) return const [];
    final length = file.lengthSync();
    if (length < _offset) _offset = 0;
    if (length == _offset) return const [];
    final handle = file.openSync();
    try {
      handle.setPositionSync(_offset);
      final bytes = handle.readSync(length - _offset);
      final complete = bytes.lastIndexOf(10);
      if (complete < 0) return const [];
      _offset += complete + 1;
      return utf8
          .decode(bytes.sublist(0, complete), allowMalformed: true)
          .split('\n')
          .map((line) => line.trimRight())
          .where((line) => line.isNotEmpty)
          .toList();
    } finally {
      handle.closeSync();
    }
  }
}

/// The cooldown also swallows the resets a switch itself causes and the
/// first minute after start-up.
class SseFailover {
  SseFailover({
    required this.claudeProjects,
    required this.bridgeLog,
    required this.port,
    required this.onFailure,
    this.onSuppressed,
    this.cooldown = const Duration(seconds: 60),
    this.interval = const Duration(seconds: 3),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _quietUntil = _clock().add(cooldown);
    for (final path in _transcripts()) {
      _claude[path] = SseLogTail(path);
    }
    _bridge = SseLogTail(bridgeLog);
  }

  final String claudeProjects;
  final String bridgeLog;
  final int Function() port;
  final Future<void> Function(SseFailure failure) onFailure;
  final void Function(SseFailure failure)? onSuppressed;
  final Duration cooldown;
  final Duration interval;
  final DateTime Function() _clock;
  final Map<String, SseLogTail> _claude = {};
  late SseLogTail _bridge;
  late DateTime _quietUntil;
  Timer? _timer;
  bool _polling = false;

  Iterable<String> _transcripts() sync* {
    final root = Directory(claudeProjects);
    if (!root.existsSync()) return;
    try {
      for (final project in root.listSync(followLinks: false)) {
        if (project is! Directory) continue;
        for (final file in project.listSync(followLinks: false)) {
          if (file is File && file.path.endsWith('.jsonl')) yield file.path;
        }
      }
    } on FileSystemException {
      return;
    }
  }

  void start() {
    _timer ??= Timer.periodic(interval, (_) => poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final failures = <SseFailure>[];
      for (final path in _transcripts()) {
        final tail = _claude.putIfAbsent(
          path,
          () => SseLogTail(path, fromStart: true),
        );
        failures.addAll(tail.read().map(parseClaudeLine).nonNulls);
      }
      final bridgePort = port();
      failures.addAll(
        _bridge.read().map((line) => parseBridgeLine(line, bridgePort)).nonNulls,
      );
      if (failures.isEmpty) return;
      final now = _clock();
      if (now.isBefore(_quietUntil)) {
        onSuppressed?.call(failures.first);
        return;
      }
      _quietUntil = now.add(cooldown);
      await onFailure(failures.first);
    } finally {
      _polling = false;
    }
  }
}
