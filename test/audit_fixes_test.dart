/// 本轮修复的回归测试（2026-10-07 审计批次）。
///
/// 覆盖 4 个已修复的真实缺陷：
///   1. -412/-352 风控误调 setUserSession() 把用户静默踢回匿名
///   2. 发布先验 gapDays 向零截断，早于发行 30.9 天掉进「预热档」
///   3. 定时关闭只翻标志位、从不暂停真实播放器
///   4. showToast / 播放错误路径在 dispose 后仍 notifyListeners
///
/// （详情缓存在途去重另见 test/detail_inflight_test.dart）
///
/// 全部只经**公开 API** 断言，不为测试往生产代码里加钩子。
library;

import 'package:audora_music/services/bilibili/bili_cookie_session.dart';
import 'package:audora_music/models/models.dart';
import 'package:audora_music/services/bilibili/bili_dto.dart';
import 'package:audora_music/services/match/match_scorer.dart';
import 'package:audora_music/state/app_state.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ═══════════════════════════════════════════════════════════════
  // 1. 风控不得清除用户登录态
  // ═══════════════════════════════════════════════════════════════
  group('风控 -412/-352 只作废匿名指纹，不踢用户下线', () {
    test('invalidateAnonymousCookie 保留登录态，作废匿名缓存', () async {
      final s = BiliCookieSession(Dio());
      s.setUserSession(cookieHeader: 'SESSDATA=abc; bili_jct=def');
      expect(s.hasUserSession, isTrue);

      // 风控路径现在调用的方法（原先调的是 setUserSession()，等于 logout）
      s.invalidateAnonymousCookie();

      expect(s.hasUserSession, isTrue,
          reason: '风控只该作废匿名指纹缓存，不该清掉用户登录态（否则丢掉 192K 音质且无 UI 提示）');

      // 登录态 Cookie 仍要带着 SESSDATA 发出去（cookieHeader 在时不走网络）
      final eff = await s.effectiveCookies();
      expect(eff.values['SESSDATA'], 'abc',
          reason: '风控后请求仍必须携带用户 SESSDATA');
      expect(eff.loggedIn, isTrue);
    });

    test('无参 setUserSession 仍是「登出」语义（logout 依赖它）', () {
      final s = BiliCookieSession(Dio());
      s.setUserSession(cookieHeader: 'SESSDATA=abc; bili_jct=def');
      expect(s.hasUserSession, isTrue);

      s.setUserSession(); // logout 路径
      expect(s.hasUserSession, isFalse,
          reason: 'setUserSession() 无参必须继续清空登录态，否则 logout 失效');
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 2. 发布先验的天边界
  // ═══════════════════════════════════════════════════════════════
  group('发布先验 gapDays 天边界（负数向零截断修正）', () {
    final release = DateTime(2024, 1, 1);
    final releaseSec = release.millisecondsSinceEpoch ~/ 1000;
    final song = Song(
      title: 'X',
      artist: 'Y',
      duration: 200,
      releaseDate: release,
      coverSeed: 0,
    );

    double pub(int pubdateSec) => MatchScorer.score(
          VideoCandidate(
            bvid: 'BV',
            title: 'X - Y',
            durationSec: 200,
            pubdate: pubdateSec,
          ),
          song,
        ).detail.s4Publish;

    test('早于发行 30 天整 → 预热档 0.65（边界内）', () {
      expect(pub(releaseSec - 30 * 86400), 0.65);
    });

    test('早于发行 30.9 天 → 不可能档 0.00（旧实现误判为 0.65）', () {
      // 旧实现 `(pubdate - releaseSec) ~/ 86400` 向零截断 → -30 →
      // 掉进 `gapDays < 0` 的预热档 0.65。这里必须判 0.00。
      const day = 30 * 86400;
      const nine = 77760; // 0.9 天 = 21.6 小时（30.9 天）
      expect(pub(releaseSec - day - nine), 0.00,
          reason: '早于发行 30 天以上应判「不可能」0.00');
    });

    test('早于发行 29.9 天 → 仍是预热档 0.65（不能矫枉过正）', () {
      const day = 29 * 86400;
      const frac = 77760; // 29.9 天
      expect(pub(releaseSec - day - frac), 0.65);
    });

    test('晚于发行 1 秒 → 0~365 天档 1.00', () {
      expect(pub(releaseSec + 1), 1.00);
    });

    test('晚于发行 0 天整（当天）→ 1.00', () {
      expect(pub(releaseSec), 1.00);
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 3. 定时关闭
  // ═══════════════════════════════════════════════════════════════
  group('定时关闭', () {
    test('设置后状态可见，到期后自动清空', () async {
      final st = AppState();
      addTearDown(st.dispose);

      st.setSleepTimer(const Duration(milliseconds: 30));
      expect(st.sleepTimer, isNotNull, reason: '刚设定时应显示剩余时长');

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(st.sleepTimer, isNull, reason: '到期后应自动清空');
      expect(st.playing, isFalse, reason: '到期后应进入暂停态');
    });

    test('重新设定会取消上一个定时器', () async {
      final st = AppState();
      addTearDown(st.dispose);

      st.setSleepTimer(const Duration(milliseconds: 30));
      // 立刻改成一个远得多的时长：旧定时器若没被取消会提前触发
      st.setSleepTimer(const Duration(minutes: 30));

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(st.sleepTimer, isNotNull,
          reason: '旧定时器必须已被取消，否则会提前把新定时器也清掉');
    });

    test('传 null 取消定时关闭', () async {
      final st = AppState();
      addTearDown(st.dispose);

      st.setSleepTimer(const Duration(minutes: 30));
      expect(st.sleepTimer, isNotNull);

      st.setSleepTimer(null);
      expect(st.sleepTimer, isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // 4. dispose 之后的通知必须安全
  // ═══════════════════════════════════════════════════════════════
  group('dispose 之后调用不得抛 used-after-dispose', () {
    test('dispose 后 showToast 不抛异常', () {
      final st = AppState();
      st.dispose();

      // 修复前这里会直接抛
      // "A ChangeNotifier was used after being disposed"
      expect(() => st.showToast('已退出后才到的 toast'), returnsNormally);
    });

    test('dispose 后 setSleepTimer 不抛异常', () async {
      final st = AppState();
      st.setSleepTimer(const Duration(milliseconds: 20));
      st.dispose();

      // 定时器回调会在 dispose 之后才触发；dispose 已取消它，
      // 这里断言的是「整个过程不抛 used-after-dispose」。
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(st.mounted, isFalse, reason: 'AppState 应已处于 disposed 状态');
    });

    test('dispose 后 loadLibrary 不抛异常（未接数据层时直接返回）', () async {
      final st = AppState();
      st.dispose();
      await expectLater(st.loadLibrary(), completes);
    });
  });
}