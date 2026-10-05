/// 换源弹层：候选列表（含重新匹配）+ 手动搜索换源（含候选瓷砖与置信标签）。
///
/// 从 player_source_sheets.dart 二次分层（P3 后续项，纯代码搬运）。
/// 唯一入口在 player_source_sheet.dart（音源详情页的两个按钮）。
library;

import 'package:flutter/material.dart';

import '../../data/db/rows.dart';
import '../../models/models.dart';
import '../../services/bilibili/bili_dto.dart' show VideoCandidate;
import '../../services/match/match_config.dart' show MatchConfidenceX;
import '../../state/app_state.dart';
import '../../theme.dart';
import '../player/player_sheets.dart';

// ═══════════════════════════════════════════════════════════════
// 手动更换音源面板
// ═══════════════════════════════════════════════════════════════

/// 「手动更换音源」面板：列出该歌所有候选 + 重新匹配按钮。
///
/// ## 设计取舍
/// 旧版有专门的"音源匹配管理"页面（在「我的」页设置里），但用户场景分散：
/// 想换音源的时机大多数是「播放中发现这首歌不对」，此时打开的全屏播放页
/// 才是自然入口——也就是这里。把全局页删掉后，**唯一的换音源入口就是这个面板**，
/// 不再需要全局页。
///
/// ## 行为
/// - 列出 BindingDao.getCandidates(songId) 的所有候选，按分数倒序
/// - 当前激活项标「正在使用」
/// - 点击非激活项 → AppState.switchSource 切音源并重拉流
/// - 底部「重新匹配」按钮 → AppState.rematchSong
/// - 没有候选时给「重新匹配」按钮即可（重新匹配后会自动刷新）
void showCandidateSheet(BuildContext context, AppState st, Song song) {
  final id = song.id;

  // 演示数据没有 id → 无法落库切换。给个明确提示，避免用户以为功能坏了
  if (id == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('演示数据不支持手动匹配'),
        duration: kSnackHint,
      ),
    );
    return;
  }

  showAppSheet(
    context,
    StatefulBuilder(
      builder: (ctx, setSheet) {
        final t = Theme.of(ctx);
        final dark = t.brightness == Brightness.dark;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            sheetHeader('手动更换音源', '${song.title} · ${song.artist}', ctx),
            const Divider(height: 1),
            FutureBuilder<List<BindingRow>>(
              future: st.loadCandidates(id),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  );
                }
                if (snap.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      '加载失败：${snap.error}',
                      style: TextStyle(
                        fontSize: 12,
                        color: t.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                final rows = snap.data ?? const <BindingRow>[];
                if (rows.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
                    child: Column(
                      children: [
                        Icon(Icons.inbox_outlined,
                            size: 36,
                            color: t.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.5)),
                        const SizedBox(height: 10),
                        const Text(
                          '暂无可选音源',
                          style: TextStyle(fontSize: 13),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '重新匹配让系统再召回一轮；仍不行就手动搜索指定',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: t.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                              backgroundColor: Tokens.brand),
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            showManualSearchSheet(context, st, song);
                          },
                          icon:
                              const Icon(Icons.manage_search_rounded, size: 17),
                          label: const Text('手动搜索音源'),
                        ),
                      ],
                    ),
                  );
                }
                return ConstrainedBox(
                  constraints: BoxConstraints(
                    // 弹层在桌面/平板上太矮就难看，限制一个最小滚动高度
                    maxHeight: MediaQuery.of(ctx).size.height * 0.55,
                  ),
                  child: ListView.separated(
                    physics: const BouncingScrollPhysics(),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (_, i) =>
                        _candidateTile(ctx, st, setSheet, rows[i], dark),
                  ),
                );
              },
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        showManualSearchSheet(context, st, song);
                      },
                      icon: const Icon(Icons.manage_search_rounded, size: 17),
                      label: const Text('手动搜索音源'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        final msg = await st.rematchSong(id);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(msg),
                            duration: kSnackResult,
                          ),
                        );
                      },
                      icon: const Icon(Icons.refresh_rounded, size: 17),
                      label: const Text('重新匹配'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// 「手动搜索音源」面板：搜索 B站 → 用户亲选 → 绑定为该歌的音源并播放。
///
/// ## 为什么需要它
/// 匹配引擎的召回+打分对冷门歌/新歌经常全军覆没（召回为空或全部被
/// Stage2 硬过滤掉），此时「重新匹配」跑一百次结果都一样。唯一出路是
/// 用户自己搜、自己挑——打分交给用户的眼睛，标题黑名单不该拦着人工判断。
///
/// ## 行为
/// - 默认关键词 = 「歌名 歌手」，可改
/// - 点结果条目 → [AppState.bindManualSource]（视频落库 + 人工绑定 +
///   激活），若是当前在播的歌立即重拉流
/// - 单次搜索只发一个请求，不触碰限流红线
void showManualSearchSheet(BuildContext context, AppState st, Song song) {
  final id = song.id;
  if (id == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('演示数据不支持手动匹配'),
        duration: kSnackHint,
      ),
    );
    return;
  }

  final kw = TextEditingController(text: '${song.title} ${song.artist}');
  List<VideoCandidate>? results;
  var searching = false;

  showAppSheet(
    context,
    StatefulBuilder(
      builder: (ctx, setSheet) {
        final t = Theme.of(ctx);

        Future<void> doSearch() async {
          final q = kw.text.trim();
          if (q.isEmpty || searching) return;
          setSheet(() {
            searching = true;
            results = null;
          });
          final r = await st.manualSearchBili(q);
          setSheet(() {
            searching = false;
            results = r;
          });
        }

        Widget body;
        if (searching) {
          body = const Padding(
            padding: EdgeInsets.symmetric(vertical: 36),
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
          );
        } else if (results == null) {
          body = Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Column(
              children: [
                Icon(Icons.manage_search_rounded,
                    size: 36,
                    color:
                        t.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                const SizedBox(height: 10),
                Text(
                  '输入关键词搜索 B站 视频\n点选任意一条即作为这首歌的音源',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: t.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          );
        } else if (results!.isEmpty) {
          body = Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Text(
              '没有搜到相关视频，换个关键词试试',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
          );
        } else {
          // 结果区高度 = 45% 屏高 - 键盘占位（键盘弹出时收窄结果区，
          // 下限 120，避免小屏 + 键盘把结果压没）。
          final h = MediaQuery.of(ctx).size.height * 0.45 -
              MediaQuery.of(ctx).viewInsets.bottom;
          body = ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: h < 120 ? 120 : h,
            ),
            child: ListView.separated(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              itemCount: results!.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (_, i) => _manualResultTile(
                ctx,
                st,
                context,
                id,
                results![i],
                song,
              ),
            ),
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            sheetHeader('手动搜索音源', '${song.title} · ${song.artist}', ctx),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: kw,
                      onSubmitted: (_) => doSearch(),
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '歌名 歌手',
                        prefixIcon: const Icon(Icons.search_rounded, size: 18),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(Tokens.rMd),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style:
                        FilledButton.styleFrom(backgroundColor: Tokens.brand),
                    onPressed: searching ? null : doSearch,
                    icon: const Icon(Icons.search_rounded, size: 17),
                    label: const Text('搜索'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            body,
            SizedBox(height: MediaQuery.of(ctx).padding.bottom + 8),
          ],
        );
      },
    ),
  );
}

/// 手动搜索结果的一项。点击 → 绑定为音源 + 立即播放。
Widget _manualResultTile(
  BuildContext sheetCtx,
  AppState st,
  BuildContext outerCtx,
  int songId,
  VideoCandidate v,
  Song song,
) {
  final t = Theme.of(sheetCtx);
  final mm = v.durationSec ~/ 60;
  final ss = (v.durationSec % 60).toString().padLeft(2, '0');

  return ListTile(
    dense: true,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Tokens.rMd),
    ),
    title: Text(
      v.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        '${v.author.isEmpty ? "未知UP" : v.author}'
        ' · $mm:$ss'
        ' · ${(v.play / 10000).toStringAsFixed(1)} 万播放'
        ' · ${v.bvid}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: t.colorScheme.onSurfaceVariant),
      ),
    ),
    trailing: const Icon(Icons.play_circle_outline_rounded, size: 22),
    onTap: () async {
      Navigator.of(sheetCtx).pop();
      final msg = await st.bindManualSource(songId: songId, video: v);
      if (!outerCtx.mounted) return;
      ScaffoldMessenger.of(outerCtx).showSnackBar(
        SnackBar(content: Text(msg), duration: kSnackResult),
      );
    },
  );
}

