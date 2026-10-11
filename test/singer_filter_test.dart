/// 歌手库筛选契约测试。
///
/// ## 这个测试锁的是什么
/// 歌手库的筛选**全部依赖硬编码的取值表**（`kSingerAreas` / `kSingerSexes` /
/// [singerIndexId]）。这些数字一旦写错，编译期不会有任何提示，表现是
/// 「点了没反应」「点了返回空列表」或「点女歌手出来一堆男的」——
/// 三种都不报错、都能被当成网络问题糊过去。
///
/// 所以这里把「取值表」当成对外契约锁住：
///   1. 与服务端 `data.tags` 自报的字典逐字一致（本文件里的期望值就是
///      2026-09-30 实测抓下来的原文）
///   2. `#` / `A-Z` 到 `index` 的换算覆盖全 27 项且互不重复
///   3. `singer_name` 的别名括号拆分**不丢字**——拆不出来就必须原样返回
///
/// 另：地区表里「华语」= 内地(200) + 港台(2) 是**产品决策**（中文语境的
/// 「中」），不是服务端的一档。这条也在这里锁住，避免有人后来「顺手」
/// 把它简化成单档，导致点「华语」看不到周杰伦。
library;

import 'package:audora_music/screens/home_screen.dart';
import 'package:audora_music/services/qqmusic/qqmusic_catalog_dto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('首字母 → 服务端 index 换算', () {
    test('A..Z 映射到 1..26', () {
      expect(singerIndexId('A'), 1);
      expect(singerIndexId('B'), 2);
      expect(singerIndexId('M'), 13);
      expect(singerIndexId('Z'), 26);
    });

    test('# 单独映射到 27（不能走字母换算）', () {
      // '#' 的 codeUnit 是 35，若误用 codeUnitAt - 64 会得到负数
      expect(singerIndexId('#'), 27);
    });

    test('小写字母等价于大写', () {
      expect(singerIndexId('a'), singerIndexId('A'));
      expect(singerIndexId('z'), singerIndexId('Z'));
    });

    test('索引条字母序列的映射两两不同，且不撞上「热门」-100', () {
      final ids = [for (final l in kSingerLetters) singerIndexId(l)];
      expect(ids.length, 27); // # + A..Z
      expect(ids.toSet().length, 27); // 互不重复
      expect(ids.contains(kSingerIndexHot), isFalse);
      expect(ids.reduce((a, b) => a < b ? a : b), 1);
      expect(ids.reduce((a, b) => a > b ? a : b), 27);
    });
  });

  group('筛选取值表（对齐服务端 tags 字典）', () {
    test('地区档位与服务端 tags.area 一致', () {
      expect(
        [for (final e in kSingerAreas) e.$2],
        [
          [-100], // 全部
          [200, 2], // 华语 = 内地 + 港台（产品口径，服务端是两档）
          [4], // 日本
          [3], // 韩国
          [5], // 欧美
        ],
      );
      expect([for (final e in kSingerAreas) e.$1],
          ['全部', '华语', '日本', '韩国', '欧美']);
    });

    test('类型档位与服务端 tags.sex 一致（0 男 / 1 女 / 2 组合）', () {
      expect(
        [for (final e in kSingerSexes) e.$2],
        [-100, 0, 1, 2],
      );
      expect([for (final e in kSingerSexes) e.$1], ['全部', '男', '女', '组合']);
    });

    test('「全部」只有一个哨兵值 -100，且同时用于地区与类型', () {
      expect(kSingerAll, -100);
      expect(kSingerAreas.first.$2, [kSingerAll]);
      expect(kSingerSexes.first.$2, kSingerAll);
      expect(kSingerIndexHot, kSingerAll);
    });

    test('服务端还有「其他」(area=6)，但不作为筛选项暴露', () {
      final exposed = {for (final e in kSingerAreas) ...e.$2};
      expect(exposed.contains(6), isFalse);
    });
  });

  group('singer_name 别名括号拆分', () {
    test('半角括号：外文名 + 中文译名', () {
      expect(splitSingerName('Alan Walker (艾兰·沃克)'), ('Alan Walker', '艾兰·沃克'));
      expect(splitSingerName('Taylor Swift (泰勒·斯威夫特)'),
          ('Taylor Swift', '泰勒·斯威夫特'));
    });

    test('全角括号同样能拆', () {
      expect(splitSingerName('米津玄師 （よねづ けんし）'), ('米津玄師', 'よねづ けんし'));
    });

    test('无括号时原样返回，不凭空造别名', () {
      expect(splitSingerName('周杰伦'), ('周杰伦', ''));
      expect(splitSingerName('G.E.M. 邓紫棋'), ('G.E.M. 邓紫棋', ''));
    });

    test('括号在开头 / 括号内为空 → 不拆，且不丢字', () {
      // 开括号在第 0 位：拆完 outer 为空，不是「名 + 别名」的形状
      expect(splitSingerName('(Live)'), ('(Live)', ''));
      expect(splitSingerName('AB()'), ('AB()', ''));
    });

    test('空串与纯空白不炸', () {
      expect(splitSingerName(''), ('', ''));
      expect(splitSingerName('   '), ('', ''));
    });

    test('拆分结果不丢字符：外名 + 别名 = 原串去掉括号与空白', () {
      const raw = 'Imagine Dragons (梦龙)';
      final (name, other) = splitSingerName(raw);
      expect(name, 'Imagine Dragons');
      expect(other, '梦龙');
      expect('$name$other', 'Imagine Dragons梦龙');
    });
  });

  group('华语档的行内地区标签', () {
    // 真机装机验证抓到的 bug：华语把内地/港台合成一项后，
    // 原先「遍历 kSingerAreas 找单项」的反查恒为 null，
    // 结果列表混排正确但每一行的地区标签都不显示。
    test('华语档的每个成员档都必须查得到标签', () {
      final hua = kSingerAreas.firstWhere((e) => e.$1 == '华语');
      expect(hua.$2, hasLength(2), reason: '华语应包含内地 + 港台两档');
      for (final id in hua.$2) {
        expect(kSingerSubAreaLabels[id], isNotNull,
            reason: '华语成员档 area=$id 没有标签，列表行会静默不显示地区');
      }
      expect(kSingerSubAreaLabels[200], '内地');
      expect(kSingerSubAreaLabels[2], '港台');
    });

    test('不限地区与单档地区不产生标签（标签只在混排时才有信息量）', () {
      expect(kSingerSubAreaLabels[kSingerAll], isNull);
      for (final id in [4, 3, 5]) {
        expect(kSingerSubAreaLabels[id], isNull);
      }
    });
  });

  group('索引条命中计算（手指坐标 → 第几项）', () {
    test('均匀分成 count 段，每段命中对应项', () {
      const h = 280.0; // 28 项 × 10px
      expect(singerIndexBarHit(0, h, 28), 0);
      expect(singerIndexBarHit(9.9, h, 28), 0);
      expect(singerIndexBarHit(10, h, 28), 1);
      expect(singerIndexBarHit(145, h, 28), 14);
      expect(singerIndexBarHit(279, h, 28), 27);
    });

    test('划出条子外夹到首 / 末项，不越界崩溃', () {
      expect(singerIndexBarHit(-40, 280, 28), 0);
      expect(singerIndexBarHit(999, 280, 28), 27);
      // 恰好等于高度：不进第 count 项（那是越界）
      expect(singerIndexBarHit(280, 280, 28), 27);
    });

    test('首帧未布局（height=0）或 count 非法时回落到第一项', () {
      expect(singerIndexBarHit(0, 0, 28), 0);
      expect(singerIndexBarHit(50, 0, 28), 0);
      expect(singerIndexBarHit(50, 280, 0), 0);
      expect(singerIndexBarHit(50, -1, 28), 0);
    });

    test('真实条目数（热 + # + A..Z = 28）覆盖完整', () {
      const n = 28; // _kSingerIndexBar 的长度
      final hits = {
        for (var y = 0; y < 280; y++) singerIndexBarHit(y.toDouble(), 280, n),
      };
      expect(hits, hasLength(n));
      expect(hits.reduce((a, b) => a < b ? a : b), 0);
      expect(hits.reduce((a, b) => a > b ? a : b), n - 1);
    });
  });

  group('头像 URL 归一', () {    test('明文 http 升级为 https', () {
      expect(
        normalizeSingerPic(
            'http://y.gtimg.cn/music/photo_new/T001R150x150M0000025NhlN2yWrP4.webp'),
        'https://y.gtimg.cn/music/photo_new/T001R150x150M0000025NhlN2yWrP4.webp',
      );
    });

    test('已是 https 则不动，空串保持空串（交给首字母圆片兜底）', () {
      const https =
          'https://y.gtimg.cn/music/photo_new/T001R150x150M0000025NhlN2yWrP4.webp';
      expect(normalizeSingerPic(https), https);
      expect(normalizeSingerPic(''), '');
    });
  });
}
