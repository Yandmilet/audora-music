/// Tab 3：榜单（分组展示 + 卡片带预览）。
///
/// 从 home_screen.dart 拆出（P3 结构整理，纯代码搬运）。
/// [ToplistCard] 由 home_screen.dart 转出，测试 import 路径不变。
library;
import 'package:flutter/material.dart';

import '../../services/qqmusic/qqmusic_catalog_dto.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../browse_screen.dart';
import 'remote_view.dart';

// ═══════════════════════════════════════════════════════════════
// Tab 3：榜单（分组展示 + 卡片带预览）
// ═══════════════════════════════════════════════════════════════

class ToplistsTab extends StatelessWidget {
  final AppState st;
  const ToplistsTab({super.key, required this.st});

  @override
  Widget build(BuildContext context) {
    return RemoteView<List<ToplistGroup>>(
      load: () async {
        final qq = st.qq;
        if (qq == null) throw StateError('数据层未接入');
        return qq.fetchToplistGroups();
      },
      builder: (context, groups) {
        return ListView.builder(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
          itemCount: groups.length,
          itemBuilder: (c, gi) {
            final g = groups[gi];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: gi == 0 ? 6 : 18, bottom: 10),
                  child: Text(
                    g.name,
                    style: const TextStyle(
                        fontSize: 15.5, fontWeight: FontWeight.w800),
                  ),
                ),
                for (final tl in g.toplists)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: ToplistCard(
                      brief: tl,
                      onTap: () {
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => BrowseScreen.toplist(st, tl),
                        ));
                      },
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

/// 榜单卡片（含 3 行预览）。
///
/// ## 为什么是公开的而不是 `_ToplistCard`
/// 「欧美榜卡片右侧出现黄黑 overflow 条纹 + 竖排红字」这个缺陷，
/// 只有在**歌手名足够长**时才复现（榜单列表接口返回的是全量拼接的歌手串）。
/// 私有类没法在 `test/toplist_card_overflow_test.dart` 里直接构造，
/// 而通过真机截图回归的代价太高、也不会每天跑。
/// 公开它，把「长歌手名不越出卡片」这件事钉进单元测试。
class ToplistCard extends StatelessWidget {
  final ToplistBrief brief;
  final VoidCallback onTap;

  const ToplistCard({super.key, required this.brief, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tokens.rLg),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
        decoration: BoxDecoration(
          color: dark ? Tokens.surfaceDark : Tokens.surface,
          borderRadius: BorderRadius.circular(Tokens.rLg),
          border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 4,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Tokens.brand,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        brief.title,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w800),
                      ),
                      if (brief.updateTime.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          '${brief.subtitle} · ${brief.totalNum} 首',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: t.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: t.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
            if (brief.preview.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final p in brief.preview.take(3))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 22,
                        child: Text(
                          '${p.rank}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: p.rank <= 3
                                ? Tokens.brand
                                : t.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      // ## 两个 Text 都必须受 flex 约束（别写回无约束的 Text）
                      // 榜单**列表**接口给的歌手名是「全量拼接」的：
                      // 欧美榜第 2 名是
                      // `HEARTSTEEL (心之钢)/英雄联盟/伯贤 (백현)/Connor Price/…`，
                      // 长度远超一行。Row 里放一个**没有** Expanded/Flexible 的
                      // Text，它会按 intrinsic 宽度布局（不受 Row 宽度限制），
                      // 于是整行右侧溢出 143 px —— 真机上就是用户看到的
                      // 卡片右缘黄黑相间的 overflow 条纹 + 竖排红字
                      // 「RIGHT OVERFLOWED BY 143 PIXELS」，把卡片内容盖住。
                      //
                      // 歌名 : 歌手 = 3 : 2 —— 歌名是主信息（用户扫榜单先看歌名），
                      // 歌手名允许被截断（`TextOverflow.ellipsis`）。
                      Expanded(
                        flex: 3,
                        child: Text(
                          p.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11.5, fontWeight: FontWeight.w500),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        flex: 2,
                        child: Text(
                          p.singer,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: t.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
