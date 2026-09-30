/// 真机自检页（临时）。
///
/// 用途：在没有完整 UI 接入前，直接在真机上验证 B站接口链路。
/// 覆盖：匿名指纹 Cookie → Wbi 签名 → 搜索 → 详情 → 拉流 → 音质选择。
///
/// 验证完成后此页会被移除，或收编进设置页的「诊断」入口。
library;

import 'package:flutter/material.dart';

import '../services/bilibili/bili_api.dart';
import '../services/bilibili/bili_api_client.dart';
import '../services/bilibili/bili_dto.dart';
import '../services/qqmusic/qqmusic_provider.dart';

class ApiSelfCheckPage extends StatefulWidget {
  const ApiSelfCheckPage({super.key});

  @override
  State<ApiSelfCheckPage> createState() => _ApiSelfCheckPageState();
}

class _SelfCheckStep {
  final String name;
  String detail = '';
  int state = 0; // 0=待执行 1=通过 2=失败

  _SelfCheckStep(this.name);
}

class _ApiSelfCheckPageState extends State<ApiSelfCheckPage> {
  final List<_SelfCheckStep> _steps = [];
  bool _running = false;
  String _query = '起风了 买辣椒也用券';

  late final BiliApiClient _client;
  late final BiliApi _api;
  late final QQMusicProvider _qq;

  @override
  void initState() {
    super.initState();
    _client = BiliApiClient();
    _api = BiliApi(_client);
    _qq = QQMusicProvider();
  }

  _SelfCheckStep _add(String name) {
    final s = _SelfCheckStep(name);
    _steps.add(s);
    return s;
  }

