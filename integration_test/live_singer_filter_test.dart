/// 歌手库筛选的真机联网冒烟测试（**真机跑，需要网络**）。
///
/// 与 `live_smoke_test.dart` 同源：真机 + 真实 DNS/TLS，验证客户端与服务端
/// 之间「说不说得通」。放在 `integration_test/` 而非 `test/`，因为
/// **筛选是否生效只有服务端能回答**——单测只能证明我们发了什么参数，
/// 证明不了服务端认不认。
///
/// ⚠️ 会产生真实网络请求，不要放进 CI。命名带 `live_` 前缀便于识别与排除。
///
/// 运行：
/// ```
/// flutter test integration_test/live_singer_filter_test.dart -d <device>
/// ```
library;

import 'package:audora2/services/qqmusic/qqmusic_catalog_dto.dart';
import 'package:audora2/services/qqmusic/qqmusic_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final qq = QQMusicProvider();

  test('地区筛选：各档真实生效，内地与港台互不重叠', () async {
    // ④ 全量：默认「全部 / 全部 / 热门」
    final all = await qq.fetchSingers();
    liveLog('全部  total=${all.total} hasMore=${all.hasMore} '
        '首条=${all.singers.first.name}');
    expect(all.singers, isNotEmpty, reason: '歌手列表返回空，检查接口是否变更');
    expect(all.total, greaterThan(20000), reason: '全量歌手总数异常偏小');
    expect(all.hasMore, isTrue);
    expect(all.singers.first.pic, startsWith('https://'),
        reason: '头像必须是 https（明文 http 在收紧 cleartext 后会静默失效）');

    final cn = await qq.fetchSingers(areas: [200]); // 内地
    final hk = await qq.fetchSingers(areas: [2]); // 港台
    liveLog('内地  total=${cn.total} 首条=${cn.singers.first.name}');
    liveLog('港台  total=${hk.total} 首条=${hk.singers.first.name}');

    for (final (label, id) in [('日本', 4), ('韩国', 3), ('欧美', 5)]) {
      final p = await qq.fetchSingers(areas: [id]);
      liveLog('$label  area=$id total=${p.total} 首条=${p.singers.first.name}');
      expect(p.singers, isNotEmpty, reason: '「$label」筛选返回空，筛选可能未被服务端接受');
    }

    // ★ 内地与港台是两档不重叠的数据。若服务端把 area 参数当成「忽略」，
    // 两档会返回同一批，这条断言会立刻抓住——这正是旧接口的行为。
    final cnMids = {for (final s in cn.singers) s.mid};
    final hkMids = {for (final s in hk.singers) s.mid};
    expect(cnMids.intersection(hkMids), isEmpty,
        reason: '内地与港台出现重复歌手，area 参数可能被服务端忽略了');

    // 港台档必须包含周杰伦，内地档必须不包含 —— 这条直接锁住「中」的口径：
    // 若把「华语」实现成只取内地，用户点「中国」就看不到周杰伦。
    expect(hk.singers.map((s) => s.name), contains('周杰伦'));
    expect(cn.singers.map((s) => s.name), isNot(contains('周杰伦')));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('类型筛选：男 / 女 / 组合 三档各自不同', () async {
    final male = await qq.fetchSingers(sex: 0);
    final female = await qq.fetchSingers(sex: 1);
    final group = await qq.fetchSingers(sex: 2);
    liveLog('男 total=${male.total} / 女 total=${female.total} '
        '/ 组合 total=${group.total}');

    for (final (label, p) in [('男', male), ('女', female), ('组合', group)]) {
      expect(p.singers, isNotEmpty, reason: '「$label」筛选返回空');
    }

    expect(male.total, greaterThan(female.total));
    expect(male.total, greaterThan(group.total));

    // 抽样互斥：邓紫棋是女歌手，不该出现在男歌手第一页
    expect(female.singers.map((s) => s.name), contains('G.E.M. 邓紫棋'));
    expect(male.singers.map((s) => s.name), isNot(contains('G.E.M. 邓紫棋')));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('首字母筛选：A 档真的是 A 开头，且与 Z 档不同', () async {
    final a = await qq.fetchSingers(index: singerIndexId('A'));
    final z = await qq.fetchSingers(index: singerIndexId('Z'));
    final hot = await qq.fetchSingers(index: kSingerIndexHot);

    double aRatio(SingerPage p) {
      final n = p.singers.where((s) => s.name.toUpperCase().startsWith('A')).length;
      return n / p.singers.length;
    }

    liveLog('A 档 total=${a.total} 以A开头占比=${(aRatio(a) * 100).toStringAsFixed(0)}% '
        '首条=${a.singers.first.name}');
    liveLog('Z 档 total=${z.total} 以A开头占比=${(aRatio(z) * 100).toStringAsFixed(0)}% '
        '首条=${z.singers.first.name}');
    liveLog('热门 total=${hot.total} 首条=${hot.singers.first.name}');

    expect(a.singers, isNotEmpty);
    expect(aRatio(a), greaterThan(0.5), reason: 'A 档里过半不是 A 开头，index 参数可能没生效');
    expect(aRatio(z), lessThan(0.1), reason: 'Z 档里出现大量 A 开头，index 参数可能没生效');
    expect(hot.total, greaterThan(a.total), reason: '「热门」应覆盖全量而非单字母');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('组合筛选 + 头像可取（欧美 · 男 · A）', () async {
    final p = await qq.fetchSingers(areas: [5], sex: 0, index: singerIndexId('A'));
    liveLog('欧美+男+A total=${p.total} 首条=${p.singers.first.name} '
        '(别名=${p.singers.first.otherName})');

    expect(p.singers, isNotEmpty, reason: '组合筛选返回空');
    expect(p.total, lessThan(1000), reason: '三重筛选后总数仍很大，说明有维度未生效');
    for (final s in p.singers.take(5)) {
      expect(s.pic, isNotEmpty, reason: '「${s.name}」服务端没返回头像 URL');
    }

    // ★ 确定性断言：热门档首位（周杰伦）的头像必须真的能取回来。
    // 服务端**对每个歌手都返回 URL**，但 CDN 上没照片的会 404，
    // 所以只能挑一个确定有图的歌手来验「URL 规则没变」。
    final hot = await qq.fetchSingers();
    final jay = hot.singers.firstWhere((s) => s.name == '周杰伦',
        orElse: () => hot.singers.first);
    final img = await Dio().get<List<int>>(
      jay.pic,
      options: Options(responseType: ResponseType.bytes),
    );
    liveLog('「${jay.name}」头像 HTTP ${img.statusCode} '
        '${img.headers.value('content-type')} ${img.data?.length} 字节');
    expect(img.statusCode, 200);
    expect(img.headers.value('content-type'), contains('image'));

    // 冷门字母档的头像可用率只做统计、不断言：它本来就是「有就显示、
    // 没有就退化首字母圆片」。留这行日志是为了让「为什么要留兜底」
    // 在测试输出里可见（实测冷门档约 1/4 有图）。
    var ok = 0;
    final sample = p.singers.take(10).toList();
    for (final s in sample) {
      try {
        final r = await Dio().get<List<int>>(
          s.pic,
          options: Options(
            responseType: ResponseType.bytes,
            validateStatus: (_) => true,
          ),
        );
        if (r.statusCode == 200) ok++;
      } catch (_) {
        // 网络异常与 404 都算「这张图展示不出来」，由 UI 兜底
      }
    }
    liveLog('冷门档头像可用 $ok/${sample.length}（其余走首字母圆片兜底）');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('华语档（内地 + 港台）：交错合并、总数相加、尾部不被截断', () async {
    final cn = await qq.fetchSingers(areas: [200]);
    final hk = await qq.fetchSingers(areas: [2]);
    final merged = await qq.fetchSingers(areas: kSingerAreas[1].$2);

    liveLog('内地 ${cn.total} + 港台 ${hk.total} → 华语 ${merged.total}');

    // ① 总数是两档之和，不是取其一
    expect(merged.total, cn.total + hk.total);

    // ② 逐条交错：内地[0], 港台[0], 内地[1], 港台[1] …
    expect(
      merged.singers.take(4).map((s) => s.mid).toList(),
      [cn.singers[0].mid, hk.singers[0].mid, cn.singers[1].mid, hk.singers[1].mid],
      reason: '合并顺序不是按下标交错',
    );

    // ③ 每条都记得自己来自哪一档（UI 靠它显示「内地 / 港台」标签）
    expect(merged.singers.take(4).map((s) => s.areaId).toList(), [200, 2, 200, 2]);

    // ★ ④ 尾部不被截断。内地 43 页、港台 20 页，若按「总条数 / 每页数」
    // 反推总页数，内地第 21 页之后整段消失——用户永远翻不到内地的小众歌手。
    final lastPage = (cn.total / 80).ceil();
    liveLog('内地共 $lastPage 页，检查第 $lastPage 页与第 ${lastPage - 1} 页');
    final tail = await qq.fetchSingers(areas: kSingerAreas[1].$2, page: lastPage);
    final beforeTail =
        await qq.fetchSingers(areas: kSingerAreas[1].$2, page: lastPage - 1);
    liveLog('  第 ${lastPage - 1} 页 hasMore=${beforeTail.hasMore} '
        'n=${beforeTail.singers.length}');
    liveLog('  第 $lastPage 页 hasMore=${tail.hasMore} n=${tail.singers.length} '
        '首条=${tail.singers.isEmpty ? "-" : tail.singers.first.name}');
    expect(beforeTail.hasMore, isTrue, reason: '倒数第二页之后还有内地尾部没放完');
    expect(tail.hasMore, isFalse);
    expect(tail.singers, isNotEmpty, reason: '内地最后一页不该是空的（尾部被截断了）');

    // ★ ⑤ 越界档必须被丢弃。港台只有 20 页，第 21 页起服务端**仍会返回数据**
    // （实测第 22 页给 80 条），若不截断就会混进华语档的尾部，
    // 真机上表现为「第 43 页 84 条」（应为内地尾页的 4 条）。
    expect(tail.singers.every((s) => s.areaId == 200), isTrue,
        reason: '港台的越界尾货混进了华语档尾部');
    expect(tail.singers.length, cn.total - (lastPage - 1) * 80,
        reason: '尾部条数与内地最后一页不符，说明合并流掺入了其他档的数据');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// integration_test 环境里 `print` 会被吞掉，用这个统一出口
void liveLog(String msg) {
  // ignore: avoid_print
  print('[LIVE-SINGER] $msg');
}
