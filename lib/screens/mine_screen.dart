import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/music_dirs.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'bili_login_page.dart';
import 'diag_log_page.dart';
import 'local_screens.dart';
import 'settings_sheets.dart';
import 'song_list_page.dart';

/// App 实际版本号 —— 「我的」页底部展示用，必须与 pubspec.yaml 的
/// `version` 一致（不带 `+build` 后缀）。
///
/// 2026-10-11 修：底部原来写死「Audora 2.0」，那是原型设计稿的年代号，
/// 和真实发版号对不上；由常量统一出处，同步校验放在
/// test/mine_footer_test.dart——改版号忘了改这里会直接测试失败。
///
/// 为什么不用 package_info_plus 动态读：为一行展示文案引入平台插件，
/// 全部 widget 测试都要跟着 mock，不值当；版本只随发版变。
const String kAppVersion = '0.2.0';

class MineScreen extends StatelessWidget {
  final AppState st;
  const MineScreen({super.key, required this.st});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    // 设置区从 7 行压到 5 行（2026-10-11 用户反馈「太多」）：
    // 音质两项进一个弹窗，目录两项进一个子页面，功能一个没少。
    final dirsSet = MusicDirKind.values.where(st.musicDirSet).length;

    return Container(
      color: dark ? Tokens.bgDark : Tokens.bg,
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const SizedBox(height: 8),
          // 标题栏
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Text(
              '我的',
              style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -0.4),
            ),
          ),

          // 资料卡
          //
          // B站已登录且有头像 URL 时展示 B站头像 + 昵称；
          // 未登录（或头像拉取失败）保持默认的 Audora 品牌形象。
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(
              children: [
                _BiliAvatar(faceUrl: st.biliUserFace, loggedIn: st.biliLoggedIn),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _displayName(st),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w800),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _sourceLine(st),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: t.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 数据卡
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: dark ? Tokens.surfaceDark : Tokens.surface,
                borderRadius: BorderRadius.circular(Tokens.rLg),
                border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
              ),
              child: Row(
                children: [
                // 「最近听」统计随入口一起挪到首页卡片了（2026-10-11），
                // 这里只留两项：收藏是资产、常听是习惯，都还在本页有出口。
                _Stat(value: '${st.likedCount}', label: '收藏'),
                _divider(dark),
                _Stat(value: '${st.topPlayed.length}', label: '常听'),                ],
              ),
            ),
          ),

          // 入口卡
          //
          // 两张并列：收藏是本机资产，本地是「手机自带 + app 下载」的入口
          // （2026-10-11 第二期：原「最近听」入口已移到首页卡片，这里补上本地）。
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: EntryCard(
                    icon: Icons.favorite_rounded,
                    title: '收藏',
                    subtitle: '${st.likedCount} 首',
                    color: Tokens.brand,
                    // 列表**现查数据库**而不是从曲库窗口里筛：曲库只装最近
                    // 500 行，收藏可以在窗口外——那正是「计数 1 首、点进去
                    // 暂无内容」的成因（2026-10-11 真机复现）。
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => SongListPage(
                        title: '收藏',
                        songs: const [],
                        loader: st.likedSongsList,
                        st: st,
                        emptyText: '还没有收藏\n在播放页点 ♥ 就能收进来',
                      ),
                    )),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: EntryCard(
                    icon: Icons.sd_storage_rounded,
                    title: '本地',
                    subtitle: '${st.localCount + st.downloadCount} 首',
                    color: const Color(0xFF6C5CE7),
                    // 进去是「本地 / 下载」两个并列功能，这里不猜用户要哪个
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => LocalHubPage(st: st),
                    )),
                  ),
                ),
              ],
            ),
          ),

          // 设置区
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
            child: Text(
              '设置',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Container(
              decoration: BoxDecoration(
                color: dark ? Tokens.surfaceDark : Tokens.surface,
                borderRadius: BorderRadius.circular(Tokens.rLg),
                border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  SettingsRow(
                    icon: Icons.tune_rounded,
                    title: '音质偏好',
                    subtitle: '在线与下载各一条上限，互不影响',
                    // ⚠️ 必须展示真实生效的值。写成常量 '192Kbps' 时用户改了
                    // 设置看不出变化，等同于假开关。两项都放进来，省掉两行。
                    trailing:
                        '在线 ${st.onlineQuality.chip} · 下载 ${st.downloadQuality.chip}',
                    onTap: () => showQualityPrefsSheet(context, st),
                  ),
                  SettingsRow(
                    icon: Icons.folder_open_rounded,
                    title: '歌曲目录',
                    subtitle: '本地扫描范围与下载存放位置，分开选',
                    trailing: '已选 $dirsSet/2',
                    // 目录这两项要拉起系统选择器，用子页面而不是弹窗：
                    // 弹窗会被选择器盖掉，返回时还可能被路由销毁。
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => MusicDirsPage(st: st)),
                    ),
                  ),
                  SettingsRow(
                    icon: Icons.qr_code_2_rounded,
                    title: 'B站账号',
                    subtitle: _biliLine(st),
                    trailing: st.biliLoggedIn ? '已登录' : '未登录',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => BiliLoginPage(st: st),
                      ),
                    ),
                  ),
                  SettingsRow(
                    icon: Icons.article_outlined,
                    title: '诊断日志',
                    subtitle: '音源匹配过程、网络风控与崩溃记录',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => DiagLogPage(st: st),
                      ),
                    ),
                  ),
                  // 「曲库状态 / 重新加载曲库 / 导入歌曲」三项已移除：
                  // 曲库规模与加载状态对用户没有可操作意义（库永远是
                  // 「点歌即播」的自动产物），导入入口已被音乐页目录点歌
                  // 取代——留着只会让人以为还有什么需要手动维护。
                  SettingsRow(
                    icon: Icons.history_rounded,
                    title: '清除播放记录',
                    subtitle: '清空最近播放与常听统计',
                    onTap: () => _clearPlayHistory(context, st),
                    isLast: true,
                  ),
                ],
              ),
            ),
          ),

          // 关于
          //
          // 版本号取实际发版号（kAppVersion，与 pubspec 同步校验）；
          // 协议声明与仓库 LICENSE（GPL-3.0）保持一致。
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Center(
              child: Text(
                'Audora v$kAppVersion · 基于 Flutter 开发 · 开源协议 GPL-3.0',
                style: TextStyle(
                  fontSize: 11,
                  color: t.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 资料卡主标题：B站已登录且拿到昵称 → 昵称；否则保持品牌名
  String _displayName(AppState st) {
    if (st.biliLoggedIn && st.biliUserName.isNotEmpty) return st.biliUserName;
    return 'Audora';
  }

  /// B站账号那行的副标题：把「还剩多久 / 要不要重扫」讲清楚。
  ///
  /// 到期不强制登出（服务端可能仍然认这个 SESSDATA），但必须催一次——
  /// 否则用户会以为「登录过就永久有效」，等哪天突然掉回 132K 才察觉。
  String _biliLine(AppState st) {
    if (!st.biliLoggedIn) return '扫码后可解锁 192K / Hi-Res，配额更宽';
    // 服务端明确不认这个凭证了（本地还在，但拿不到登录态收益）
    if (st.biliSessionStale) return '登录态已失效，请重新扫码';
    final days = st.biliCookieDaysLeft ?? 0;
    if (st.biliCookieExpired) return '已超过 30 天，建议重新扫码';
    if (st.biliCookieExpiringSoon) return '还剩 $days 天，可提前续期';
    return '登录态有效（还剩 $days 天）';
  }

  /// 数据来源说明。用 mock 兜底时明确标出来，避免误以为匹配没生效。
  String _sourceLine(AppState st) {
    if (st.loadState == LibraryLoadState.failed) {
      return '数据库不可用，当前为演示数据';
    }
    if (st.usingMock) {
      return '演示数据 · 元数据来自 QQ音乐 · 音源来自 B站';
    }
    return '元数据来自 QQ音乐 · 音源来自 B站';
  }

  /// 清除播放记录（需二次确认——不可撤销）
  Future<void> _clearPlayHistory(BuildContext context, AppState st) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除播放记录？', style: TextStyle(fontSize: 16)),
        content: const Text(
          '会清空「最近播放」和「常听」的统计，无法撤销。',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final msg = await st.clearPlayHistory();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Widget _divider(bool dark) => Container(
        width: 1,
        height: 26,
        color: dark ? Tokens.lineDark : Tokens.line,
      );
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  const _Stat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, height: 1.1),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 资料卡头像：B站已登录且有头像 URL 时显示网络头像，否则品牌渐变圆 + 「A」。
///
/// 网络头像加载失败（断网 / URL 过期 / 明文被禁）时回退品牌形象，
/// 不让资料卡出现破图或空洞。
class _BiliAvatar extends StatelessWidget {
  final String faceUrl;
  final bool loggedIn;

  const _BiliAvatar({required this.faceUrl, required this.loggedIn});

  bool get _showNetwork => loggedIn && faceUrl.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: 58,
      height: 58,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE5484D), Color(0xFFF2708C)],
        ),
      ),
      alignment: Alignment.center,
      child: const Text(
        'A',
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          color: Colors.white,
        ),
      ),
    );

    if (!_showNetwork) return fallback;

    return ClipOval(
      child: SizedBox(
        width: 58,
        height: 58,
        child: CachedNetworkImage(
          imageUrl: faceUrl,
          fit: BoxFit.cover,
          // 加载中先给一个不刺眼的底色，避免透明闪烁
          placeholder: (_, __) => Container(
            color: const Color(0xFFF1F3F7),
          ),
          errorWidget: (_, __, ___) => fallback,
        ),
      ),
    );
  }
}