  void _mark(_SelfCheckStep s, bool ok, String detail) {
    setState(() {
      s.state = ok ? 1 : 2;
      s.detail = detail;
    });
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _steps.clear();
      _running = true;
    });

    // ── 1. 匿名 Cookie ──────────────────────────────
    final cookieStep = _add('① 匿名指纹 Cookie');
    try {
      final cookies = await _client.session.effectiveCookies();
      if (cookies.isEmpty) {
        _mark(cookieStep, false, '未取到任何 Cookie');
      } else {
        _mark(cookieStep, true,
            '${cookies.values.length} 项：${cookies.values.keys.join(", ")}');
      }
    } catch (e) {
      _mark(cookieStep, false, '$e');
    }

    // ── 2. Wbi 签名密钥 ─────────────────────────────
    final wbiStep = _add('② Wbi 签名密钥');
    try {
      final keys = await _client.session.fetchWbiKeys();
      if (keys == null) {
        _mark(wbiStep, false, 'nav 接口未返回 wbi_img');
      } else {
        _mark(wbiStep, true, 'imgKey=${keys.$1}\nsubKey=${keys.$2}');
      }
    } catch (e) {
      _mark(wbiStep, false, '$e');
    }

    // ── 3. 搜索接口 ─────────────────────────────────
    final searchStep = _add('③ 搜索接口（wbi/search/type）');
    List<VideoCandidate> candidates = [];
    try {
      candidates = await _api.searchWithFallback(_query, durationFilter: 1);
      if (candidates.isEmpty) {
        _mark(searchStep, false, '关键词「$_query」无结果');
      } else {
        final top = candidates.take(3).map((c) =>
            '· ${c.title}\n  ${c.author} | ${c.durationSec}s | 播放 ${c.play}');
        _mark(searchStep, true,
            '命中 ${candidates.length} 条\n${top.join("\n")}');
      }
    } catch (e) {
      _mark(searchStep, false, '$e');
    }

    // ── 4. 详情接口 ─────────────────────────────────
    final detailStep = _add('④ 详情接口（wbi/view）');
    VideoDetail? detail;
    if (candidates.isEmpty) {
      _mark(detailStep, false, '跳过：无候选');
    } else {
      try {
        detail = await _api.fetchVideoDetail(candidates.first.bvid);
        if (detail == null) {
          _mark(detailStep, false, '详情返回空（视频可能已失效）');
        } else {
          _mark(
            detailStep,
            true,
            'bvid=${detail.bvid} cid=${detail.cid}\n'
            'UP=${detail.ownerName} 分区=${detail.tname}\n'
            '精确时长=${detail.durationSec}s 播放=${detail.playCount}\n'
            '分P数=${detail.pages.length}',
          );
        }
      } catch (e) {
        _mark(detailStep, false, '$e');
      }
    }

    // ── 5. 音频流解析 ───────────────────────────────
    final streamStep = _add('⑤ 音频流（player/wbi/playurl）');
    if (detail == null) {
      _mark(streamStep, false, '跳过：无详情');
    } else {
      try {
        final stream = await _api.fetchAudioStream(detail.bvid, detail.cid);
        if (stream == null) {
          _mark(streamStep, false, '未返回 dash.audio');
        } else {
          _mark(
            streamStep,
            true,
            '音质ID=${stream.id}（${stream.qualityLabel}）\n'
            '带宽=${stream.bandwidth} bytes/s\n'
            'mimeType=${stream.mimeType}\n'
            'URL 前缀=${stream.baseUrl.substring(0, stream.baseUrl.length.clamp(0, 60))}...',
          );
        }
      } catch (e) {
        _mark(streamStep, false, '$e');
      }
    }

    setState(() => _running = false);
  }

  /// QQ音乐元数据链路：搜索 → 详情 → 歌词创作者解析
  Future<void> _runQqMusic() async {
    if (_running) return;
    setState(() {
      _steps.clear();
      _running = true;
    });

    // ── 1. QQ音乐搜索 ───────────────────────────────
    final searchStep = _add('⑥ QQ音乐搜索');
    List<dynamic> metas = [];
    try {
      metas = await _qq.search('起风了', pageSize: 3);
      if (metas.isEmpty) {
        _mark(searchStep, false, '无结果');
      } else {
        final lines = metas.take(3).map((m) =>
            '· ${m.title}\n  ${m.artists.join("/")} | ${m.interval}s | ${m.songMid}');
        _mark(searchStep, true, '命中 ${metas.length} 条\n${lines.join("\n")}');
      }
    } catch (e) {
      _mark(searchStep, false, '$e');
    }

    // ── 2. 详情（精确时长 / 发行日期）────────────────
    final detailStep = _add('⑦ QQ音乐详情（精确字段）');
    dynamic detail;
    if (metas.isEmpty) {
      _mark(detailStep, false, '跳过：无候选');
    } else {
      try {
        detail = await _qq.fetchDetail(metas.first);
        if (detail == null) {
          _mark(detailStep, false, '详情返回空');
        } else {
          _mark(
            detailStep,
            true,
            '标题=${detail.title}\n'
            '歌手=${detail.artists.join("/")}\n'
            '专辑=${detail.album}\n'
            '时长=${detail.interval}s  发行=${detail.releaseDate}\n'
            '封面=${detail.coverUrl ?? "(无)"}',
          );
        }
      } catch (e) {
        _mark(detailStep, false, '$e');
      }
    }

    // ── 3. 歌词解析创作者 ───────────────────────────
    final creditStep = _add('⑧ 歌词头部 → 创作者信息');
    if (detail == null) {
      _mark(creditStep, false, '跳过：无详情');
    } else {
      try {
        final lyr = await _qq.fetchLyric(detail.songMid as String);
        if (lyr == null) {
          _mark(creditStep, false, '未取到歌词');
        } else {
          _mark(
            creditStep,
            true,
            'LRC 长度=${lyr.lrc.length} 字符\n'
            '译文=${lyr.hasTranslation ? "有" : "无（回落网易源）"}\n'
            '作词=${lyr.credits.lyricist ?? "(未解析到)"}\n'
            '作曲=${lyr.credits.composer ?? "(未解析到)"}\n'
            '编曲=${lyr.credits.arranger ?? "(未解析到)"}\n'
            '--- LRC 开头 ---\n'
            '${lyr.lrc.split("\n").take(9).join("\n")}',
          );
        }
      } catch (e) {
        _mark(creditStep, false, '$e');
      }
    }

    // ── 4. 端到端：关键词 → Song 对象 ────────────────
    final e2eStep = _add('⑨ 端到端：关键词 → Song 模型');
    try {
      final song = await _qq.resolveSong('米津玄師 Lemon', withLyricCredits: true);
      if (song == null) {
        _mark(e2eStep, false, '未解析出歌曲');
      } else {
        _mark(
          e2eStep,
          true,
          'title=${song.title}\n'
          'artist=${song.artist}\n'
          'album=${song.album}\n'
          'duration=${song.duration}s\n'
          '作词=${song.lyricist ?? "-"} 作曲=${song.composer ?? "-"}\n'
          '编曲=${song.arranger ?? "-"}\n'
          '发行=${song.releaseDate}\n'
          'key=${song.key}',
        );
      }
    } catch (e) {
      _mark(e2eStep, false, '$e');
    }

    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('接口自检（临时页）',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: TextEditingController(text: _query),
            decoration: const InputDecoration(
              labelText: '搜索关键词',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => _query = v,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow_rounded),
            label: Text(_running ? '执行中...' : '① B站接口自检'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.blueGrey),
            onPressed: _running ? null : _runQqMusic,
            icon: const Icon(Icons.library_music_rounded),
            label: const Text('② QQ音乐元数据自检'),
          ),
          const SizedBox(height: 16),
          ..._steps.map(_buildStep),
        ],
      ),
    );
  }

  Widget _buildStep(_SelfCheckStep s) {
    final color = switch (s.state) {
      1 => Colors.green,
      2 => Colors.red,
      _ => Colors.grey,
    };
    final icon = switch (s.state) {
      1 => Icons.check_circle_rounded,
      2 => Icons.error_rounded,
      _ => Icons.hourglass_empty_rounded,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(s.name,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            if (s.detail.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                s.detail,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  fontFamily: 'monospace',
                  color: s.state == 2 ? Colors.red.shade700 : null,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