/// 候选列表的一项。点击即触发切换并重拉流（AppState.switchSource 内部完成）。
Widget _candidateTile(BuildContext ctx, AppState st,
    void Function(void Function()) setSheet, BindingRow r, bool dark) {
  final t = Theme.of(ctx);
  // REJECTED 用灰色文字——它已经在候选里，但用户选了大概率翻车，
  // 视觉上要有"不推荐"的暗示而不是和正常候选一样亮。
  final isRejected = r.confidence.label == 'REJECTED';
  final inkColor = isRejected
      ? t.colorScheme.onSurfaceVariant.withValues(alpha: 0.55)
      : t.colorScheme.onSurface;

  return InkWell(
    borderRadius: BorderRadius.circular(Tokens.rMd),
    onTap: r.isActive
        ? null
        : () async {
            // 乐观地把 UI 切到"切换中"避免用户连点；switchSource 完成后关弹层
            setSheet(() {});
            final msg = await st.switchSource(songId: r.songId, bvid: r.bvid);
            if (!ctx.mounted) return;
            Navigator.of(ctx).pop();
            ScaffoldMessenger.of(ctx).showSnackBar(
              SnackBar(content: Text(msg), duration: kSnackResult),
            );
          },
    child: Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      decoration: BoxDecoration(
        // 激活项暗色必须用 brandSoftDark（深酒红），不能用亮色的
        // brandSoft 浅粉——浅粉底 + 暗色主题近白文字 = 不可读
        color: r.isActive
            ? (dark ? Tokens.brandSoftDark : Tokens.brandSofter)
            : (dark ? Tokens.surface2Dark : Tokens.surface2),
        borderRadius: BorderRadius.circular(Tokens.rMd),
        border: r.isActive
            ? Border.all(
                color: Tokens.brand.withValues(alpha: dark ? 0.5 : 0.35))
            : null,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        r.bvid,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight:
                              r.isActive ? FontWeight.w800 : FontWeight.w700,
                          color: inkColor,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _confTag(t, r.confidence.label),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '匹配分 ${r.matchScore.toStringAsFixed(2)}'
                  '${isRejected ? " · 不推荐" : ""}',
                  style: TextStyle(
                    fontSize: 11,
                    color: t.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (r.isActive)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: Tokens.brand,
                borderRadius: BorderRadius.circular(Tokens.rFull),
              ),
              child: const Text(
                '正在使用',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            )
          else
            Icon(
              Icons.check_circle_outline_rounded,
              size: 18,
              color: t.colorScheme.onSurfaceVariant,
            ),
        ],
      ),
    ),
  );
}

/// 候选置信度标签（AUTO / REVIEW / REJECTED 三色）。
Widget _confTag(ThemeData t, String label) {
  Color bg;
  Color ink;
  switch (label) {
    case 'AUTO':
      bg = SemColor.okBg;
      ink = SemColor.okInk;
      break;
    case 'REVIEW':
      bg = SemColor.pendingBg;
      ink = SemColor.pendingInk;
      break;
    default: // REJECTED
      bg = SemColor.noneBg;
      ink = SemColor.noneInk;
  }
  final dark = t.brightness == Brightness.dark;
  if (dark) {
    bg = label == 'AUTO'
        ? SemColor.okBgDark
        : label == 'REVIEW'
            ? SemColor.pendingBgDark
            : SemColor.noneBgDark;
    ink = label == 'AUTO'
        ? SemColor.okInkDark
        : label == 'REVIEW'
            ? SemColor.pendingInkDark
            : SemColor.noneInkDark;
  }

  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(Tokens.rFull),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 9.5,
        fontWeight: FontWeight.w800,
        color: ink,
        letterSpacing: 0.3,
      ),
    ),
  );
}
