import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/sse_history.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'providers.dart';
import 'sse.dart';

/// A single catalog of every subscription, independent of the active profile
/// and of the upstream rule-group/tab/list preferences.
class ProxiesView extends ConsumerStatefulWidget {
  const ProxiesView({super.key});

  @override
  ConsumerState<ProxiesView> createState() => _ProxiesViewState();
}

class _ProxiesViewState extends ConsumerState<ProxiesView> {
  final store = SseHistory.instance;
  bool _loading = false;
  bool _refreshPending = false;
  int _loadRevision = 0;
  String _error = '';
  String? _selecting;
  final _expanded = <int>{};
  final _searchCollapsed = <int>{};

  bool _isExpanded(int id, String query) =>
      query.isEmpty ? _expanded.contains(id) : !_searchCollapsed.contains(id);

  void _toggle(int id, String query) => setState(() {
    final set = query.isEmpty ? _expanded : _searchCollapsed;
    if (!set.remove(id)) set.add(id);
  });

  @override
  void initState() {
    super.initState();
    store.addListener(_storeChanged);
    ref.listenManual(
      profilesProvider.select(
        (profiles) =>
            profiles.map((p) => '${p.id}:${p.lastUpdateDate}').join('|'),
      ),
      (_, _) => unawaited(_refresh()),
    );
    ref.listenManual(queryProvider(QueryTag.proxies), (_, _) {
      setState(_searchCollapsed.clear);
    });
    Future.microtask(_refresh);
  }

  void _storeChanged() {
    if (!mounted) return;
    setState(() {});
    if (_refreshPending && !store.running) {
      _refreshPending = false;
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    if (store.running) {
      _refreshPending = true;
      return;
    }
    final revision = ++_loadRevision;
    final profiles = ref.read(profilesProvider);
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      if (profiles.isEmpty) {
        store.accept({'nodes': [], 'issues': []}, measurement: false);
      } else {
        await store.load(
          ref.read(coreHandlerProvider),
          profiles.map((p) => p.id).toList(),
        );
      }
    } catch (error) {
      commonPrint.log('SSE subscription catalog unavailable: $error');
      if (mounted && revision == _loadRevision) {
        setState(() => _error = '节点目录读取失败，请刷新：$error');
      }
    } finally {
      if (mounted && revision == _loadRevision)
        setState(() => _loading = false);
    }
  }

