/// B站 Wbi 签名实现。
///
/// 依据 bilibili-API-collect 公开文档：
///   1. 从 `/x/web-interface/nav` 取 `wbi_img.img_url` / `sub_url`
///   2. 各取文件名（去路径与扩展名）得到 imgKey / subKey
///   3. 拼接后按固定 MIXIN_INDEX 重排，取前 32 位作为 mixinKey
///   4. 请求参数按 key 升序排序 → 拼 query → 混入 mixinKey → MD5 得 w_rid
///
/// mixinKey 有有效期（约一天），此处缓存 10 分钟，失败时自动重取。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 固定的 64 位重排索引表（官方实现，直接照抄标准实现）
const List<int> _mixinIndex = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
  27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
  37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
  22, 25, 54, 21, 56, 62, 6, 63, 57, 20, 34, 52, 59, 11, 36, 44,
];

/// Wbi 签名器。只负责算法，不管网络请求。
class WbiSigner {
  /// imgKey + subKey 拼接后的 64 位串
  final String _orig;

  WbiSigner(String imgKey, String subKey) : _orig = '$imgKey$subKey' {
    if (_orig.length < 64) {
      throw ArgumentError(
        'Wbi keys 拼接后长度不足 64：imgKey="$imgKey" subKey="$subKey"',
      );
    }
    _mixinKey = _deriveMixinKey();
  }

  late final String _mixinKey;

  String _deriveMixinKey() {
    final buf = StringBuffer();
    for (final i in _mixinIndex) {
      buf.write(_orig[i]);
    }
    return buf.toString().substring(0, 32);
  }

  /// 暴露给测试用
  String get mixinKey => _mixinKey;

  /// 对参数签名，返回追加了 `wts` 与 `w_rid` 的完整 query 参数。
  ///
  /// [params] 的值会被转成字符串；值为 null 的项直接丢弃。
  Map<String, String> sign(Map<String, dynamic> params) {
    // 1) wts 时间戳（秒），参与签名
    final signed = <String, String>{
      'wts': (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
    };
    for (final e in params.entries) {
      if (e.value == null) continue;
      signed[e.key] = e.value.toString();
    }

    // 2) 按 key 升序排列（ASCII 序）后拼接
    final keys = signed.keys.toList()..sort();
    final query = keys.map((k) => '$k=${_urlEncode(signed[k]!)}').join('&');

    // 3) 混入 mixinKey 后取 MD5
    final wRid = md5.convert(utf8.encode(query + _mixinKey)).toString();

    return {...signed, 'w_rid': wRid};
  }

  /// 从 nav 接口返回的 url 中提取文件名（去路径与扩展名）。
  ///
  /// `https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png`
  ///   → `7cd084941338484aae1ad9425b84077c`
  static String extractKey(String url) {
    if (url.isEmpty) return '';
    final noQuery = url.split('?').first;
    final name = noQuery.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// Wbi 签名要求参数值做 RFC3986 编码：空格须编码为 %20（而非 +）。
  static String _urlEncode(String v) {
    return Uri.encodeComponent(v)
        // encodeComponent 已处理大部分字符，这里补齐几个 B站签名约定：
        // 单引号 / 括号 / 叹号 官方实现不编码
        .replaceAll('%21', '!')
        .replaceAll('%27', "'")
        .replaceAll('%28', '(')
        .replaceAll('%29', ')')
        .replaceAll('%2A', '*')
        .replaceAll('%7E', '~');
  }
}
