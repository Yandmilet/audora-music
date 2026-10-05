import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/settings/settings_store.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'bili_login_page.dart';
import 'diag_log_page.dart';

class MineScreen extends StatelessWidget {
  final AppState st;
  const MineScreen({super.key, required this.st});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final liked = st.library.where(st.isLiked).toList();

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
                // 「最近听」取代原「歌曲」（曲库列表不再是用户入口，
                // 曲库规模对用户没有意义，最近听过几首才是真的）
                _Stat(value: '${st.recentlyPlayed.length}', label: '最近听'),
                _divider(dark),
                _Stat(value: '${st.likedCount}', label: '收藏'),
                _divider(dark),
                _Stat(value: '${st.topPlayed.length}', label: '常听'),                ],
              ),
            ),
          ),

          // 入口卡
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: _EntryCard(
                    icon: Icons.favorite_rounded,
                    title: '收藏',
                    subtitle: '${st.likedCount} 首',
                    color: Tokens.brand,
                    onTap: () => _openList(context, '收藏', liked),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  // 原「曲库」入口 → 「最近听」。曲库列表已不再是产品入口，
                  // 这里展示按最后收听时间倒序、已按歌去重的播放记录。
                  child: _EntryCard(
                    icon: Icons.history_rounded,
                    title: '最近听',
                    subtitle: '${st.recentlyPlayed.length} 首',
                    color: const Color(0xFF0EA5A4),
                    onTap: () =>
                        _openList(context, '最近听', st.recentlyPlayed),
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
                  _SettingRow(
                    icon: Icons.high_quality_rounded,
                    title: '音质偏好',
                    // ⚠️ 这里必须展示真实生效的值。写成常量 '192Kbps' 时
                    // 用户改了设置看不出变化，等同于假开关。
                    trailing: st.quality.label,
                    onTap: () => _pickQuality(context, st),
                  ),
                  _SettingRow(
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
                  _SettingRow(
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
                  _SettingRow(
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
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Center(
              child: Text(
                'Audora 2.0 · 个人自用 · 基于 Flutter',
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

  /// 音质偏好选择。
  ///
  /// 用底部弹层而不是普通对话框：选项带说明文字（流量代价），
  /// 需要更多纵向空间，弹层也更符合移动端「选一个值」的习惯。
  Future<void> _pickQuality(BuildContext context, AppState st) async {
    final picked = await showModalBottomSheet<QualityPreference>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final t = Theme.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text('音质偏好',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800)),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  '设为上限：该档位没有可用音源时会自动放宽，不会静默无声。'
                  '正在播放时立即换档并保留进度。',
                  style: TextStyle(fontSize: 11.5),
                ),
              ),
              for (final q in QualityPreference.values)
                ListTile(
                  leading: Icon(
                    st.quality == q
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: st.quality == q
                        ? Tokens.brand
                        : t.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(q.label, style: const TextStyle(fontSize: 13.5)),
                  subtitle: Text(q.desc,
                      style: const TextStyle(fontSize: 11.5)),
                  onTap: () => Navigator.of(ctx).pop(q),
                ),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
    if (picked == null) return;
    await st.setQuality(picked);
  }

  Widget _divider(bool dark) => Container(
        width: 1,
        height: 26,
        color: dark ? Tokens.lineDark : Tokens.line,
      );

  void _openList(BuildContext context, String title, List<Song> songs) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _SongListPage(title: title, songs: songs, st: st),
    ));
  }

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

class _EntryCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _EntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tokens.rLg),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        decoration: BoxDecoration(
          color: dark ? Tokens.surfaceDark : Tokens.surface,
          borderRadius: BorderRadius.circular(Tokens.rLg),
          border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: dark ? 0.2 : 0.12),
                borderRadius: BorderRadius.circular(Tokens.rSm),
              ),
              child: Icon(icon, size: 19, color: color),
            ),
            const SizedBox(height: 11),
            Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(fontSize: 11, color: t.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? trailing;
  /// null 表示禁用（导入/匹配进行中），此时灰显且不可点
  final VoidCallback? onTap;
  final bool isLast;

  const _SettingRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.onTap,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final enabled = onTap != null;

    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.45,
        child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: isLast
              ? null
              : Border(
                  bottom: BorderSide(color: dark ? Tokens.lineDark : Tokens.line),
                ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 19, color: t.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                  // 副标题用来把「这个开关会带来什么代价」讲清楚，
                  // 否则用户只看到「自动匹配」不知道会打接口
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 11,
                        color: t.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              Text(
                trailing!,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: t.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: t.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
        ),
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

/// 通用歌曲列表页（收藏 / 最近听共用）
class _SongListPage extends StatelessWidget {
  final String title;
  final List<Song> songs;
  final AppState st;

  const _SongListPage({
    required this.title,
    required this.songs,
    required this.st,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
        elevation: 0,
      ),
      body: SwipeBack(
        onBack: () => Navigator.of(context).maybePop(),
        child: songs.isEmpty
            ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.inbox_rounded,
                    size: 48,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '暂无内容',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              itemCount: songs.length,
              itemBuilder: (c, i) {
                final s = songs[i];
                return SongRow(
                  song: s,
                  leading: CoverArt(seed: s.coverSeed, size: 46, radius: Tokens.rSm),
                  subtitle: '${s.artist} · ${s.album}',
                  showDuration: false,
                  trailing: s.sourceStatus != SourceStatus.ok
                      ? SourceBadge(status: s.sourceStatus, compact: true)
                      : null,
                  onTap: () => st.playSong(s, source: songs),
                );
              },
            ),
      ),
    );
  }
}

