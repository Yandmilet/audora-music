/// 在线搜索（QQ音乐四分类）：关键词 / 历史 / 结果 / 竞态防护 / 导入进度。
///
/// ## 为什么从 AppState 拆出来（P3 组合式拆分，**不是** part 文件）
/// 自洽叶子模块：只依赖 catalog（搜索接口）、repo（导入落库）与两个回调
/// （onImported 导入后刷新曲库、onChange 通知外层），不碰播放/曲库核心。
/// AppState 保留同名转发，search_screen 的 st.query / st.searchResults
/// 等用法完全不变。
library;

import 'dart:async';

import '../data/repository/library_repository.dart';
import '../services/qqmusic/qqmusic_dto.dart';
import '../services/qqmusic/qqmusic_provider.dart';

class OnlineSearchBox {
  OnlineSearchBox({
    required QQMusicProvider? Function() catalog,
    required LibraryRepository? Function() repo,
    required Future<void> Function() onImported,
    required void Function() onChange,
  })  : _catalog = catalog,
        _repo = repo,
        _onImported = onImported,
        _onChange = onChange;

  final QQMusicProvider? Function() _catalog;
  final LibraryRepository? Function() _repo;
  final Future<void> Function() _onImported;
  final void Function() _onChange;

  /// 搜索词只用于驱动「在线搜 QQ 音乐」。
  ///
  /// 曲库作为独立概念已删除（QQ 音乐元数据即曲库，音源在播放页匹配），
  /// 不再有本地库搜索：输入即想搜 QQ 音乐，回车才发请求。
  /// 只记录搜索词，**不发全局通知**（性能修复，别把 onChange 加回来）。
  ///
  /// ## 为什么不通知
  /// 打字是最高频的交互，而全局通知会走根 AnimatedBuilder →
  /// MaterialApp → Shell → HomeScreen/MineScreen 整树重建——每敲一个键
  /// 歌手库 4 个 tab 全部重画，只为更新搜索框旁边那个清除按钮。
  /// 输入框有自己的 TextEditingController，需要响应「有没有输入」的
  /// 只有搜索页自己：它监听 controller 局部 setState（见
  /// _SearchScreenState._onQueryChanged），重建范围从整棵树缩到搜索层。
  /// 本字段只在 [commit] / [search] 的入参兜底里被读。
  void setQuery(String q) {
    query = q;
  }

  String query = '';

  /// 搜索历史：数据层未接入时用 mock 的示例词，真实运行时从空开始
  final List<String> history = [];

  /// 综合搜索结果（四分类：歌曲 / 歌手 / 专辑 / 歌单）。
  ///
  /// 歌曲从 QQ 音乐搜索接口直接返回；歌手 / 专辑从歌曲结果中
  /// 按 mid 去重提取（QQ 音乐无公开可用的歌手 / 专辑搜索端点）。
  /// 歌单暂空（无公开接口）。
  QQSearchResults results = const QQSearchResults();
  bool searching = false;
  bool searched = false;
  String? error;

  /// 在线搜索的请求序号（竞态防护）。
  ///
  /// 搜索请求在途时用户可以再按一次回车（关键词已改），两个请求并发
  /// 在途——慢的旧请求若后返回，会把新结果覆盖成旧词的结果。
  /// 每次发起搜索自增，返回时序号不是最新即丢弃。
  int _seq = 0;

  /// 导入状态文案（导入中显示，导入完成后保留结果供用户查看）
  String? importMessage;
  bool importing = false;

  /// 在线搜索结果（歌曲 tab 用，带真实 songMid）。
  ///
  /// 从 [results.songs] 转换为 OnlineSong——保留这个 getter 是为了
  /// 兼容既有代码路径。歌手 / 专辑 / 歌单分类请直接用
  /// `results.singers` 等。
  List<OnlineSong> get onlineResults => results.songs
      .map((m) => OnlineSong(
            song: m.toSong(),
            songMid: m.songMid,
            albumMid: m.albumMid,
            singerMid: m.singerMid,
            singerId: m.singerId,
          ))
      .toList();

  /// 回车确认：记历史 + 发一次远端请求。
  void commit(String q) {
    if (q.trim().isEmpty) return;
    history.remove(q);
    history.insert(0, q);
    if (history.length > 8) history.removeLast();
    query = q;
    _onChange();
    // 回车 = 明确意图，这时候才值得花一次远端请求。
    unawaited(search(q));
  }

  void clearHistory() {
    history.clear();
    _onChange();
  }

  /// 手动触发一次在线搜索（四分类综合搜索）。
  ///
  /// 调用 QQ 音乐搜索接口翻页获取歌曲，然后从歌曲结果中按
  /// mid 去重提取歌手和专辑，一起返回 [QQSearchResults]。
  ///
  /// ## 为什么不跟着 [setQuery] 自动打
  /// 搜索是远端请求（慢、限流），打字时只更新输入框，
  /// 用户**明确按下搜索/回车**才发请求。
  Future<void> search([String? keyword]) async {
    final qq = _catalog();
    final kw = (keyword ?? query).trim();
    if (qq == null || kw.isEmpty) return;

    // 竞态防护：旧请求晚归不能覆盖新请求的结果
    final seq = ++_seq;
    searching = true;
    error = null;
    _onChange();

    try {
      final r = await qq.searchAll(kw);
      if (seq != _seq) return;
      results = r;
      searched = true;
    } catch (e) {
      if (seq != _seq) return;
      results = const QQSearchResults();
      searched = true;
      error = '$e';
    } finally {
      if (seq == _seq) {
        searching = false;
        _onChange();
      }
    }
  }

  /// 把在线搜索选中的条目导入曲库。
  ///
  /// 导入后必须经 [onImported] 刷新曲库——否则用户在「我的」页看到的
  /// 还是旧的，会以为导入没生效。
  Future<String> importSelected(List<OnlineSong> items) async {
    final repo = _repo();
    if (repo == null) return '数据层未接入';
    if (items.isEmpty) return '没有选中的歌曲';

    importing = true;
    importMessage = '正在导入 ${items.length} 首…';
    _onChange();

    try {
      final n = await repo.importOnline(items);
      await _onImported();
      // 导入后这些歌已经从「在线」变成「在库」——
      // 综合搜索结果里暂不做实时查重标记，用户重新搜索即可看到最新状态

      // ⚠️ 提示语必须指向**最短路径**。
      // 点开任意一首就会按需匹配（约 20 秒/首），直接听才是对的。
      importMessage = '已导入 $n 首，点开即自动匹配音源（约 20 秒/首）';
      return importMessage!;
    } catch (e) {
      importMessage = '导入失败：$e';
      return importMessage!;
    } finally {
      importing = false;
      _onChange();
    }
  }

  /// 清空在线搜索结果（关闭搜索页 / 清空输入时）。
  void clearResults() {
    if (results.isEmpty && !searched && error == null) return;
    results = const QQSearchResults();
    searched = false;
    error = null;
    _onChange();
  }

  /// 关闭搜索页时复位关键词与结果（由 AppState 统一发一次通知）。
  void resetOnClose() {
    query = '';
    results = const QQSearchResults();
    searched = false;
    error = null;
  }
}
