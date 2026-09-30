/// 音乐页（首页）：歌手库 / 歌单推荐 / 榜单 / 新歌推荐。
///
/// ## 产品形态（2026-09 方向调整）
/// 旧版是「导入优先」：先去搜索导入歌，首页才有内容。
/// 新版是「浏览优先」：打开就是 QQ音乐 的目录内容，点任何一首歌
/// 即播（后台静默入库 + 按需匹配），**不需要用户导入任何东西**。
///
/// ## 数据纪律（与空态契约同源）
/// 目录内容来自远端（`st.qq`），加载中就是转圈、失败就是重试，
/// **没有任何 mock 兜底**。曲库本地为空只影响「随便听一下」，
/// 不影响目录浏览——那本来就是两条独立的数据链。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/qqmusic/qqmusic_catalog_dto.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'browse_screen.dart';

/// 首页目录的 4 个 tab。顺序即用户的构想顺序。
const _kTabs = ['歌手库', '歌单推荐', '榜单', '新歌推荐'];

class HomeScreen extends StatelessWidget {
  final AppState st;

  const HomeScreen({super.key, required this.st});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return Container(
      color: dark ? Tokens.bgDark : Tokens.bg,
      child: SafeArea(
        bottom: false,
        child: DefaultTabController(
          length: _kTabs.length,
          child: Column(
            children: [
              // 顶栏
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 6, 0),
                child: Row(
                  children: [
                    const Text(
                      '音乐',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: st.toggleTheme,
                      icon: Icon(
                        st.isDark
                            ? Icons.light_mode_outlined
                            : Icons.dark_mode_outlined,
                        size: 21,
                      ),
                    ),
                  ],
                ),
              ),

              // 搜索框
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: _SearchBar(onTap: st.openSearch),
              ),

              // 随便听一下（只依赖本地曲库，有歌才出现）
              if (st.library.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                  child: _ShuffleCard(onPlay: st.shufflePlay),
                ),

              // 目录 tabs
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  splashBorderRadius: BorderRadius.circular(Tokens.rFull),
                  labelColor: dark ? Colors.white : Colors.black,
                  unselectedLabelColor: t.colorScheme.onSurfaceVariant,
                  labelStyle:
                      const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                  unselectedLabelStyle: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500),
                  indicatorColor: Tokens.brand,
                  indicatorSize: TabBarIndicatorSize.label,
                  dividerColor: Colors.transparent,
                  tabs: [for (final s in _kTabs) Tab(text: s)],
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _SingersTab(st: st),
                    _PlaylistsTab(st: st),
                    _ToplistsTab(st: st),
                    _NewSongsTab(st: st),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  final VoidCallback onTap;
  const _SearchBar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: dark ? Tokens.surface2Dark : Tokens.surface,
          borderRadius: BorderRadius.circular(Tokens.rFull),
          border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: 19, color: t.colorScheme.onSurfaceVariant),
            const SizedBox(width: 9),
            Text(
              '搜索歌曲、歌手、专辑',
              style: TextStyle(
                fontSize: 13.5,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShuffleCard extends StatelessWidget {
  final VoidCallback onPlay;
  const _ShuffleCard({required this.onPlay});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 17, 16, 17),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Tokens.rLg),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE5484D), Color(0xFFF2708C)],
        ),
        boxShadow: [
          BoxShadow(
            color: Tokens.brand.withValues(alpha: 0.28),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Row(
                  children: [
                    Icon(Icons.shuffle_rounded, size: 17, color: Colors.white),
                    SizedBox(width: 6),
                    Text(
                      '随便听一下',
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  '从你的收藏、常听和最近添加里智能混选',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Colors.white.withValues(alpha: 0.88),
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Material(
            color: Colors.white.withValues(alpha: 0.22),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPlay,
              child: const SizedBox(
                width: 46,
                height: 46,
                child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 目录视图的公共骨架：远端 Future 的三态（加载 / 错误重试 / 内容）
// ═══════════════════════════════════════════════════════════════

/// 远端目录视图的三态骨架。
///
/// 目录数据来自 QQ音乐，没有 mock 兜底：加载中就是转圈，
/// 失败给原因 + 重试按钮。retriable 用 key 重挂 FutureBuilder。
class _RemoteView<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext, T data) builder;
  const _RemoteView({super.key, required this.load, required this.builder});

  @override
  State<_RemoteView<T>> createState() => _RemoteViewState<T>();
}

class _RemoteViewState<T> extends State<_RemoteView<T>> {
  late Future<T> _future;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  void _retry() {
    setState(() {
      _epoch++;
      _future = widget.load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      key: ValueKey(_epoch),
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.only(top: 48),
              child: CircularProgressIndicator(),
            ),
          );
        }
        if (snap.hasError) {
          return Center(
            child: EmptyState(
              icon: Icons.cloud_off_outlined,
              title: '加载失败',
              message: '${snap.error}\n请检查网络后重试。',
              actionLabel: '重试',
              onAction: _retry,
            ),
          );
        }
        return widget.builder(context, snap.data as T);
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Tab 1：歌手库（地区 / 类型筛选 + 首字母索引 + 分页）
// ═══════════════════════════════════════════════════════════════
//
// ## 为什么这里终于能做筛选了（历史包袱说明）
// 旧实现走 `v8.fcg?channel=singer`，该接口的 `area`/`key` 参数被服务端忽略
// （传什么值都返回同一批），所以当时只敢把地区当**标签**显示，不敢摆筛选按钮。
// 2026-09-30 换用 `Music.SingerListServer/get_singer_list` 后筛选真实生效，
// 才把「标签」升级成「筛选项」。取值域全部来自服务端自报的 `tags` 字典，
// 见 [kSingerAreas] / [kSingerSexes] / [singerIndexId]。

/// 首字母索引条上的条目：`(服务端 index 取值, 显示标签)`。
///
/// `kSingerIndexHot`(-100) 排在队首、标签「热」——它不是字母，但用户心智里
/// 「热门」和「A-Z」是同一排入口（且它是默认值），放进同一条更省一行高度。
///
/// 取值和标签放在同一条 record 里，UI 层就不必再实现一遍「字母 ↔ index」
/// 的换算——那个换算只该有 [singerIndexId] 一份实现。
final List<(int, String)> _kSingerIndexBar = [
  (kSingerIndexHot, '热'),
  for (final l in kSingerLetters) (singerIndexId(l), l),
];

class _SingersTab extends StatefulWidget {
  final AppState st;
  const _SingersTab({required this.st});

  @override
  State<_SingersTab> createState() => _SingersTabState();
}

class _SingersTabState extends State<_SingersTab> {
  final _scroll = ScrollController();
  final _singers = <SingerBrief>[];

  /// 当前筛选项的**下标**（不是取值）。存下标而非取值，让列表渲染和
  /// 「选中态判断」都退化成下标比较，不必到处查表。
  int _areaIdx = 0; // kSingerAreas 下标
  int _sexIdx = 0; // kSingerSexes 下标

  /// 当前首字母：服务端 index 取值（-100 热门 / 1..26 = A-Z / 27 = #）。
  int _indexId = kSingerIndexHot;

  /// 索引条**按住拖动**时的高亮项。非 null 即表示正在拖。
  ///
  /// 拖动过程只更新它、**不发请求**：手指划过 26 个字母就是 26 次请求。
  /// 只有抬手才由 `onCommit` 提交——这既是 iOS 通讯录的手感，
  /// 也是必要的节流。
  ///
  /// ## 为什么是 [ValueNotifier] 而不是 `int?` + `setState`
  /// 这一项的变化频率是「手指每滑过一个字母一次」。用 `setState` 的话，
  /// 每一次都要重建整个歌手库 tab（两个横向筛选行 + 100 行的 ListView
  /// + 索引条本身 + 气泡），手指快速划过时就是连续掉帧——用户报的
  /// 「UI 切换卡顿迟滞」里有一部分就是它。改成 [ValueNotifier] 后，
  /// 重建范围收窄到**索引条与气泡这两个小组件**。
  final _dragId = ValueNotifier<int?>(null);

  int _page = 1;
  bool _hasMore = false;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _dragId.dispose();
    super.dispose();
  }

  /// 当前筛选签名。任一维度变化都会换掉 [_RemoteView] 的 key —— 重挂即重建
  /// Future，等价于「回到第一页重新加载」，不需要另写一套 load/reset 状态机。
  String get _sig => '$_areaIdx|$_sexIdx|$_indexId';

  List<int> get _areas => kSingerAreas[_areaIdx].$2;
  int get _sex => kSingerSexes[_sexIdx].$2;

  Future<List<SingerBrief>> _loadFirst() async {
    final qq = widget.st.qq;
    if (qq == null) throw StateError('数据层未接入');
    final first = await qq.fetchSingers(
      page: 1,
      areas: _areas,
      sex: _sex,
      index: _indexId,
    );
    // 首屏数据直接进本地缓存列表，翻页往里追加
    _singers
      ..clear()
      ..addAll(first.singers);
    _page = first.page;
    _hasMore = first.hasMore;
    return _singers;
  }

  void _maybeLoadMore() {
    if (_loadingMore || !_hasMore) return;
    if (_scroll.position.extentAfter < 600) _loadMore();
  }

  Future<void> _loadMore() async {
    final qq = widget.st.qq;
    if (qq == null || _loadingMore || !_hasMore) return;
    _loadingMore = true;
    try {
      final next = await qq.fetchSingers(
        page: _page + 1,
        areas: _areas,
        sex: _sex,
        index: _indexId,
      );
      if (!mounted) return;
      setState(() {
        _page = next.page;
        _hasMore = next.hasMore;
        // 按 mid 去重。多档合并下两条流各自稳定，理论上不会重复；但服务端
        // 重排 / 下架都可能让第 N+1 页里混进第 N 页见过的 mid，而长列表里的
        // 重复项靠肉眼几乎发现不了。代价只有每页一次 Set。
        final seen = _singers.map((s) => s.mid).toSet();
        var added = 0;
        for (final s in next.singers) {
          if (seen.add(s.mid)) {
            _singers.add(s);
            added++;
          }
        }
        // 整页全是重复项 = 这条流已经走到头。此时若还留着 `_hasMore = true`，
        // 触底监听会反复触发却永远拉不到新内容，空转到用户手动离开页面。
        if (added == 0 && next.singers.isNotEmpty) _hasMore = false;
      });
    } catch (_) {
      // 静默失败：翻页失败不打断浏览，滚回顶部或重进可重试。
      // 不做 toast——翻页是增强，报错反而打扰。
    } finally {
      _loadingMore = false;
    }
  }

  /// 切换筛选并重新加载。传 `null` 的维度保持不变。
  ///
  /// ## 切换后必须把滚动位置打回顶部
  /// `ScrollController` 在整个 tab 生命周期里是同一个实例，[_RemoteView]
  /// 换 key 重挂时 ListView 会沿用旧偏移量。换了数据集却停在原偏移，
  /// 用户一进来看到的是「第 7 页的中间」，看起来像列表顺序坏了。
  void _setFilter({int? areaIdx, int? sexIdx, int? indexId}) {
    final changed = (areaIdx != null && areaIdx != _areaIdx) ||
        (sexIdx != null && sexIdx != _sexIdx) ||
        (indexId != null && indexId != _indexId);
    if (!changed) return;
    setState(() {
      if (areaIdx != null) _areaIdx = areaIdx;
      if (sexIdx != null) _sexIdx = sexIdx;
      if (indexId != null) _indexId = indexId;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    return Column(
      children: [
        _FilterRow(
          items: [for (final e in kSingerAreas) e.$1],
          selected: _areaIdx,
          onSelect: (i) => _setFilter(areaIdx: i),
        ),
        _FilterRow(
          items: [for (final e in kSingerSexes) e.$1],
          selected: _sexIdx,
          onSelect: (i) => _setFilter(sexIdx: i),
        ),
        const SizedBox(height: 2),
        Expanded(
          child: Stack(
            children: [
              _RemoteView<List<SingerBrief>>(
                key: ValueKey(_sig),
                load: _loadFirst,
                builder: (context, singers) {
                  if (singers.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.only(top: 36),
                        child: EmptyState(
                          icon: Icons.person_search_outlined,
                          title: '这个组合下没有歌手',
                          message: '换一个地区、类型或首字母再试。',
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    controller: _scroll,
                    physics: const BouncingScrollPhysics(),
                    // 右侧留 26px 给索引条，否则最后一行会被它压住
                    padding: const EdgeInsets.fromLTRB(20, 8, 26, 24),
                    itemCount: singers.length + (_hasMore ? 1 : 0),
                    itemBuilder: (c, i) {
                      if (i >= singers.length) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        );
                      }
                      final s = singers[i];
                      return _SingerRow(
                        singer: s,
                        // 只有「华语」这种多档合并的列表才需要标出每条来自
                        // 内地还是港台。单档筛选时每条都同区，标了是噪音。
                        showAreaTag: _areas.length > 1,
                        onTap: () => _openSinger(st, s),
                      );
                    },
                  );
                },
              ),
              Positioned(
                top: 6,
                bottom: 6,
                right: 0,
                width: 26,
                // 只有索引条自己跟着 [_dragId] 重建（见该字段的说明）
                child: ValueListenableBuilder<int?>(
                  valueListenable: _dragId,
                  builder: (_, drag, __) => _IndexBar(
                    items: _kSingerIndexBar,
                    currentId: drag ?? _indexId,
                    onHover: (id) {
                      if (id != _dragId.value) _dragId.value = id;
                    },
                    onCommit: (id) {
                      _dragId.value = null;
                      _setFilter(indexId: id);
                    },
                  ),
                ),
              ),
              // 气泡：树形状**恒定**（原先写 `if (_dragId != null) Positioned(...)`
              // 会随拖动插入 / 移除子树，虽然 Stack 能处理，但每帧都要
              // 重挂 element）。这里改成常驻 + 内部按值切换，
              // 拖动开始 / 结束时不再有 element 装卸。
              Positioned.fill(
                child: IgnorePointer(
                  child: ValueListenableBuilder<int?>(
                    valueListenable: _dragId,
                    builder: (_, drag, __) {
                      if (drag == null) return const SizedBox.shrink();
                      return Center(
                        child: _IndexBubble(
                          label: _kSingerIndexBar
                              .firstWhere((e) => e.$1 == drag,
                                  orElse: () => (kSingerIndexHot, '热'))
                              .$2,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _openSinger(AppState st, SingerBrief s) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BrowseScreen.singer(st, s),
    ));
  }
}

/// 一行筛选胶囊（地区 / 类型共用）。
///
/// 选中态用品牌色实底 —— 与「歌单推荐」的排序切换保持同一套视觉，
/// 用户在目录的各 tab 之间来回切时不必重新学一遍。
class _FilterRow extends StatelessWidget {
  final List<String> items;
  final int selected;
  final ValueChanged<int> onSelect;

  const _FilterRow({
    required this.items,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return SizedBox(
      height: 34,
      child: ListView.separated(
        // 横向可滚：现在最多 5 项放得下，但服务端 tags 随时可能增档，
        // 到时候不该整行溢出，而应该能滑。
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (c, i) {
          final on = i == selected;
          return GestureDetector(
            onTap: () => onSelect(i),
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                decoration: BoxDecoration(
                  color: on
                      ? Tokens.brand
                      : (dark ? Tokens.surface2Dark : Tokens.surface),
                  borderRadius: BorderRadius.circular(Tokens.rFull),
                  border: Border.all(
                    color: on
                        ? Tokens.brand
                        : (dark ? Tokens.lineDark : Tokens.line),
                  ),
                ),
                child: Text(
                  items[i],
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                    color: on ? Colors.white : t.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 索引条命中计算：把条上的**本地 y 坐标**映射成「第几项」。
///
/// 抽成顶层纯函数而不是留在手势回调里，是因为这条公式有真实的边界：
/// 手指划出条子外（`dy < 0` 或 `dy > height`）必须夹住到首 / 末项，
/// 否则会 `RangeError` 直接把页面打崩。手势回调很难在组件测试里
/// 精确复现这些坐标，纯函数一行断言就能覆盖。
///
/// [height] 为 0（首帧未布局）或 [count] 非法时返回 0 —— 返回第一项
/// 而不是抛异常：命中失败最多是「选了第一个字母」，崩掉是整个 tab 白屏。
int singerIndexBarHit(double dy, double height, int count) {
  if (height <= 0 || count <= 0) return 0;
  return (dy / height * count).floor().clamp(0, count - 1);
}

/// 右侧竖直首字母索引条（`热` + `#` + A..Z）。
///
/// ## 交互：按下即定位、抬起才生效
/// 拖动过程中逐帧回调 [onHover]（只改高亮 + 气泡），抬手才回调 [onCommit]
/// 真正切数据。若在拖动中切数据，划一次字母条会打出十几次分页请求。
///
/// ## 命中计算为什么用 [Expanded] 而不是 `spaceEvenly`
/// 每项都套 `Expanded`，第 i 项严格占据 `[i*h/n, (i+1)*h/n)`，
/// 「本地 y 坐标 → 第几项」就是一个精确的除法。用 `spaceEvenly` 让
/// 文字视觉居中但分的间距是「间隙」，需要再加回半格偏移，容易差一位。
class _IndexBar extends StatefulWidget {
  final List<(int, String)> items;
  final int currentId;
  final ValueChanged<int> onHover;
  final ValueChanged<int> onCommit;

  const _IndexBar({
    required this.items,
    required this.currentId,
    required this.onHover,
    required this.onCommit,
  });

  @override
  State<_IndexBar> createState() => _IndexBarState();
}

class _IndexBarState extends State<_IndexBar> {
  /// 本次手势最后一次命中的项。
  ///
  /// 不用父组件传进来的 `currentId` 收尾：`setState` 触发的重建是**异步**的，
  /// 抬手事件有可能先于重建到达，那时闭包里的 `currentId` 还是拖动开始时的值，
  /// 会出现「拖到 W 抬手却跳到 A」。在自己这一层记，就没有这个时间差。
  int? _lastId;

  void _pick(double dy, double h) {
    final i = singerIndexBarHit(dy, h, widget.items.length);
    final id = widget.items[i].$1;
    _lastId = id;
    widget.onHover(id);
  }

  void _commit() {
    final id = _lastId;
    _lastId = null;
    if (id != null) widget.onCommit(id);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);

    // 用 LayoutBuilder 拿到真实高度再交给手势闭包，而不是在回调里读
    // `context.size`——手势回调发生在布局之后，读到的可能是新一帧的尺寸。
    return LayoutBuilder(
      builder: (context, c) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _pick(d.localPosition.dy, c.maxHeight),
        onTapUp: (_) => _commit(),
        onTapCancel: () => _lastId = null,
        onVerticalDragStart: (d) => _pick(d.localPosition.dy, c.maxHeight),
        onVerticalDragUpdate: (d) => _pick(d.localPosition.dy, c.maxHeight),
        onVerticalDragEnd: (_) => _commit(),
        onVerticalDragCancel: () => _lastId = null,
        child: Column(
          children: [
            for (final e in widget.items)
              Expanded(
                child: Center(
                  child: Text(
                    e.$2,
                    style: TextStyle(
                      fontSize: 9.5,
                      height: 1,
                      fontWeight: e.$1 == widget.currentId
                          ? FontWeight.w800
                          : FontWeight.w500,
                      color: e.$1 == widget.currentId
                          ? Tokens.brand
                          : t.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 拖动索引条时的大字气泡。手指会盖住索引条本身，
/// 不给反馈用户就不知道自己停在哪一档。
class _IndexBubble extends StatelessWidget {
  final String label;
  const _IndexBubble({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76,
      height: 76,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Tokens.brand,
        borderRadius: BorderRadius.circular(Tokens.rXl),
        boxShadow: [
          BoxShadow(
            color: Tokens.brand.withValues(alpha: 0.35),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 34,
          fontWeight: FontWeight.w800,
          color: Colors.white,
          height: 1,
        ),
      ),
    );
  }
}

class _SingerRow extends StatelessWidget {
  final SingerBrief singer;

  /// 是否在行尾显示「内地 / 港台」标签。仅在多档合并的列表里为 true。
  final bool showAreaTag;
  final VoidCallback onTap;

  const _SingerRow({
    required this.singer,
    required this.onTap,
    this.showAreaTag = false,
  });

  /// 由「这条记录来自哪一档」反查地区标签。
  ///
  /// 用 [kSingerSubAreaLabels] 而不是遍历 [kSingerAreas]：后者把内地与港台
  /// 合成了一项「华语」，没有 `[200]` / `[2]` 单项，反查恒为 `null`
  /// （真机装机验证时正是这个 bug：列表混排对了，标签一个都不显示）。
  /// 查不到就返回 null —— 不显示，也不凭空造一个假的地区名。
  static String? _areaTagOf(int areaId) => kSingerSubAreaLabels[areaId];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final tag = showAreaTag ? _areaTagOf(singer.areaId) : null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tokens.rSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            _SingerAvatar(singer: singer, dark: dark),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    singer.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                  if (singer.otherName.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    Text(
                      singer.otherName,
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
            // 地区标签只在「华语」档出现：那里内地的和港台的混在一列里，
            // 不标的话用户看不出为什么周杰伦排在薛之谦后面。
            if (tag != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: dark ? Tokens.surface2Dark : Tokens.surface,
                  borderRadius: BorderRadius.circular(Tokens.rFull),
                  border:
                      Border.all(color: dark ? Tokens.lineDark : Tokens.line),
                ),
                child: Text(
                  tag,
                  style: TextStyle(
                    fontSize: 9.5,
                    color: t.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: t.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// 歌手头像：真实头像优先，退化到首字母圆片。
///
/// 旧接口不提供头像，列表只能画首字母；新版接口的 `singer_pic` 有真图
/// （150×150 webp，约 6.5 KB）。但**兜底不是可选装饰，是会被真实触发的分支**：
/// 服务端对每个歌手都返回 URL，CDN 上没照片的却会 404
/// （2026-09-30 抽样：热门档 24/24 有图，冷门字母档只有 6/24）。
///
/// 所以两条退化路径都要留：
///   1. `pic` 为空串 → 直接画首字母
///   2. `pic` 有值但加载失败（404 / 超时）→ `errorBuilder` 兜住
/// 只做第 1 条的话，翻到冷门字母档会满屏破图。
class _SingerAvatar extends StatelessWidget {
  final SingerBrief singer;
  final bool dark;

  const _SingerAvatar({required this.singer, required this.dark});

  @override
  Widget build(BuildContext context) {
    // 用 runes 取首字符而不是 substring(0,1)：后者会把代理对（emoji 等）
    // 从中间切开，渲染成乱码方块。
    final initial = singer.name.isEmpty
        ? '#'
        : String.fromCharCode(singer.name.runes.first);

    Widget letter() => Center(
          child: Text(
            initial.toUpperCase(),
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Tokens.brand,
            ),
          ),
        );

    return Container(
      width: 40,
      height: 40,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: dark ? Tokens.surface2Dark : Tokens.surface,
        shape: BoxShape.circle,
        border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
      ),
      child: singer.pic.isEmpty
          ? letter()
          : CachedNetworkImage(
              imageUrl: singer.pic,
              fit: BoxFit.cover,
              // 内存解码尺寸（取代 Image.network.cacheWidth）：按实际显示尺寸解码，
              // 40dp 头像 × 设备像素比，避免 150×150 原图整个展开常驻内存。
              memCacheWidth:
                  (40 * MediaQuery.devicePixelRatioOf(context)).round(),
              // 淡入时长为 0 = 保持已加载帧不淡出，等效 gaplessPlayback:true。
              fadeInDuration: Duration.zero,
              errorWidget: (_, __, ___) => letter(),
            ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Tab 2：歌单推荐（双列封面网格 + 推荐/最新切换）
// ═══════════════════════════════════════════════════════════════

class _PlaylistsTab extends StatefulWidget {
  final AppState st;
  const _PlaylistsTab({required this.st});

  @override
  State<_PlaylistsTab> createState() => _PlaylistsTabState();
}

class _PlaylistsTabState extends State<_PlaylistsTab> {
  int _sortId = 5; // kPlaylistSorts 里的「推荐」

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return Column(
      children: [
        // 排序切换。只放两档——实测接口只有这两档真的不同
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(
            children: [
              for (final (id, label) in kPlaylistSorts) ...[
                if (id != _sortId) const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    if (id == _sortId) return;
                    setState(() => _sortId = id);
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                    decoration: BoxDecoration(
                      color: id == _sortId
                          ? Tokens.brand
                          : (dark ? Tokens.surface2Dark : Tokens.surface),
                      borderRadius: BorderRadius.circular(Tokens.rFull),
                      border: Border.all(
                        color: id == _sortId
                            ? Tokens.brand
                            : (dark ? Tokens.lineDark : Tokens.line),
                      ),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: id == _sortId
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: id == _sortId
                            ? Colors.white
                            : t.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: _RemoteView<List<PlaylistBrief>>(
            key: ValueKey(_sortId),
            load: () async {
              final qq = st.qq;
              if (qq == null) throw StateError('数据层未接入');
              return qq.fetchPlaylists(sortId: _sortId);
            },
            builder: (context, playlists) {
              return GridView.builder(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 14,
                  childAspectRatio: 0.86,
                ),
                itemCount: playlists.length,
                itemBuilder: (c, i) =>
                    _PlaylistCard(brief: playlists[i], onTap: () {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => BrowseScreen.playlist(st, playlists[i]),
                  ));
                }),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  final PlaylistBrief brief;
  final VoidCallback onTap;

  const _PlaylistCard({required this.brief, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tokens.rLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(Tokens.rLg),
                    child: brief.cover.isEmpty
                        ? CoverArt(
                            seed: brief.dissId.hashCode,
                            size: 200,
                            radius: 0,
                          )
                        : CachedNetworkImage(
                            imageUrl: brief.cover,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => CoverArt(
                              seed: brief.dissId.hashCode,
                              size: 200,
                              radius: 0,
                            ),
                          ),
                  ),
                ),
                // 收听数角标
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(Tokens.rFull),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.headphones_rounded,
                            size: 10, color: Colors.white),
                        const SizedBox(width: 3),
                        Text(
                          _listenText(brief.listenNum),
                          style: const TextStyle(
                            fontSize: 9.5,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 7),
          Text(
            brief.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, height: 1.35),
          ),
          const SizedBox(height: 2),
          Text(
            brief.creator,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  static String _listenText(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }
}

// ═══════════════════════════════════════════════════════════════
// Tab 3：榜单（分组展示 + 卡片带预览）
// ═══════════════════════════════════════════════════════════════

class _ToplistsTab extends StatelessWidget {
  final AppState st;
  const _ToplistsTab({required this.st});

  @override
  Widget build(BuildContext context) {
    return _RemoteView<List<ToplistGroup>>(
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

// ═══════════════════════════════════════════════════════════════
// Tab 4：新歌推荐（巅峰榜·新歌，直接铺歌单行）
// ═══════════════════════════════════════════════════════════════

class _NewSongsTab extends StatelessWidget {
  final AppState st;
  const _NewSongsTab({required this.st});

  @override
  Widget build(BuildContext context) {
    return _RemoteView<ToplistDetail>(
      load: () async {
        final qq = st.qq;
        if (qq == null) throw StateError('数据层未接入');
        return qq.fetchToplistDetail(kNewSongTopId);
      },
      builder: (context, detail) {
        final items = detail.songs.map(asOnlineSong).toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      detail.updateTime.isEmpty
                          ? '${items.length} 首新歌'
                          : '${items.length} 首新歌 · 更新于 ${detail.updateTime}',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  // 播放全部
                  TextButton.icon(
                    onPressed:
                        items.isEmpty ? null : () => st.playOnline(items, 0),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('播放全部',
                        style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      foregroundColor: Tokens.brand,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                itemCount: items.length,
                itemBuilder: (c, i) {
                  final s = items[i].song;
                  return BrowseSongRow(
                    rank: i + 1,
                    song: s,
                    currentKey: st.current?.key,
                    onTap: () => st.playOnline(items, i),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
