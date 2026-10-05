import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';
import 'player/player_controls.dart';
import 'player/player_lyric_tab.dart';
import 'player/player_song_tab.dart';
import 'player/player_top_bar.dart';

/// 播放页（全屏上滑）
class PlayerScreen extends StatefulWidget {
  final AppState st;
  const PlayerScreen({super.key, required this.st});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin {
  /// 唱片自转周期。20s/圈 ≈ 3 RPM：真实黑胶 33⅓ RPM 太快，纯装饰旋转
  /// 用 12s 会显得急促，20s 才有「缓慢自转」的观感。
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 20),
  );

  /// 歌曲 / 歌词两页的翻页控制器。
  ///
  /// ## 为什么必须手动同步 [AppState.playerTab]
  /// 顶部 SegTabs 是 PageView 的指示器：点它要切页，滑页也要更新指示器。
  /// 真实状态在 [AppState.playerTab]（决定音源/音量等是否在歌词页禁用），
  /// 这里双向同步：AppState → PageController；PageView.onPageChanged → AppState。
  late final PageController _page =
      PageController(initialPage: widget.st.playerTab);

  @override
  void initState() {
    super.initState();
    widget.st.addListener(_onState);
    _syncSpin();
    _syncPageFromState();
  }

  void _onState() {
    _syncSpin();
    _syncPageFromState();
  }

  /// 当外部（setPlayerTab 切换 / 初始值变化）改了 playerTab 而 PageView
  /// 没跟上时，把页面滑到对应位置。
  ///
  /// 用 `_page.hasClients` 防止 build 之前 PageController 还未 attach。
  /// 用 `jumpToPage`（而非 animateToPage）避免与用户正在滑动的手势打架。
  void _syncPageFromState() {
    if (!mounted || !_page.hasClients) return;
    final target = widget.st.playerTab;
    if (_page.page?.round() == target) return;
    _page.jumpToPage(target);
  }

  void _syncSpin() {
    if (!mounted) return;
    if (widget.st.playing && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!widget.st.playing && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    widget.st.removeListener(_onState);
    _spin.dispose();
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final song = st.current;
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    if (song == null) {
      return const Scaffold(body: Center(child: Text('无播放内容')));
    }

    return Scaffold(
      backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            TopBar(st: st, song: song),
            if (st.playbackError != null) ErrorBanner(st: st),
            // SegTabs 提到 PageView 之上：用户切页时它不动，比各 tab 自带一份
            // 切换瞬间"消失又出现"更接近 iOS 音乐 app 的体感。
            SegTabs(st: st, page: _page),
            Expanded(
              child: PageView(
                controller: _page,
                physics: const BouncingScrollPhysics(),
                // onPageChanged 是「用户滑完松手」触发的；点 SegTabs 是程序化
                // 跳页（jumpToPage），不会触发它——所以双向同步都不会循环。
                onPageChanged: (i) {
                  if (widget.st.playerTab != i) {
                    widget.st.setPlayerTab(i);
                  }
                },
                children: [
                  SongTab(st: st, song: song, spin: _spin),
                  LyricTab(st: st),
                ],
              ),
            ),
            // 进度条订阅**秒级进度通道**：只重建这一小块，
            // 不陪着整棵树走（见 [AppState.posTick]）。
            ValueListenableBuilder<int>(
              valueListenable: st.posTick,
              builder: (_, __, ___) => ProgressBar(st: st),
            ),
            Controls(st: st),
            FootActions(st: st),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
          ],
        ),
      ),
    );
  }
}
