/// 「一批歌」的通用列表页：收藏 / 最近听过 /（第二期的）本地与下载共用。
///
/// ## 为什么从 mine_screen 的私有 _SongListPage 抽出来
/// 首页那张「最近听过」卡片也要落到一个列表页上（卡片本身只进列表、
/// 不直接播）。「我的」页与首页是两个入口、同一形态，复制一份必然会
/// 分叉——之前这首歌的封面修复就只改了一处（见 test/mine_cover_test.dart）。
///
/// ## 队列红线
/// 点任意一首 → 队列 = **整张列表**（[songs]），沿列表顺序上下切。
/// 展示层可以截断，队列不行（见 [AppState.playSong] 的注释）。
///
/// ## 两种数据来源
/// - 只给 [songs]：静态快照（最近听过——AppState 里已经算好了）。
/// - 给 [loader]：**进页面现查**，下拉可刷新。收藏走这条，因为它是
///   数据库里的用户资产，不受「曲库只加载最近 500 行」这个窗口限制
///   （2026-10-11 修「计数写着 1 首、点进去暂无内容」）。
library;

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

class SongListPage extends StatefulWidget {
  final String title;

  /// 静态列表；[loader] 非空时这只是首帧占位，真实内容以查询结果为准。
  final List<Song> songs;
  final AppState st;

  /// 现查一批歌（收藏 = 查 liked_song 表）。null = 用 [songs] 这份快照。
  final Future<List<Song>> Function()? loader;

  /// 空列表时的提示语。默认「暂无内容」——收藏还没点过、最近还没听过，
  /// 都是正常的空态，不该写成错误口吻。
  final String emptyText;

  const SongListPage({
    super.key,
    required this.title,
    required this.songs,
    required this.st,
    this.loader,
    this.emptyText = '暂无内容',
  });

  @override
  State<SongListPage> createState() => _SongListPageState();
}

class _SongListPageState extends State<SongListPage> {
  late List<Song> _songs = widget.songs;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final loader = widget.loader;
    if (loader != null) {
      // 首帧之后再查：_load 里有 await，放在 initState 里同步跑会撞上
      // 「setState during build」。
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    final loader = widget.loader;
    if (loader == null || _loading) return;
    setState(() => _loading = true);
    // 查询失败按空列表收尾：这一页没有「重试」按钮之外的补救动作，
    // 把异常摊在屏幕上对用户没有意义（原因会进 AppState._loadError）。
    var got = const <Song>[];
    try {
      got = await loader();
    } catch (_) {
      // 保持空
    }
    if (!mounted) return;
    setState(() {
      _songs = got;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final songs = _songs;
    return Scaffold(
      backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
      appBar: AppBar(
        title: Text(widget.title,
            style: const TextStyle(fontWeight: FontWeight.w800)),
        backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
        elevation: 0,
      ),
      body: SwipeBack(
        onBack: () => Navigator.of(context).maybePop(),
        child: Builder(builder: (context) {
          // 查询中且手上还没有内容 → 转圈。已有内容时下拉刷新不打断阅读。
          if (_loading && songs.isEmpty) {
            return const Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            );
          }
          final body = songs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.inbox_rounded,
                        size: 48,
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        widget.emptyText,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics()),
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  itemCount: songs.length,
                  itemBuilder: (c, i) {
                    final s = songs[i];
                    return SongRow(
                      song: s,
                      // 左侧小封面必须是**真实专辑图**（song.coverUrl），不是
                      // CoverArt 的占位渐变。占位渐变只在「没有 albumMid 拼不出
                      // URL」或网络图加载失败时才该露出来——见 [SongCover]。
                      leading: SongCover(song: s, size: 46, radius: Tokens.rSm),
                      subtitle: '${s.artist} · ${s.album}',
                      showDuration: false,
                      trailing: s.sourceStatus != SourceStatus.ok
                          ? SourceBadge(status: s.sourceStatus, compact: true)
                          : null,
                      onTap: () => widget.st.playSong(s, source: songs),
                    );
                  },
                );
          // 只有会变的列表才值得刷新（静态快照套一层下拉刷新是纯装饰）
          return widget.loader == null
              ? body
              : RefreshIndicator(onRefresh: _load, child: body);
        }),
      ),
    );
  }
}
