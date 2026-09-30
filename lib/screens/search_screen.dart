import 'package:flutter/material.dart';

import '../data/repository/library_repository.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

class SearchScreen extends StatefulWidget {
  final AppState st;
  const SearchScreen({super.key, required this.st});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final TextEditingController _c =
      TextEditingController(text: widget.st.query);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final hasQuery = st.query.trim().isNotEmpty;

    return Container(
      color: dark ? Tokens.bgDark : Tokens.bg,
      child: SafeArea(
        child: Column(
          children: [
            // 搜索头
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 16, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: st.closeSearch,
                    icon: const Icon(Icons.arrow_back_rounded, size: 22),
                  ),
                  Expanded(
                    child: Container(
                      height: 42,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: dark ? Tokens.surface2Dark : Tokens.surface,
                        borderRadius: BorderRadius.circular(Tokens.rFull),
                        border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.search_rounded,
                              size: 18, color: t.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _c,
                              focusNode: _focus,
                              onChanged: st.setQuery,
                              // 回车 = 明确意图 → 本地 + 在线一起搜
                              onSubmitted: st.commitSearch,
                              textInputAction: TextInputAction.search,
                              style: const TextStyle(fontSize: 13.5),
                              decoration: const InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                hintText: '搜索歌曲、歌手、专辑',
                                hintStyle: TextStyle(fontSize: 13.5),
                              ),
                            ),
                          ),
                          if (hasQuery)
                            GestureDetector(
                              onTap: () {
                                _c.clear();
                                st.setQuery('');
                                st.clearOnlineResults();
                              },
                              child: Icon(Icons.cancel_rounded,
                                  size: 17,
                                  color: t.colorScheme.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: hasQuery
                  ? _Results(st: st)
                  : _History(st: st, onPick: (q) {
                      _c.text = q;
                      st.commitSearch(q);
                    }),
            ),
          ],
        ),
      ),
    );
  }
}

/// 搜索页的初始态：搜索历史。
///
/// 曲库作为独立产品概念已删除（QQ 音乐元数据即曲库，音源在播放页匹配），
/// 这里不再展示「常听 / 最近添加」等本地列表——那些数据在「我的」页看。
class _History extends StatelessWidget {
  final AppState st;
  final ValueChanged<String> onPick;

  const _History({required this.st, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    if (st.history.isEmpty) {
      return const EmptyState(
        icon: Icons.search_rounded,
        title: '搜索 QQ 音乐',
        message: '输入歌名 / 歌手 / 专辑，按回车在线搜索 QQ 音乐。\n'
            '搜过的关键词会保留在这里。',
      );
    }

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        Row(
          children: [
            const Text('搜索历史',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
            const Spacer(),
            GestureDetector(
              onTap: st.clearHistory,
              child: Icon(Icons.delete_outline_rounded,
                  size: 18, color: t.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final h in st.history)
              GestureDetector(
                onTap: () => onPick(h),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                  decoration: BoxDecoration(
                    color: dark ? Tokens.surface2Dark : Tokens.surface,
                    borderRadius: BorderRadius.circular(Tokens.rFull),
                    border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
                  ),
                  child: Text(h, style: const TextStyle(fontSize: 12.5)),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 搜索结果：只搜 QQ 音乐（在线）。
///
/// 本地「曲库结果」段已删除：曲库作为独立概念不复存在，
/// 元数据来自 QQ 音乐，搜索的语义就是「去 QQ 音乐找这首歌」。
/// 点结果 = 播放（静默入库 + 按需匹配音源）。
class _Results extends StatelessWidget {
  final AppState st;
  const _Results({required this.st});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        _SectionHeader(
          title: 'QQ 音乐',
          trailing: st.onlineSearching
              ? '搜索中…'
              : (st.onlineResults.isEmpty ? null : '${st.onlineResults.length} 条'),
          trailingWidget: st.onlineSearching
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                )
              : null,
        ),
        _OnlineSection(st: st),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? trailing;
  final Widget? trailingWidget;

  const _SectionHeader({
    required this.title,
    this.trailing,
    this.trailingWidget,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(title,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (trailingWidget != null) ...[
            trailingWidget!,
            const SizedBox(width: 6),
          ],
          if (trailing != null)
            Text(
              trailing!,
              style: TextStyle(
                  fontSize: 11.5, color: t.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

/// 在线结果区：搜索中 / 出错 / 空 / 有结果 四态。
class _OnlineSection extends StatelessWidget {
  final AppState st;
  const _OnlineSection({required this.st});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);

    // 数据层未接入（单测 / 预览）——没有 QQ 接口，如实说明
    if (!st.canSearchOnline) {
      return _note(t, '当前环境未接入网络数据层，无法在线搜索。');
    }

    if (st.onlineSearching && st.onlineResults.isEmpty) {
      return _note(t, '正在搜索 QQ 音乐…');
    }

    final err = st.onlineError;
    if (err != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _note(t, '在线搜索失败：$err'),
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: () => st.searchOnline(),
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('重试', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      );
    }

    if (st.onlineResults.isEmpty) {
      return _note(
        t,
        st.onlineSearched
            ? 'QQ 音乐里也没有找到「${st.query}」。'
            : '按回车即可同时搜索 QQ 音乐。',
      );
    }

    return Column(
      children: [
        for (final (i, e) in st.onlineResults.indexed)
          _OnlineTile(
            entry: e,
            onTap: () => st.playOnline(st.onlineResults, i),
          ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: st.onlineResults.isEmpty
                ? null
                : () => st.playOnline(st.onlineResults, 0),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: Text(
              '全部播放（${st.onlineResults.length} 首）',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ),
      ],
    );
  }

  Widget _note(ThemeData t, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          text,
          style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant),
        ),
      );
}

/// 在线结果条目：整行点击 = 播放（静默入库 + 按需匹配）。
///
/// 与「导入优先」时代的区别：不再有独立的导入按钮。
/// 点一下就是播——入库这件事用户无感知，播放统计 / 收藏 / 歌词
/// 都依赖入库后的 id，[AppState.playOnline] 一并处理。
class _OnlineTile extends StatelessWidget {
  final OnlineSong entry;
  final VoidCallback onTap;

  const _OnlineTile({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = entry.song;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Tokens.rSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              CoverArt(seed: s.coverSeed, size: 46, radius: Tokens.rSm),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        s.artist,
                        s.album,
                        if (s.duration > 0) _fmtDuration(s.duration),
                      ].where((x) => x.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: t.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (entry.inLibrary)
                Icon(Icons.check_circle_rounded,
                    size: 14,
                    color: t.brightness == Brightness.dark
                        ? SemColor.okInkDark
                        : SemColor.okInk),
              Icon(
                Icons.play_arrow_rounded,
                size: 20,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmtDuration(int sec) {
    final m = sec ~/ 60;
    final s2 = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s2';
  }
}
