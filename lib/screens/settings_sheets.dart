/// 设置区里那两组「一件事好几个值」的编辑界面。
///
/// ## 为什么单独一个文件
/// 「我的」页本来有 7 行设置，用户反馈是**太多**。压到 5 行的做法不是删功能，
/// 而是把同一件事的多个取值收进一个入口：
///   - 在线音质 + 下载音质 → 一个「音质偏好」弹窗（两条上限**依然各自独立**，
///     只是不再各占一行。分开存的产品理由见 [QualityPreference] 的说明，
///     合并入口不等于合并偏好）
///   - 本地目录 + 下载目录 → 一个「歌曲目录」子页面（这里必须是页面不是弹窗：
///     点一行要拉起系统选择器，弹窗压在下面会被选择器盖掉、返回时还被销毁，
///     用户在魅族 21 上遇到的「点了没反应」有一半就是这么来的）
/// 顺手把 [AppState.dirsNote]（授权失效 / 不可写 / 平台不支持）显示出来——
/// 这个状态以前只存在 getter 里，界面上从没露过面。
library;

import 'package:flutter/material.dart';

import '../services/settings/settings_store.dart';
import '../state/app_state.dart';
import '../state/music_dirs.dart';
import '../theme.dart';

/// 设置区的一行（图标 + 标题 + 可选副标题 + 可选尾串 + 右箭头）。
class SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? trailing;

  /// null 表示不可点（灰显）。
  final VoidCallback? onTap;
  final bool isLast;

  /// 尾串右侧的附加控件（「歌曲目录」页用它放「清除」）。
  final Widget? trailingWidget;

  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.trailingWidget,
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
                    bottom:
                        BorderSide(color: dark ? Tokens.lineDark : Tokens.line),
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
                    // 否则用户只看到「音质偏好」不知道里面能改几样
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
                Flexible(
                  child: Text(
                    trailing!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: t.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (trailingWidget != null) ...[
                const SizedBox(width: 4),
                trailingWidget!,
              ],
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

/// 「音质偏好」弹窗：在线与下载两条上限一次改完。
Future<void> showQualityPrefsSheet(BuildContext context, AppState st) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => QualityPrefsSheet(st: st),
    );

class QualityPrefsSheet extends StatefulWidget {
  final AppState st;
  const QualityPrefsSheet({super.key, required this.st});

  @override
  State<QualityPrefsSheet> createState() => _QualityPrefsSheetState();
}

class _QualityPrefsSheetState extends State<QualityPrefsSheet> {
  @override
  void initState() {
    super.initState();
    // 选完一档要立刻看到圆点跳过去。弹窗挂在根 Navigator 上，
    // 不自己订阅就只能等外层整树重建，那不可靠。
    widget.st.addListener(_rebuilt);
  }

  @override
  void dispose() {
    widget.st.removeListener(_rebuilt);
    super.dispose();
  }

  void _rebuilt() {
    if (mounted) setState(() {});
  }

  Future<void> _pick({required bool online, required QualityPreference q}) async {
    if (online) {
      await widget.st.setOnlineQuality(q);
    } else {
      await widget.st.setDownloadQuality(q);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    return SafeArea(
      // 六个选项 + 两段说明在小屏上会超过半屏，给一个可滚的上限
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('音质偏好',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(
                '在线和下载是两条独立上限：在线只管这次拉流要多少流量，'
                '下载只管落到手机上的文件留多大。',
                style: TextStyle(
                    fontSize: 11.5, height: 1.5, color: _hint(context)),
              ),
              _section(
                context,
                title: '在线音质',
                explain: '设为上限：该档位没有可用音源时会自动放宽，'
                    '不会静默无声。正在播放时立即换档并保留进度。',
                current: st.onlineQuality,
                onPick: (q) => _pick(online: true, q: q),
              ),
              const Divider(height: 26),
              _section(
                context,
                title: '下载音质',
                explain: '决定存到手机上的文件用哪一档码率。'
                    '档位越高越清晰，占的存储也越大。',
                current: st.downloadQuality,
                onPick: (q) => _pick(online: false, q: q),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(
    BuildContext context, {
    required String title,
    required String explain,
    required QualityPreference current,
    required Future<void> Function(QualityPreference) onPick,
  }) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(explain, style: TextStyle(fontSize: 11, height: 1.45, color: _hint(context))),
        const SizedBox(height: 4),
        // 展示顺序按用户给的来（标准 → 高品质 → 自动），
        // 不跟着枚举声明顺序走（见 kQualityChoices）。
        for (final q in kQualityChoices)
          RadioListTile<QualityPreference>(
            value: q,
            groupValue: current,
            onChanged: (v) {
              if (v != null) onPick(v);
            },
            dense: true,
            contentPadding: EdgeInsets.zero,
            visualDensity: const VisualDensity(vertical: -1),
            activeColor: Tokens.brand,
            title: Text(q.label, style: const TextStyle(fontSize: 13.5)),
            subtitle: Text(q.desc,
                style: TextStyle(fontSize: 11, color: t.colorScheme.onSurfaceVariant)),
          ),
      ],
    );
  }

  Color _hint(BuildContext context) =>
      Theme.of(context).colorScheme.onSurfaceVariant;
}

/// 「歌曲目录」子页面：本地扫描范围 + 下载落点，两项都在这一页里选与清。
class MusicDirsPage extends StatefulWidget {
  final AppState st;
  const MusicDirsPage({super.key, required this.st});

  @override
  State<MusicDirsPage> createState() => _MusicDirsPageState();
}

class _MusicDirsPageState extends State<MusicDirsPage> {
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    widget.st.addListener(_rebuilt);
  }

  @override
  void dispose() {
    widget.st.removeListener(_rebuilt);
    super.dispose();
  }

  void _rebuilt() {
    if (mounted) setState(() {});
  }

  /// 结果与失败原因一律显示出来。
  ///
  /// 用本页 Scaffold 的 SnackBar 而不是全局 toast：这一页是 push 出来的
  /// 路由，全局提示挂在 Shell 层（见 shell.dart），会被这一页整个盖住——
  /// 那正好又变成用户报过的「点了没反应」。与 `local_screens.dart` 的扫描
  /// 走同一条可见路径，别再制造第二种「说了但看不见」的实现。
  void _say(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _pick(MusicDirKind kind) async {
    final msg = await widget.st.pickMusicDir(kind);
    if (!mounted || msg == null) return; // null = 用户取消，静默是对的
    _say(msg);
  }

  Future<void> _clear(MusicDirKind kind) async {
    final msg = await widget.st.clearMusicDir(kind);
    if (!mounted) return;
    _say(msg ?? (kind == MusicDirKind.local
        ? '已清除本地目录，扫描回到全盘'
        : '已清除下载目录，下载前需要重选'));
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    final msg = await widget.st.scanLocalAudio();
    if (!mounted) return;
    setState(() => _scanning = false);
    _say(msg ?? '扫描完成：本机歌曲 ${widget.st.localCount} 首');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final st = widget.st;

    return Scaffold(
      backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
      appBar: AppBar(
        title: const Text('歌曲目录',
            style: TextStyle(fontWeight: FontWeight.w800)),
        backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
        elevation: 0,
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          Text(
            '两个目录是两件事，互不回退：本地是**扫描范围**（只读，把手机里已有的歌找出来），'
            '下载是**写入位置**。合成一个的话，下载的歌会被下次扫描再收一遍。',
            style: TextStyle(
                fontSize: 11.5, height: 1.6, color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          // 授权失效 / 不可写 / 平台不支持——这些状态以前只能藏在 getter 里
          if (st.dirsNote != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF4E5),
                borderRadius: BorderRadius.circular(Tokens.rSm),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 17, color: Color(0xFFB26A00)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      st.dirsNote!,
                      style: const TextStyle(
                          fontSize: 11.5, height: 1.45, color: Color(0xFF6B4A1B)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          Container(
            decoration: BoxDecoration(
              color: dark ? Tokens.surfaceDark : Tokens.surface,
              borderRadius: BorderRadius.circular(Tokens.rLg),
              border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final kind in MusicDirKind.values)
                  SettingsRow(
                    icon: kind == MusicDirKind.local
                        ? Icons.folder_outlined
                        : Icons.drive_folder_upload_outlined,
                    title: MusicDirsBox.labelOf(kind),
                    subtitle: st.musicDirSubtitle(kind),
                    trailing: st.musicDirTrailing(kind),
                    trailingWidget: st.musicDirSet(kind)
                        ? InkWell(
                            onTap: () => _clear(kind),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              child: Text(
                                '清除',
                                style: TextStyle(
                                    fontSize: 11.5, color: Tokens.brand),
                              ),
                            ),
                          )
                        : null,
                    // 没设过 = 直接去选；已经设过 = 同一行就是「换一个」，
                    // 想退回未设置点右侧「清除」。少一层中间弹窗。
                    onTap: () => _pick(kind),
                    isLast: kind == MusicDirKind.download,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Text(
            '本机歌曲',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: dark ? Tokens.surfaceDark : Tokens.surface,
              borderRadius: BorderRadius.circular(Tokens.rLg),
              border: Border.all(color: dark ? Tokens.lineDark : Tokens.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: SettingsRow(
              icon: Icons.refresh_rounded,
              title: '扫描手机音乐',
              // 清单里已经有歌就别再说「还没扫过」：lastScanAt 只记
              // 本机这次进程里成功扫的时刻，重启后为 0，而清单是落库的。
              subtitle: st.localCount == 0 && st.lastLocalScanAt == 0
                  ? '还没扫过；扫描范围跟着上面的本地目录走'
                  : '已扫到 ${st.localCount} 首，可重复扫描',
              trailing: _scanning ? '扫描中…' : null,
              onTap: _scanning ? null : _scan,
              isLast: true,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '扫描需要「音乐」读取权限。没扫到歌时先去系统设置里确认权限，'
            '再看本地目录是不是选得太窄。',
            style: TextStyle(fontSize: 11, height: 1.5, color: _hint(t)),
          ),
        ],
      ),
    );
  }

  Color _hint(ThemeData t) => t.colorScheme.onSurfaceVariant;
}
