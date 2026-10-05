/// 歌手库 Provider 契约测试：筛选参数 / 多档合并 / 分页边界。
///
/// ## 为什么这层必须测
/// 歌手库的三种典型故障**都不抛异常**，UI 上看只是「没反应」或「少了一截」：
///
/// | 故障 | 表面现象 | 实际原因 |
/// | --- | --- | --- |
/// | `area` / `sex` / `index` 传错 | 点筛选没变化 | 参数名或取值写错，服务端按默认值返回 |
/// | 漏传 `genre` | 列表空白 | 服务端 `code=0` + 空数组的静默空结果 |
/// | 合并档的 `hasMore` 算错 | 列表刷到一半停住 | 用 `total / 每页数` 反推总页数，把某档尾部截掉 |
///
/// 所以这里断言的是**请求参数**与**分页结论**，不是「有没有报错」。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:audora2/services/qqmusic/qqmusic_catalog_dto.dart';
import 'package:audora2/services/qqmusic/qqmusic_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假适配器：按 `req_1.param` 生成一页歌手数据，并记录收到的请求参数。
class _FakeSingerApi implements HttpClientAdapter {
  _FakeSingerApi(this.respond);

  final Map<String, dynamic> Function(Map<String, dynamic> param) respond;
  final List<Map<String, dynamic>> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data =
        jsonDecode(options.queryParameters['data'] as String) as Map;
    final req = (data['req_1'] as Map).cast<String, dynamic>();
    final param = (req['param'] as Map).cast<String, dynamic>();
    calls.add({
      'module': req['module'],
      'method': req['method'],
      ...param,
    });
    return ResponseBody.fromString(
      jsonEncode({
        'code': 0,
        'req_1': {'code': 0, 'data': respond(param)},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 构造一个只依赖假网络的 provider。每个 test 用新实例，
/// 避免 `_cached` 的页级缓存跨用例污染。
({QQMusicProvider qq, _FakeSingerApi api}) build(
  Map<String, dynamic> Function(Map<String, dynamic> param) respond,
) {
  final api = _FakeSingerApi(respond);
  final dio = Dio(BaseOptions(
    validateStatus: (s) => s != null && s < 500,
  ))
    ..httpClientAdapter = api;
  return (qq: QQMusicProvider(dio: dio), api: api);
}

/// 一页 `get_singer_list` 的响应体。
Map<String, dynamic> body({
  required int area,
  required List<String> names,
  required int total,
}) =>
    {
      'area': area,
      'total': total,
      'singerlist': [
        for (final n in names)
          {
            'singer_mid': 'mid_$n',
            // 头像刻意给明文 http，用来验证归一化
            'singer_pic': 'http://y.gtimg.cn/p/$n.webp',
            'singer_name': n,
          },
      ],
    };

void main() {
  group('请求参数', () {
    test('默认请求走新接口，且筛选参数齐全（含必须显式传的 genre）', () async {
      final h = build((p) => body(area: p['area'] as int, names: ['周杰伦'], total: 1));

      await h.qq.fetchSingers();

      expect(h.api.calls, hasLength(1));
      final c = h.api.calls.single;
      expect(c['module'], 'Music.SingerListServer');
      expect(c['method'], 'get_singer_list');
      expect(c['area'], kSingerAll);
      expect(c['sex'], kSingerAll);
      expect(c['index'], kSingerIndexHot);
      // genre 少传会得到 code=0 的空列表（静默空结果），必须显式带 -100
      expect(c['genre'], -100);
      expect(c['sin'], 0);
      expect(c['cur_page'], 1);
    });

    test('筛选取值原样透传：欧美 + 男 + 首字母 A', () async {
      final h = build((p) => body(area: p['area'] as int, names: ['A1'], total: 493));

      await h.qq.fetchSingers(areas: [5], sex: 0, index: singerIndexId('A'));

      final c = h.api.calls.single;
      expect([c['area'], c['sex'], c['index']], [5, 0, 1]);
    });

    test('翻页偏移量按 sin 计算（page=3 → sin=160）', () async {
      final h = build((p) => body(area: p['area'] as int, names: ['A'], total: 500));

      await h.qq.fetchSingers(page: 3, areas: [200]);

      expect(h.api.calls.single['sin'], 160);
      expect(h.api.calls.single['cur_page'], 3);
    });

    test('相同筛选的同一页命中缓存；换页 / 换筛选必须重新请求', () async {
      final h = build((p) => body(area: p['area'] as int, names: ['A'], total: 9999));

      await h.qq.fetchSingers(areas: [200]);
      await h.qq.fetchSingers(areas: [200]);
      expect(h.api.calls, hasLength(1));

      await h.qq.fetchSingers(areas: [200], page: 2);
      await h.qq.fetchSingers(areas: [2]);
      expect(h.api.calls, hasLength(3));
    });
  });

  group('解析', () {
    test('单档：服务端顺序原样透传，头像归一 https，别名从括号拆出', () async {
      final h = build((p) => body(
            area: 5,
            names: ['Alan Walker (艾兰·沃克)', '周杰伦'],
            total: 2,
          ));

      final page = await h.qq.fetchSingers(areas: [5]);

      expect(page.singers.map((s) => s.name), ['Alan Walker', '周杰伦']);
      expect(page.singers.first.otherName, '艾兰·沃克');
      expect(page.singers.first.pic, startsWith('https://'));
      expect(page.singers.first.areaId, 5);
      // 「周杰伦」没有括号别名，别名必须为空而不是整串
      expect(page.singers.last.otherName, '');
      expect(page.total, 2);
      expect(page.hasMore, isFalse);
    });

    test('缺 mid 或 name 的条目直接丢弃，不产生无法入库的半成品', () async {
      final h = build((_) => {
            'area': 200,
            'total': 3,
            'singerlist': [
              {'singer_mid': '', 'singer_name': '没有mid', 'singer_pic': ''},
              {'singer_mid': 'mid_x', 'singer_name': '', 'singer_pic': ''},
              {'singer_mid': 'mid_ok', 'singer_name': '正常', 'singer_pic': ''},
            ],
          });

      final page = await h.qq.fetchSingers(areas: [200]);

      expect(page.singers.map((s) => s.mid), ['mid_ok']);
      // 头像为空 → UI 走首字母圆片兜底
      expect(page.singers.single.pic, '');
    });
  });

  group('多档合并（华语 = 内地 + 港台）', () {
    test('并行拉两档，按下标逐条交错，total 为两档之和', () async {
      final h = build((p) => (p['area'] as int) == 200
          ? body(area: 200, names: ['内地A', '内地B', '内地C'], total: 3364)
          : body(area: 2, names: ['港台A', '港台B'], total: 1538));

      final page = await h.qq.fetchSingers(areas: kSingerAreas[1].$2);

      expect(h.api.calls, hasLength(2));
      expect({for (final c in h.api.calls) c['area']}, {200, 2});
      expect(
        page.singers.map((s) => s.name),
        ['内地A', '港台A', '内地B', '港台B', '内地C'],
      );
      expect(page.total, 3364 + 1538);
      expect(page.hasMore, isTrue);
    });

    test('某档已到头也不会提前结束：hasMore 取各档「或」', () async {
      final h = build((p) => (p['area'] as int) == 200
          ? body(area: 200, names: ['内地A'], total: 200)
          : body(area: 2, names: ['港台A'], total: 80));

      final page = await h.qq.fetchSingers(areas: [200, 2]);

      // 港台 80 人 → 已到头；内地还有 → 整体仍有下一页
      expect(page.hasMore, isTrue);
    });

    test('两档都到头才是 false —— 不能用「总条数 / 每页数」反推总页数', () async {
      final h = build((p) => body(area: p['area'] as int, names: ['A'], total: 80));

      final page = await h.qq.fetchSingers(areas: [200, 2]);

      // 合并后本页有 2 条、total=160：若按 160/80=2 页反推会误判「还有下一页」
      expect(page.singers, hasLength(2));
      expect(page.total, 160);
      expect(page.hasMore, isFalse);
    });

    test('第 21 页：港台已空，内地仍有后续页 → 合并流不截断', () async {
      // 复刻真实数据规模：内地 3364 人(43 页) / 港台 1538 人(20 页)。
      // 用 total/(每页数×2)=ceil(4902/160)=31 反推总页数的话，
      // 内地第 32~43 页会整段看不到。
      final h = build((p) {
        final area = p['area'] as int;
        final sin = p['sin'] as int;
        if (area == 2) {
          return body(
            area: 2,
            names: sin >= 1600 ? const [] : ['港台A'],
            total: 1538,
          );
        }
        return body(area: 200, names: ['内地A'], total: 3364);
      });

      final page21 = await h.qq.fetchSingers(areas: [200, 2], page: 21);
      expect(page21.singers.map((s) => s.name), ['内地A']);
      expect(page21.hasMore, isTrue);

      // 内地最后一页：43*80 = 3440 > 3364 → 到头
      final page43 = await h.qq.fetchSingers(areas: [200, 2], page: 43);
      expect(page43.hasMore, isFalse);
    });
  });

  group('越界页截断（服务端对越界 sin 仍会返回数据）', () {
    // 实测：港台 total=1538（20 页），第 21 页仍返回 1 条、第 22 页返回 80 条；
    // 内地 total=3364（43 页），第 44 页也返回 80 条。`total` 不是分页终点。
    test('单档：越过 total 的页返回空，不把越界数据当正文', () async {
      final h = build((p) => body(area: 2, names: ['越界尾货'], total: 1538));

      final page = await h.qq.fetchSingers(areas: [2], page: 21);

      expect(page.singers, isEmpty);
      expect(page.hasMore, isFalse);
    });

    test('多档合并：越界档整体丢弃，只剩未越界档的数据', () async {
      // 真机现象复刻：华语档第 43 页本该只有内地 4 条，
      // 修复前会混进港台的 80 条越界数据（合计 84 条）。
      final h = build((p) => (p['area'] as int) == 2
          ? body(area: 2, names: List.generate(80, (i) => '港台越界$i'), total: 1538)
          : body(area: 200, names: ['内地A', '内地B'], total: 3364));

      final page = await h.qq.fetchSingers(areas: [200, 2], page: 22);

      expect(page.singers.map((s) => s.name), ['内地A', '内地B']);
      expect(page.singers.every((s) => s.areaId == 200), isTrue);
      // 内地仍有后续页
      expect(page.hasMore, isTrue);
    });

    test('最后一页仍按服务端给的部分结果返回（不误伤正常尾页）', () async {
      // 内地 total=3364 → 第 43 页起点 3360 < 3364，属正常尾页，不该被截断
      final h = build((p) => body(area: 200, names: ['小柯隆贝'], total: 3364));

      final page = await h.qq.fetchSingers(areas: [200], page: 43);

      expect(page.singers.map((s) => s.name), ['小柯隆贝']);
      expect(page.hasMore, isFalse);
    });

    test('total 为 0 时不据此否决已拿到的数据', () async {
      // total 缺失/为 0 既可能是「真的没有」，也可能是服务端没给，
      // 不能拿它去丢掉正文
      final h = build((_) => body(area: 200, names: ['A'], total: 0));

      final page = await h.qq.fetchSingers(areas: [200], page: 2);

      expect(page.singers.map((s) => s.name), ['A']);
    });
  });

  group('空结果与死循环防护', () {    test('返回空页但 total 仍偏大时 hasMore 必须为 false', () async {
      // 少了「本页确实拿到数据」这个条件，触底加载就会反复触发、
      // 永远拉不到新内容 —— 空转成死循环。
      final h = build((p) => body(area: p['area'] as int, names: const [], total: 9999));

      final page = await h.qq.fetchSingers(areas: [200]);

      expect(page.singers, isEmpty);
      expect(page.hasMore, isFalse);
    });

    test('有效地区但服务端返回空列表：如实返回空，不抛异常也不造数据', () async {
      // 实测 area=1 / area=-1 是非法取值，服务端返回 code=0 + 空数组
      final h = build((_) => {'area': 1, 'total': 0, 'singerlist': <dynamic>[]});

      final page = await h.qq.fetchSingers(areas: [1]);

      expect(page.singers, isEmpty);
      expect(page.total, 0);
      expect(page.hasMore, isFalse);
    });

    test('areas 传空列表时回落到「全部」，不会发出没有 area 的请求', () async {
      final h = build((p) => body(area: p['area'] as int, names: ['A'], total: 1));

      await h.qq.fetchSingers(areas: const []);

      expect(h.api.calls.single['area'], kSingerAll);
    });
  });
}
