/// 网易云音乐 —— 只用来补**歌词译文**。
///
/// ## 为什么引入第二个源
/// QQ音乐歌词接口的 `trans` 字段匿名请求下恒为空（2026-09-29 实测 15 首
/// 热门外语歌全部返回空串，翻译要登录态）。而网易的 `/api/song/lyric`
/// 匿名就能拿到 `tlyric`（中文译文）。歌词原文仍走 QQ——它已与 `songMid`
/// 绑定，换源意味着重新搜索、重新对齐，不值得。
///
/// ## 职责边界
/// 只做「按歌名+歌手搜 id → 取 tlyric」这一件事，**不参与曲库、不参与匹配**。
/// 拿不到就返回 null，调用方静默降级为「无译文」。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../match/text_normalizer.dart';

class NeteaseProvider {
  NeteaseProvider({Dio? dio}) : dio = dio ?? _buildDio();

  final Dio dio;

  static Dio _buildDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 10),
        // 网易返回的 Content-Type 不固定（有 text/plain 也有 json），
        // 交给 Dio 自动判类型会偶发解析失败，统一当纯文本再自己 decode。
        responseType: ResponseType.plain,
        validateStatus: (s) => s != null && s < 500,
      ));

  static const _searchUrl = 'https://music.163.com/api/search/get/web';
  static const _lyricUrl = 'https://music.163.com/api/song/lyric';

  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'Referer': 'https://music.163.com/',
    'Accept': '*/*',
    // os=pc 决定返回 pc 版字段；缺了它部分歌词接口只回空壳
    'Cookie': 'os=pc; appver=8.9.70',
  };

  /// 取译文 LRC（网易的 `tlyric`），拿不到返回 null。
  ///
  /// 一次调用最多 2 个请求：搜索 + 歌词。
  Future<String?> fetchTranslationLrc({
    required String title,
    required String artist,
  }) async {
    final id = await _searchSongId(title: title, artist: artist);
    if (id == null) return null;

    try {
      final resp = await dio.get<dynamic>(
        _lyricUrl,
        queryParameters: {'os': 'pc', 'id': id, 'lv': -1, 'tv': -1},
        options: Options(headers: _headers),
      );
      final map = _decode(resp.data);
      final t = (map['tlyric'] as Map?)?['lyric']?.toString() ?? '';
      // 译文轨空 = 这首歌没有译文（不是错误）。别把它当失败重试。
      return t.trim().isEmpty ? null : t;
    } catch (_) {
      // 翻译是装饰性数据，任何失败都静默吞掉
      return null;
    }
  }

  /// 搜出歌曲 id。**匹配不上就返回 null**——宁可没译文，也不能把
  /// 另一首歌的译文挂到这首上（那种错误用户一眼就能看出来）。
  Future<int?> _searchSongId({
    required String title,
    required String artist,
  }) async {
    try {
      final resp = await dio.get<dynamic>(
        _searchUrl,
        queryParameters: {
          's': _keyword(title, artist),
          'type': 1,
          'offset': 0,
          'limit': 8,
        },
        options: Options(headers: _headers),
      );
      final map = _decode(resp.data);
      // 搜索接口用 code=200 表示成功（不是 0），与歌词接口不同源不同规约
      if ((map['code'] as num?)?.toInt() != 200) return null;

      final songs = (map['result'] as Map?)?['songs'];
      if (songs is! List) return null;

      final wantTitle = TextNormalizer.normalize(title);
      // QQ 的多歌手是 "/" 分隔，取第一段参与比对
      final wantArtist = TextNormalizer.normalize(artist.split('/').first);

      for (final item in songs) {
        if (item is! Map) continue;
        final gotTitle =
            TextNormalizer.normalize(item['name']?.toString() ?? '');
        if (gotTitle.isEmpty) continue;
        if (!TextNormalizer.isFuzzyMatch(gotTitle, wantTitle, 0.75)) continue;

        final artists = item['artists'];
        if (wantArtist.isNotEmpty && artists is List && artists.isNotEmpty) {
          final names = artists
              .map((a) =>
                  TextNormalizer.normalize((a as Map)['name']?.toString() ?? ''))
              .where((n) => n.isNotEmpty)
              .toList();
          // 第三档 fuzzy 是必需的：网易的歌手名常带重音 / 译名差异
          //（Céline Dion vs Celine Dion，编辑距离 1，但 contains 判不中）。
          final hit = names.any((n) =>
              n.contains(wantArtist) ||
              wantArtist.contains(n) ||
              TextNormalizer.isFuzzyMatch(n, wantArtist, 0.7));
          if (!hit) continue;
        }

        final id = (item['id'] as num?)?.toInt() ?? 0;
        if (id > 0) return id;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 搜索关键词：歌名 + 首位歌手。
  ///
  /// 只带一位歌手——网易的搜索对「A/B/C」这种多歌手串的召回很差，
  /// 实测三歌手关键词会把正确结果排到很后面。
  String _keyword(String title, String artist) {
    final a = artist.split('/').first.trim();
    return a.isEmpty ? title.trim() : '${title.trim()} $a';
  }

  static Map<String, dynamic> _decode(dynamic raw) {
    if (raw == null) return const {};
    if (raw is Map<String, dynamic>) return raw;
    final decoded = jsonDecode(raw.toString());
    return decoded is Map ? decoded.cast<String, dynamic>() : const {};
  }
}
