import 'dart:async';

import 'package:fl_clash/common/sse_history.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

Future<void> showSseTest(BuildContext context, {String? name}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => SseTestDialog(name: name),
  );
}

class SseTestDialog extends ConsumerStatefulWidget {
  const SseTestDialog({super.key, this.name});
  final String? name;

  @override
  ConsumerState<SseTestDialog> createState() => _SseTestDialogState();
}

class _SseTestDialogState extends ConsumerState<SseTestDialog> {
  final store = SseHistory.instance;
  final clock = Stopwatch();
  Timer? timer;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted && store.running) setState(() {});
    });
    Future.microtask(run);
  }

  Future<void> run() async {
    if (!mounted || store.running) return;
    clock..reset()..start();
    await store.run(
      ref.read(coreHandlerProvider),
      ref.read(profilesProvider).map((p) => p.id).toList(),
      name: widget.name,
      profileId: ref.read(currentProfileIdProvider),
    );
    clock.stop();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  String number(dynamic value) => value is num ? value.toStringAsFixed(1) : '—';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final nodes = [...store.nodes]..sort((a, b) {
          final x = SseHistory.success(store.history[a['key']]);
          final y = SseHistory.success(store.history[b['key']]);
          return ((y?['tokPerSec'] as num?) ?? 0).compareTo((x?['tokPerSec'] as num?) ?? 0);
        });
        final labels = {for (final p in ref.watch(profilesProvider)) p.id: p.label};
        final successful = nodes.where((n) => store.attemptedKeys.contains(n['key']) && SseHistory.object(SseHistory.object(store.history[n['key']])['latest'])['status'] == 'done').length;
        return PopScope(
          canPop: !store.running,
          child: Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760, maxHeight: 640),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('SSE 链路测速', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    const Text('8 秒固定模拟流 · 512 路有界并发 · 整批 20 秒截止\n模拟 tok/s = 161 个完整事件 ÷ 请求到结束耗时，不代表模型速度。'),
                    const SizedBox(height: 12),
                    if (store.running) ...[
                      LinearProgressIndicator(value: (clock.elapsedMilliseconds / 20000).clamp(0, 1)),
                      const SizedBox(height: 8),
                      Text('本轮测速中 ${(clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} / 20 秒 · 历史有效成绩保持显示'),
                    ] else
                      Text('${nodes.length} 个去重节点 · 本轮 ${store.attemptedKeys.length} 个，完整成功 $successful · ${(store.elapsedMs / 1000).toStringAsFixed(2)} 秒'),
                    if (store.error.isNotEmpty)
                      Padding(padding: const EdgeInsets.only(top: 8), child: Text(store.error, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                    if (store.issues.isNotEmpty)
                      Text('${store.issues.length} 项未覆盖（需处理）：${store.issues.map((i) => '${labels[i['profileId']] ?? i['profileId']}: ${i['error']}').join('；')}'),
                    const SizedBox(height: 12),
                    const Divider(),
                    Expanded(
                      child: nodes.isEmpty
                          ? Center(child: Text(store.running ? '正在收集所有订阅并并发测速…' : '请先在本隔离版导入并更新订阅。不会读取原版的私有配置。'))
                          : ListView.builder(
                              itemCount: nodes.length,
                              itemBuilder: (context, index) {
                                final node = nodes[index];
                                final record = SseHistory.object(store.history[node['key']]);
                                final good = SseHistory.success(record);
                                final latest = SseHistory.object(record['latest']);
                                final names = SseHistory.objects(node['aliases']).map((a) => labels[a['profileId']] ?? '${a['profileId']}').toSet().join(' / ');
                                final latestText = store.running ? '测速中' : '${latest['status'] ?? '未测'}${latest['error'] == null ? '' : ': ${latest['error']}'}';
                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text('${node['name']}'),
                                  subtitle: Text('$names\n$latestText · 首事件 ${number(good?['firstMs'])} ms · 最大额外停顿 ${number(good?['maxGapMs'])} ms'),
                                  isThreeLine: true,
                                  trailing: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(good == null ? '—' : '${number(good['tokPerSec'])} tok/s', style: Theme.of(context).textTheme.titleMedium),
                                      Text(good == null ? '尚无有效成绩' : '模拟 · ${DateTime.fromMillisecondsSinceEpoch((record['measuredAt'] as num).toInt()).toLocal().toString().substring(5, 16)}', style: Theme.of(context).textTheme.labelSmall),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                    const Divider(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(onPressed: store.running ? null : run, child: const Text('重新测速')),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: store.running ? null : () => Navigator.of(context).pop(), child: const Text('完成')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
