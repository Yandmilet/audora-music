/// 诊断日志页 —— 匹配链路 / 网络 / 崩溃的本地回看。
///
/// ## 为什么要有这个页面
/// 真机上「这首歌为什么没匹配上」「刚才为什么闪退」是最难复现的两类问题：
/// 现场转瞬即逝，日志只存在于当时的控制台里。这个页面把 [DiagLog]
/// 落盘的 JSONL 直接读回来，让用户（也就是开发者本人）能在真机上
/// 当场看到四阶段链路、每次请求的返回码与崩溃栈。
///
/// ## 统计条为什么放在最上面
/// 限流与匹配质量都是**趋势问题**：单次看不出，攒一天就明显。
/// 今日请求数 / -412 次数 / 匹配成功率三个数字是判断
/// 「配额够不够用」与「召回要不要调」的第一手依据。
library;

import 'package:flutter/material.dart';

import '../services/diag/diag_log.dart';
import '../state/app_state.dart';
import '../theme.dart';

class DiagLogPage extends StatefulWidget {
  final AppState st;

  const DiagLogPage({super.key, required this.st});

  @override
  State<DiagLogPage> createState() => _DiagLogPageState();
}

class _DiagLogPageState extends State<DiagLogPage> {
  List<DiagEntry> _entries = const [];
  DiagStats _stats = const DiagStats();
  DiagCategory? _filter;
  String _keyword = '';
  bool _loading = true;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      if (_keyword == _search.text) return;
      setState(() => _keyword = _search.text);
    });
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final entries = await DiagLog.instance.readAll();
    final stats = await DiagLog.instance.stats();
    if (!mounted) return;
    setState(() {
      // 最新的在最上面：排查时关心的是"刚才发生了什么"
      _entries = entries.reversed.toList();
      _stats = stats;
      _loading = false;
    });
  }

  List<DiagEntry> get _visible {
    final kw = _keyword.trim().toLowerCase();
    return _entries.where((e) {
      if (_filter != null && e.category != _filter) return false;
      if (kw.isEmpty) return true;
      if (e.message.toLowerCase().contains(kw)) return true;
      return e.fields.values.any(
        (v) => v.toString().toLowerCase().contains(kw),
      );
    }).toList();
  }

  Future<void> _export() async {
    final path = await DiagLog.instance.export();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(path == null ? '导出失败（日志目录不可用）' : '已导出到：$path'),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空诊断日志？', style: TextStyle(fontSize: 16)),
        content: const Text(
          '会删除本机保留的全部日志（含崩溃记录）。设置不受影响，无法撤销。',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await DiagLog.instance.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final visible = _visible;

    return Scaffold(
      backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
      appBar: AppBar(
        title: const Text('诊断日志',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: '导出为 JSONL',
            icon: const Icon(Icons.ios_share_rounded, size: 20),
            onPressed: _export,
          ),
          IconButton(
            tooltip: '清空日志',
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            onPressed: _clear,
          ),
        ],
      ),
      body: Column(
        children: [
          _StatsBar(stats: _stats, dark: dark),
          _VerboseRow(st: widget.st),
          _FilterBar(
            current: _filter,
            onPick: (c) => setState(() => _filter = c),
            controller: _search,
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : visible.isEmpty
                    ? _EmptyState(dark: dark)
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: visible.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) =>
                            _EntryCard(entry: visible[i], dark: dark),
                      ),
          ),
        ],
      ),
    );
  }
}

// ── 统计条 ────────────────────────────────────────────────

class _StatsBar extends StatelessWidget {
  final DiagStats stats;
  final bool dark;

  const _StatsBar({required this.stats, required this.dark});

