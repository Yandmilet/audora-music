/// 没有 binding 时（纯 Dart 单测）进度通道必须「安静地不挂载」而不是崩。
///
/// ## 这条测试钉的是修复的另一半
/// 2026-10-11 修 release 上「一直下载中」（见 `download_progress_channel_test.dart`
/// 的说明：`BindingBase.debugBindingType()` 在 release 恒 null，导致 handler
/// 从来没挂上）时，判据换成了 release 也可用的写法。但**不能顺手把守卫删了**：
/// 仓库里大量纯 `test()` 只 `new AppState()` 看状态，那条构造链一路走到
/// `DownloadBox` → `ensureAttached()`，而 `MethodChannel.setMethodCallHandler`
/// 在 binding 之前注册会直接断言失败，实测一次打挂 7 个无关文件。
///
/// ## 为什么单独一个文件
/// binding 一旦在某个 isolate 里被 `testWidgets` 建起来就不会消失，所以
/// 「没有 binding」这个前提只能待在一个不跑 `testWidgets` 的文件里。
library;

import 'dart:async';

import 'package:audora_files/audora_files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('没有 binding：ensureAttached 返回 false 且不抛（注册 handler 会断言崩）', () {
    expect(DownloadUpdates.ensureAttached(), isFalse,
        reason: '这里没有 binding；返回 true 说明它其实根本没挡');
    // 早退不能被记成「已挂载」——否则 binding 起来之后就再也没有重试的机会
    expect(DownloadUpdates.ensureAttached(), isFalse);
  });

  test('没挂通道也不影响注入式进度：流本身照样能用', () async {
    final ctl = StreamController<DownloadUpdate>();
    addTearDown(ctl.close);
    final seen = <DownloadUpdate>[];
    final sub = ctl.stream.listen(seen.add);
    addTearDown(sub.cancel);

    ctl.add(const DownloadUpdate(
      taskId: 'd1',
      status: DownloadStatus.running,
      done: 2 * 1024 * 1024,
      total: 8 * 1024 * 1024,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(seen.single.percent, 25);
  });
}
