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
                        '${profiles.length} 个订阅 · 按淘汰赛得分排序',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    const Tooltip(
                      message:
                          '全部测速：每个节点连 chatgpt.com 和 api.anthropic.com，只认未登录的 401，不调用模型；ChatGPT 热连接连测 5 次取最小值。\n'
                          '按出口机房的中位延迟选出最快的两个机房，其中所有节点保持空闲连接，先被掐断的先淘汰，前四名依次加 4、3、2、1 分并累计。\n'
                          '重启切到最高分节点；Claude 会话或 GPT 桥出现真实连接失败时切到下一名。',
                      child: Icon(Icons.info_outline, size: 18),
                    ),
                  ],
                ),
                if (store.running || _loading) ...[
                  const SizedBox(height: 10),
                  const LinearProgressIndicator(minHeight: 2),
                  const SizedBox(height: 8),
                  Text(
                    store.tournamentRunning
                        ? _tournamentProgress()
                        : store.running
                        ? '后台初筛中 · 上次成绩保留，可继续切换节点和页面'
                        : '正在读取订阅节点…',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ] else if (store.attemptedKeys.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '本轮初筛成功 $successful/${store.attemptedKeys.length} · ${(store.elapsedMs / 1000).toStringAsFixed(2)} 秒',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (!store.tournamentRunning && store.tournament.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    _tournamentSummary(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (store.failover.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    _failoverSummary(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
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

  String _colos() {
    final colos = SseHistory.objects(store.tournament['colos']).take(2);
    return colos
        .map((c) => '${c['location']} ${(c['latencyMs'] as num?)?.round()}ms')
        .join('、');
  }

  String _tournamentProgress() {
    final entrants = SseHistory.objects(store.tournament['entrants']);
    final alive = entrants.where((e) => e['alive'] == true).length;
    final startedAt = (store.tournament['startedAt'] as num?)?.toInt() ?? 0;
    final seconds = startedAt == 0
        ? 0
        : (DateTime.now().millisecondsSinceEpoch - startedAt) ~/ 1000;
    return '淘汰赛：${_colos()} 共 ${entrants.length} 个节点，剩 $alive 个 · 已 $seconds 秒';
  }

  String _tournamentSummary() {
    final t = store.tournament;
    final error = t['error']?.toString() ?? '';
    if (error.isNotEmpty) return '最近一场淘汰赛未进行：$error';
    final entrants = SseHistory.objects(t['entrants']);
    final podium = (t['podium'] as List?) ?? const [];
    if (podium.isEmpty) return '尚无淘汰赛结果';
    final winner = entrants.firstWhere(
      (e) => e['key'] == podium.first,
      orElse: () => {},
    );
    final idle = ((winner['idleMs'] as num?) ?? 0) / 1000;
    final finishedAt = (t['finishedAt'] as num?)?.toInt();
    final when = finishedAt == null
        ? ''
        : ' · ${DateTime.fromMillisecondsSinceEpoch(finishedAt).toLocal().toString().substring(5, 16)}';
    return '最近一场：${_colos()} · ${entrants.length} 个节点 · 冠军 ${winner['name'] ?? '—'}（空闲存活 ${idle.toStringAsFixed(0)} 秒）$when';
  }

  String _failoverSummary() {
    final f = store.failover;
    final at = (f['at'] as num?)?.toInt();
    final when = at == null
        ? ''
        : DateTime.fromMillisecondsSinceEpoch(
            at,
          ).toLocal().toString().substring(11, 19);
    return '自动切换 $when：${f['source']} 连接失败（${f['detail']}）→ ${f['name']}';
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
    final latency = good?['latencyMs'] as num?;
    final score = SseHistory.score(record);
    String ms(String key) => (good?[key] as num?)?.round().toString() ?? '—';
    final measuredAt = (record['measuredAt'] as num?)?.toInt();
    final location = good?['location'];
    final place = (latest['place'] as num?)?.toInt();
    final idle = ((latest['idleMs'] as num?) ?? 0) / 1000;
    final details = [
      '累计得分 $score',
      if (good != null) ...[
        'ChatGPT 热连接 5 次：最小 ${ms('latencyMs')} ms · 中位 ${ms('medianMs')} ms',
        '建连 ${ms('connectMs')} ms${location == null ? '' : ' · 出口机房 $location'}',
      ] else
        '尚无有效延迟成绩',
      if (place != null)
        '淘汰赛第 $place 名 · 空闲存活 ${idle.toStringAsFixed(0)} 秒${latest['survived'] == true ? '（未断）' : ''}',
      if (measuredAt != null)
        '测量时间：${DateTime.fromMillisecondsSinceEpoch(measuredAt).toLocal()}',
    ].join('\n');
    final blockedBy = '${latest['error'] ?? ''}'.startsWith('Claude')
        ? 'Claude'
        : 'ChatGPT';
    final state = switch (latest['status']) {
      'blocked' => '$blockedBy 拒绝该出口',
      'failed' => '本轮失败',
      'timeout' => '本轮超时',
      'unmeasured' => '本轮未覆盖',
      'unsupported' => '节点类型不支持',
      _ => good == null ? '尚未测速' : '最近一次成绩',
    };
    final colors = Theme.of(context).colorScheme;
    final failed = [
      'blocked',
      'failed',
      'timeout',
      'unmeasured',
      'unsupported',
    ].contains(latest['status']);
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
                // Scores accumulate without bound, so the label is capped to
                // keep the name and retest button on one line at large text.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 120 * MediaQuery.textScalerOf(context).scale(1),
                  ),
                  child: Text(
                    [
                      if (score > 0) '$score分',
                      latency == null ? '—' : '${latency.round()}ms',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: score > 0
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                  ),
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