  Future<void> _select(Map<String, dynamic> entry) async {
    setState(() {
      _selecting = '${entry['profileId']}:${entry['key']}';
      _error = '';
    });
    try {
      await ref.read(profilesActionProvider.notifier).selectSseNode(entry);
    } catch (error) {
      commonPrint.log('SSE subscription node selection failed: $error');
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _selecting = null);
    }
  }

  @override
  void dispose() {
    store.removeListener(_storeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(profilesProvider);
    final currentId = ref.watch(currentProfileIdProvider);
    final currentProfile = profiles.where((p) => p.id == currentId).firstOrNull;
    final currentTarget =
        currentProfile?.selectedMap['GLOBAL'] ??
        ref.watch(
          selectedProxyNameProvider(
            currentProfile?.currentGroupName ?? 'GLOBAL',
          ),
        );
    final resolved = currentTarget == null
        ? null
        : ref.watch(realSelectedProxyStateProvider(currentTarget)).proxyName;
    final currentNode = resolved == '' ? null : resolved;
    final query = ref
        .watch(queryProvider(QueryTag.proxies))
        .trim()
        .toLowerCase();
    final groups = [
      for (final profile in profiles)
        (
          profile: profile,
          nodes: store.entriesFor(
            profile.id,
            query: profile.label.toLowerCase().contains(query) ? '' : query,
          ),
        ),
    ];
    final successful = store.attemptedKeys
        .where(
          (key) =>
              SseHistory.object(
                SseHistory.object(store.history[key])['latest'],
              )['status'] ==
              'done',
        )
        .length;
    final error = [_error, store.error].where((e) => e.isNotEmpty).join('\n');
    return CommonScaffold(
      resizeToAvoidBottomInset: false,
      title: context.appLocalizations.proxies,
      searchState: AppBarSearchState(
        onSearch: (value) =>
            ref.read(queryProvider(QueryTag.proxies).notifier).value = value,
      ),
      actions: [
        IconButton(
          tooltip: '刷新订阅节点',
          onPressed: _loading || store.running ? null : _refresh,
          icon: const Icon(Icons.refresh),
        ),
        if (ref.watch(providersProvider).isNotEmpty)
          IconButton(
            tooltip: context.appLocalizations.providers,
            onPressed: () async {
              await showExtend(context, builder: (_) => const ProvidersView());
              if (mounted) await _refresh();
            },
            icon: const Icon(Icons.cloud_sync_outlined),
          ),
      ],
      floatingActionButton: FloatingActionButton.extended(
        onPressed: store.running || profiles.isEmpty
            ? null
            : () => runSseTest(context),
        icon: Icon(store.running ? Icons.hourglass_top : Icons.speed),
        label: Text(store.running ? '后台测速中' : '全部测速'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _currentSelection(context, currentProfile, currentNode),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.sort,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${profiles.length} 个订阅 · 模拟 tok/s 从高到低',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    const Tooltip(
                      message: '8 秒固定模拟 SSE，不调用模型。整批 20 秒截止；失败和测速中保留历史有效成绩。',
                      child: Icon(Icons.info_outline, size: 18),
                    ),
                  ],
                ),
                if (store.running || _loading) ...[
                  const SizedBox(height: 10),
                  const LinearProgressIndicator(minHeight: 2),
                  const SizedBox(height: 8),
                  Text(
                    store.running ? '后台测速中 · 历史成绩保留，可继续切换节点和页面' : '正在读取订阅节点…',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ] else if (store.attemptedKeys.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '本轮成功 $successful/${store.attemptedKeys.length} · ${(store.elapsedMs / 1000).toStringAsFixed(2)} 秒',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Tooltip(
                      message: error,
                      child: Text(
                        error,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                if (store.issues.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Tooltip(
                      message: store.issues
                          .take(10)
                          .map((i) => '${i['profileId']}: ${i['error']}')
                          .join('\n'),
                      child: Text(
                        '${store.issues.length} 项未覆盖，请更新对应订阅或代理集合',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: profiles.isEmpty
                ? const Center(child: Text('请在本版导入并更新订阅，不会读取原版配置。'))
                : query.isNotEmpty && groups.every((g) => g.nodes.isEmpty)
                ? const Center(child: Text('没有匹配的节点或订阅'))
                : CustomScrollView(
                    key: const PageStorageKey('sse-subscriptions'),
                    slivers: [
                      for (final group in groups)
                        if (query.isEmpty || group.nodes.isNotEmpty) ...[
                          SliverToBoxAdapter(
                            child: _groupHeader(
                              context,
                              group.profile,
                              group.nodes.length,
                              query,
                              currentId == group.profile.id,
                            ),
                          ),
                          if (_isExpanded(group.profile.id, query) &&
                              group.nodes.isEmpty)
                            const SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 12,
                                ),
                                child: Text('暂无缓存节点，请更新此订阅后刷新。'),
                              ),
                            ),
                          if (_isExpanded(group.profile.id, query))
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                              sliver: SliverGrid(
                                gridDelegate:
                                    SliverGridDelegateWithMaxCrossAxisExtent(
                                      maxCrossAxisExtent:
                                          340 *
                                          MediaQuery.textScalerOf(context)
                                              .scale(1)
                                              .clamp(1, 3),
                                      mainAxisExtent:
                                          36 *
                                          MediaQuery.textScalerOf(context)
                                              .scale(1)
                                              .clamp(1, double.infinity),
                                      crossAxisSpacing: 6,
                                      mainAxisSpacing: 6,
                                    ),
                                delegate: SliverChildBuilderDelegate((
                                  context,
                                  index,
                                ) {
                                  final entry = group.nodes[index];
                                  final selected =
                                      currentId == group.profile.id &&
                                      SseHistory.objects(entry['aliases']).any(
                                        (alias) =>
                                            alias['profileId'] == currentId &&
                                            alias['name'] == currentNode,
                                      );
                                  return _nodeCard(
                                    context,
                                    group.profile,
                                    entry,
                                    selected,
                                  );
                                }, childCount: group.nodes.length),
                              ),
                            ),
                        ],
                      const SliverToBoxAdapter(child: SizedBox(height: 100)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  String _label(Profile profile) =>
      profile.label.isEmpty ? '订阅 ${profile.id}' : profile.label;

  Widget _currentSelection(
    BuildContext context,
    Profile? profile,
    String? node,
  ) {
    final colors = Theme.of(context).colorScheme;
    final title = profile == null
        ? '尚未选择订阅'
        : '${_label(profile)} / ${node ?? '未选择节点'}';
    return Container(
      key: const ValueKey('sse-current-selection'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.primary.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.near_me_outlined, size: 18, color: colors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '当前选择 · 订阅 / 节点',
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: colors.primary),
                ),
                const SizedBox(height: 2),
                Tooltip(
                  message: title,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupHeader(
    BuildContext context,
    Profile profile,
    int count,
    String query,
    bool current,
  ) {
    final expanded = _isExpanded(profile.id, query);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Semantics(
        expanded: expanded,
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            key: ValueKey('sse-group-${profile.id}'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => _toggle(profile.id, query),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _label(profile),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  if (current)
                    Padding(
                      padding: const EdgeInsets.only(left: 6, right: 10),
                      child: Text(
                        '当前',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  Text(
                    '$count 个节点',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _nodeCard(
    BuildContext context,
    Profile profile,
    Map<String, dynamic> entry,
    bool selected,
  ) {
    final record = SseHistory.object(store.history[entry['key']]);
    final good = SseHistory.success(record);
    final latest = SseHistory.object(record['latest']);
    final speed = good?['tokPerSec'] as num?;
    String metric(String key) =>
        (good?[key] as num?)?.toStringAsFixed(1) ?? '—';
    final measuredAt = (record['measuredAt'] as num?)?.toInt();
    final burst = good?['burstRatio'] as num?;
    final burstText = burst == null
        ? '—'
        : '${(burst * 100).toStringAsFixed(1)}%';
    final details = good == null
        ? '尚无有效模拟 SSE 成绩'
        : [
            '模拟 tok/s，不代表模型吞吐',
            if (measuredAt != null)
              '测量时间：${DateTime.fromMillisecondsSinceEpoch(measuredAt).toLocal()}',
            '首事件 ${metric('firstMs')} ms · 抖动 ${metric('jitterMs')} ms',
            '最大间隔 ${metric('maxGapMs')} ms · 攒包比例 $burstText',
            '流式质量：${good['flowPass'] == true ? '合格' : '不合格'}',
          ].join('\n');
    final state = switch (latest['status']) {
      'failed' => '本轮失败',
      'timeout' => '本轮超时',
      'unmeasured' => '本轮未覆盖',
      'endpoint' => '测速源不可用',
      _ =>
        good == null
            ? '尚未测速'
            : good['flowPass'] == false
            ? '流式质量不合格'
            : '历史有效成绩',
    };
    final colors = Theme.of(context).colorScheme;
    final failed =
        [
          'failed',
          'timeout',
          'endpoint',
          'unmeasured',
        ].contains(latest['status']) ||
        good?['flowPass'] == false;
    return Card.outlined(
      key: ValueKey('sse-node-${profile.id}-${entry['key']}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(
          color: selected
              ? colors.primary
              : colors.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      color: selected ? colors.secondaryContainer : null,
      child: Tooltip(
        message:
            '${entry['name']}\n$state${latest['error'] == null ? '' : ': ${latest['error']}'}\n$details',
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: _selecting == null ? () => _select(entry) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.check_circle : Icons.language,
                  size: 15,
                  color: selected ? colors.primary : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${entry['name']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(fontSize: 12.5),
                  ),
                ),
                const SizedBox(width: 6),
                if (failed)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.error_outline,
                      size: 12,
                      color: colors.error,
                    ),
                  ),
                Text(
                  speed == null
                      ? '— tok/s'
                      : '${speed.toStringAsFixed(1)} tok/s',
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: colors.primary),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  height: 28,
                  width: 28,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: '重测此节点',
                    onPressed: store.running
                        ? null
                        : () => runSseTest(
                            context,
                            name: '${entry['name']}',
                            profileId: profile.id,
                          ),
                    icon: const Icon(Icons.speed, size: 15),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
