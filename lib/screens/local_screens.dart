/// 「本地」这一片：入口页（本地 / 下载 两个并列功能）+ 两份清单页。
///
/// ## 为什么是一个文件两个页面
/// 它们是一组：入口页只负责把人分到正确的清单，清单页只负责一份 kind 的
/// 列表。拆成两个文件的话，「两个目录隔开」这条约束会被复制到两处去守。
///
/// ## 隔开是硬要求（2026-10-11 产品决定）
/// 入口页两张卡分别通向 kind=local 与 kind=download，**任何一处都不合并**：
/// 手机自带的歌和 app 下载的歌，来源、清理方式、能不能删都不一样。
/// 数据层用同一张表的 kind 列区分（见 schema.dart 的 local_audio 注释），
/// 展示层则完全分开。
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../data/db/dao/local_audio_dao.dart';
import '../state/app_state.dart';
import '../state/local_library.dart' show localEntryToSong;
import '../theme.dart';
import '../widgets/common.dart';

/// 入口页：两个左右并列的功能卡。
class LocalHubPage extends StatelessWidget {
  final AppState st;
  const LocalHubPage({super.key, required this.st});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
      appBar: AppBar(
        title: const Text('本地',
            style: TextStyle(fontWeight: FontWeight.w800)),
        backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
        elevation: 0,
      ),
      body: SwipeBack(
        onBack: () => Navigator.of(context).maybePop(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _HubCard(
                      icon: Icons.smartphone_rounded,
                      title: '本地',
                      subtitle: '${st.localCount} 首',
                      hint: '扫描手机自带歌曲',
                      color: const Color(0xFF6C5CE7),
                      scanning: st.localScanning,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => LocalAudioPage(
                            st: st,
                            kind: LocalAudioKind.local,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _HubCard(
                      icon: Icons.download_done_rounded,
                      title: '下载',
                      subtitle: '${st.downloadCount} 首',
                      hint: '本 app 下载的歌曲',
                      color: const Color(0xFF0EA5A4),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => LocalAudioPage(
                            st: st,
                            kind: LocalAudioKind.download,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // 把「为什么是两个地方」写在脸上，否则用户会以为下载的歌
              // 应该出现在本地列表里，然后来问为什么没有。
              Text(
                '两份清单各自独立：手机里的歌靠扫描，下载的歌由 app 落盘，'
                '互不混排、互不覆盖。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 入口页的功能卡。比公共的 [EntryCard] 多一行「这块是干什么的」。
class _HubCard extends StatelessWidget {
  const _HubCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.hint,
    required this.color,
    required this.onTap,
    this.scanning = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String hint;
  final Color color;
  final VoidCallback onTap;
  final bool scanning;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tokens.rLg),
      child: Container(
        padding: const EdgeInsets.all(16),
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
              child: scanning
                  ? const Padding(
                      padding: EdgeInsets.all(9),
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : Icon(icon, size: 19, color: color),
            ),
            const SizedBox(height: 11),
            Text(title,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(
              scanning ? '扫描中…' : subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              hint,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.4,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一份清单（kind 决定是哪一份）。
class LocalAudioPage extends StatefulWidget {
  final AppState st;
  final LocalAudioKind kind;

  const LocalAudioPage({super.key, required this.st, required this.kind});

  @override
  State<LocalAudioPage> createState() => _LocalAudioPageState();
}

class _LocalAudioPageState extends State<LocalAudioPage> {
  bool _busy = false;

  /// 一进页面就把「还没有线上身份」的本机歌交给后台补全。
  ///
  /// 放 postFrame 而不是 build 里：补全会回写清单 → notify → 本页重建，
  /// 在 build 中驱动它等于自己重建自己。不 await：串行带间隔的请求是
  /// 半分钟量级的活，不该挡住列表出现——用户看到的应该是封面一首一首
  /// 变真，而不是一个转圈的页面。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.st.syncLocalMeta());
    });
  }

  List<LocalAudioEntry> get _entries =>
      widget.kind == LocalAudioKind.local
          ? widget.st.localTracks
          : widget.st.downloadedTracks;

  bool get _isLocal => widget.kind == LocalAudioKind.local;

  /// 扫描 / 刷新。文案原样呈现 AppState 给出的原因——失败原因比失败本身有用。
  Future<void> _scan() async {
    setState(() => _busy = true);
    final msg = await widget.st.scanLocalAudio();
    if (!mounted) return;
    setState(() => _busy = false);
    if (msg == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _forget(LocalAudioEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除这条记录？', style: TextStyle(fontSize: 16)),
        content: Text(
          '只从「下载」清单里去掉「${e.title}」的记录，'
          '手机上的文件不会被删除。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true || e.id == null) return;
    await widget.st.forgetDownload(e.id!);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final entries = _entries;

    return Scaffold(
      backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
      appBar: AppBar(
        title: Text(
          _isLocal ? '本地' : '下载',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: dark ? Tokens.bgDark : Tokens.bg,
        elevation: 0,
        actions: [
          if (_isLocal)
            IconButton(
              // 扫描是幂等的（同一批 uri upsert），所以不需要二次确认
              onPressed: _busy ? null : _scan,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 21),
              tooltip: '扫描手机音乐',
            ),
        ],
      ),
      body: SwipeBack(
        onBack: () => Navigator.of(context).maybePop(),
        child: entries.isEmpty ? _empty(t) : _list(entries),
      ),
    );
  }

  Widget _empty(ThemeData t) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _isLocal ? Icons.library_music_outlined : Icons.download_outlined,
                size: 46,
                color: t.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                _isLocal ? '还没有扫描过手机里的歌曲' : '还没有下载的歌曲',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13.5,
                  color: t.colorScheme.onSurfaceVariant,
                ),
              ),
              if (_isLocal) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _scan,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(_busy ? '扫描中…' : '扫描手机音乐'),
                ),
                const SizedBox(height: 8),
                Text(
                  '需要「音乐」读取权限；扫描范围跟着设置里的本地目录走。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.5,
                    color: t.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      );

  Widget _list(List<LocalAudioEntry> entries) => ListView.builder(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        itemCount: entries.length,
        itemBuilder: (c, i) {
          final e = entries[i];
          final song = localEntryToSong(e);
          return SongRow(
            song: song,
            // 换到 albumMid 就拼真实封面；没换到、或断网拉不到图时，
            // CoverImage 会露出底下那层渐变占位（seed 与原来同一派生口径，
            // 所以占位颜色和改造前完全一致）。
            leading: CoverImage(
              url: song.coverUrl,
              seed: song.coverSeed,
              size: 46,
            ),
            subtitle: '${e.displayArtist} · ${e.sizeText}',
            showDuration: true,
            trailing: _isLocal
                ? null
                : IconButton(
                    onPressed: () => _forget(e),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: '从清单移除',
                  ),
            onTap: () => widget.st.playLocalTrack(e, source: entries),
          );
        },
      );
}