  @override
  Widget build(BuildContext context) {
    final rate = stats.matchRate;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: dark ? Tokens.surfaceDark : Tokens.surface,
        borderRadius: BorderRadius.circular(Tokens.rLg),
        border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
      ),
      child: Row(
        children: [
          _Stat(
            value: '${stats.requests}',
            label: '今日请求',
            danger: stats.rateLimited > 0,
          ),
          _Stat(
            value: '${stats.rateLimited}',
            label: '风控 -412',
            danger: stats.rateLimited > 0,
          ),
          _Stat(
            value: rate == null ? '—' : '${(rate * 100).round()}%',
            label: '匹配成功',
          ),
          _Stat(
            value: '${stats.crashes}',
            label: '崩溃',
            danger: stats.crashes > 0,
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  final bool danger;

  const _Stat({required this.value, required this.label, this.danger = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: danger ? Tokens.brand : null,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ── 详细级开关 ────────────────────────────────────────────

class _VerboseRow extends StatelessWidget {
  final AppState st;

  const _VerboseRow({required this.st});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: dark ? Tokens.surfaceDark : Tokens.surface,
        borderRadius: BorderRadius.circular(Tokens.rLg),
        border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
      ),
      // ⚠️ 必须套一层 Material：SwitchListTile 的波纹画在最近的 Material
      // 祖先上，直接放进带背景色的 DecoratedBox 里会「看不見水波纹」，
      // 框架也会在测试里直接断言报错。
      child: Material(
        color: Colors.transparent,
        child: SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: st.diagVerbose,
          onChanged: (v) => st.setDiagVerbose(v),
          title: const Text('详细级（记录全部网络请求）',
              style: TextStyle(fontSize: 13.5)),
          subtitle: Text(
            '摘要级（匹配过程与崩溃）始终开启，无需开关。'
            '排查限流时再打开详细级，平时关掉可减少日志量。',
            style: TextStyle(
              fontSize: 11,
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

// ── 筛选与搜索 ────────────────────────────────────────────

class _FilterBar extends StatelessWidget {
  final DiagCategory? current;
  final ValueChanged<DiagCategory?> onPick;
  final TextEditingController controller;

  const _FilterBar({
    required this.current,
    required this.onPick,
    required this.controller,
  });

  static const _labels = {
    DiagCategory.match: '匹配',
    DiagCategory.net: '网络',
    DiagCategory.playback: '播放',
    DiagCategory.crash: '崩溃',
    DiagCategory.ui: '界面',
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _chip(context, null, '全部', dark),
                for (final e in _labels.entries)
                  _chip(context, e.key, e.value, dark),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索歌名 / bvid / 错误信息',
              hintStyle: TextStyle(
                fontSize: 12.5,
                color: t.colorScheme.onSurfaceVariant,
              ),
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Tokens.rMd),
                borderSide: BorderSide(
                  color: dark ? Tokens.lineDark : Tokens.line,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Tokens.rMd),
                borderSide: BorderSide(
                  color: dark ? Tokens.lineDark : Tokens.line,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    DiagCategory? cat,
    String label,
    bool dark,
  ) {
    final t = Theme.of(context);
    final on = current == cat;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: on,
        showCheckmark: false,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: dark ? Tokens.surfaceDark : Tokens.surface,
        selectedColor: Tokens.brandSoft,
        side: BorderSide(
          color: on ? Tokens.brand : (dark ? Tokens.lineDark : Tokens.line),
        ),
        labelStyle: TextStyle(
          color: on ? Tokens.brand : t.colorScheme.onSurfaceVariant,
          fontWeight: on ? FontWeight.w700 : FontWeight.w400,
        ),
        onSelected: (_) => onPick(cat),
      ),
    );
  }
}

// ── 单条日志 ──────────────────────────────────────────────

class _EntryCard extends StatelessWidget {
  final DiagEntry entry;
  final bool dark;

  const _EntryCard({required this.entry, required this.dark});

  static Color _levelColor(DiagLevel l) => switch (l) {
        DiagLevel.debug => const Color(0xFF9AA0AC),
        DiagLevel.info => const Color(0xFF378ADD),
        DiagLevel.warn => const Color(0xFFBA7517),
        DiagLevel.error => Tokens.brand,
      };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = _levelColor(entry.level);
    return Container(
      decoration: BoxDecoration(
        color: dark ? Tokens.surfaceDark : Tokens.surface,
        borderRadius: BorderRadius.circular(Tokens.rMd),
        border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        leading: Container(
          width: 6,
          height: 28,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        title: Text(
          entry.message,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Row(
            children: [
              Text(
                _categoryLabel(entry.category),
                style: TextStyle(fontSize: 10.5, color: color),
              ),
              const SizedBox(width: 8),
              Text(
                _time(entry.at),
                style: TextStyle(
                  fontSize: 10.5,
                  color: t.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: dark ? Tokens.surface2Dark : Tokens.surface2,
              borderRadius: BorderRadius.circular(Tokens.rSm),
            ),
            child: SelectableText(
              entry.detailText.isEmpty ? '（无附加字段）' : entry.detailText,
              style: TextStyle(
                fontSize: 11,
                height: 1.45,
                fontFamily: 'monospace',
                color: t.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _categoryLabel(DiagCategory c) => switch (c) {
        DiagCategory.match => '匹配',
        DiagCategory.net => '网络',
        DiagCategory.playback => '播放',
        DiagCategory.crash => '崩溃',
        DiagCategory.ui => '界面',
      };

  static String _time(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:'
        '${two(t.second)}';
  }
}

class _EmptyState extends StatelessWidget {
  final bool dark;

  const _EmptyState({required this.dark});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.article_outlined,
              size: 40,
              color: t.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              '还没有日志',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: t.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '去播放一首歌或匹配一次音源，过程会记录在这里。'
              '崩溃记录也会自动出现。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
