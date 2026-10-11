/// 音源详情弹层：当前这首歌的音源信息 + 通往「候选列表 / 手动搜索」的入口。
///
/// 从 player_source_sheets.dart 二次分层（P3 后续项，纯代码搬运）——
/// 详情 / 换源两组弹层职责不同：这里只展示与跳转，选择与绑定在
/// player_change_source_sheets.dart。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../player/player_sheets.dart';
import 'player_change_source_sheets.dart';

void showSourceSheet(BuildContext context, AppState st, Song song) {
  final src = song.source;
  showAppSheet(
    context,
    Builder(builder: (ctx) {
      final t = Theme.of(ctx);
      final dark = t.brightness == Brightness.dark;

      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          sheetHeader('音源详情', '${song.title} · ${song.artist}', ctx),
          const Divider(height: 1),
          if (src == null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(Icons.cloud_off_rounded,
                      size: 42, color: t.colorScheme.onSurfaceVariant),
                  const SizedBox(height: 12),
                  const Text('暂无可用音源'),
                  const SizedBox(height: 4),
                  Text(
                    '可以先重新匹配；仍找不到就用搜索手动指定',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: t.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      // 手动兜底：匹配引擎对冷门歌经常全军覆没（召回为空
                      // 或全被硬过滤），此时唯一出路是用户自己搜、自己挑。
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            showManualSearchSheet(context, st, song);
                          },
                          icon:
                              const Icon(Icons.manage_search_rounded, size: 17),
                          label: const Text('手动搜索音源'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                              backgroundColor: Tokens.brand),
                          onPressed: () async {
                            final id = song.id;
                            if (id == null) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                  content: Text('演示数据不支持重新匹配'),
                                  duration: kSnackHint,
                                ),
                              );
                              return;
                            }
                            final msg = await st.rematchSong(id);
                            if (!ctx.mounted) return;
                            Navigator.of(ctx).pop();
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
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: dark ? Tokens.surface2Dark : Tokens.surface2,
                      borderRadius: BorderRadius.circular(Tokens.rMd),
                    ),
                    child: Column(
                      children: [
                        _srcRow(t, '平台', '哔哩哔哩'),
                        _srcRow(t, '视频', src.bvid),
                        if (src.partTitle != null)
                          _srcRow(t, '分P', src.partTitle!),
                        // ★ 优先显示「这首实际在播的音质」。
                        // src 里的 qualityLabel 是库里缓存的「上次拉流档位」，
                        // 首次播放前它是「未知音质」（质量ID 0）——用户看到
                        // 的就成了「明明在放歌，却不知道放的什么音质」。
                        _srcRow(
                          t,
                          '当前音质',
                          st.playingQualityId > 0
                              ? '${st.playingQualityLabel} · '
                                  '质量ID ${st.playingQualityId}'
                              : '${src.qualityLabel} · '
                                  '质量ID ${src.qualityId}（未开始播放）',
                          highlight: true,
                        ),
                        // 把「上限偏好」一并摊开：用户改了设置能立刻看到它
                        // 生效在哪一档，而不是只能靠耳朵猜。这里只管在线
                        // 拉流的上限；下载音质是另一条独立偏好。
                        _srcRow(t, '在线音质上限', st.onlineQuality.label),
                        _srcRow(
                          t,
                          '匹配分',
                          '${src.matchScore.toStringAsFixed(2)} · '
                              '${src.auto ? "AUTO 自动采用" : "REVIEW 待复核"}',
                          highlight: true,
                        ),
                        _srcRow(
                          t,
                          '时长校验',
                          src.durationDelta == 0
                              ? '完全一致'
                              : '差 ${src.durationDelta > 0 ? "+" : ""}${src.durationDelta} 秒',
                        ),
                        _srcRow(t, 'UP主', src.uploader),
                        _srcRow(
                          t,
                          '播放量',
                          '${(src.playCount / 10000).toStringAsFixed(1)} 万',
                          last: true,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            // 用 Navigator 而非弹层：在 SourceSheet 上叠一个
                            // 全屏页，让用户能完整浏览候选列表。
                            // 关闭时回到这里继续看当前激活音源。
                            Navigator.of(ctx).pop();
                            showCandidateSheet(context, st, song);
                          },
                          icon: const Icon(Icons.swap_horiz_rounded, size: 17),
                          label: const Text('手动更换音源'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                              backgroundColor: Tokens.brand),
                          onPressed: () async {
                            final id = song.id;
                            if (id == null) {
                              // mock 数据没有数据库 id，无法落库重匹配
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                  content: Text('演示数据不支持重新匹配'),
                                  duration: kSnackHint,
                                ),
                              );
                              return;
                            }
                            final msg = await st.rematchSong(id);
                            if (!ctx.mounted) return;
                            Navigator.of(ctx).pop();
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
                  const SizedBox(height: 8),
                ],
              ),
            ),
        ],
      );
    }),
  );
}

Widget _srcRow(ThemeData t, String k, String v,
    {bool highlight = false, bool last = false}) {
  return Padding(
    padding: EdgeInsets.only(bottom: last ? 0 : 8),
    child: Row(
      children: [
        SizedBox(
          width: 66,
          child: Text(
            k,
            style: TextStyle(
                fontSize: 11.5, color: t.colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Text(
            v,
            style: TextStyle(
              fontSize: 12,
              fontWeight: highlight ? FontWeight.w800 : FontWeight.w600,
              color: highlight ? Tokens.brand : null,
            ),
          ),
        ),
      ],
    ),
  );
}
