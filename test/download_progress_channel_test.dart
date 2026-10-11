/// 原生 → Dart 的下载进度通道连通性测试。
///
/// ## 为什么单独立一个文件（2026-10-11 release 事故）
/// `DownloadUpdates.ensureAttached()` 原先用 `BindingBase.debugBindingType()`
/// 判「binding 是否就绪」。那个值是写在 `assert(() {...}())` 里的，release 包
/// 把 assert 整块剥掉，于是它在**任何 release 构建里恒返回 null** —— handler
/// 一次都没挂上，原生每条进度/完成都被 MissingPluginException 吃掉：界面上
/// 「点了下载一直卡在下载中」，而文件其实几秒就完整落盘了。
///
/// 这类 bug 在 debug 跑的单测里天生看不见（debug 下守卫会通过），所以这里用
/// **真通道**把 seam 钉死：模拟原生 `invokeMethod('download', payload)`，要求
/// 它必须变成 `DownloadUpdates.stream` 里的一条 [DownloadUpdate]，字段解析
/// 也不能错。handler 挂没挂、codec 对不对、taskId/percent/uri 解析对不对，
/// 一条事件打进来就见分晓。
///
/// ## 边界
/// DownloadBox 拿到这些事件之后怎么变状态，是 `download_box_test.dart` 的
/// 事（它注入自己的流，避开真通道与真播放器）。这里只管「通道 → 流」这一段。
library;

import 'package:audora_files/audora_files.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 模拟原生侧一次 `progressChannel.invokeMethod('download', payload)`。
Future<void> _pushFromNative(
  WidgetTester tester,
  Object? payload, {
  String method = 'download',
}) async {
  final data =
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, payload));
  await tester.binding.defaultBinaryMessenger
      .handlePlatformMessage(AudoraFiles.progressChannel.name, data, (ByteData? _) {});
  await tester.pump();
}

void main() {
  group('下载进度通道（原生 → DownloadUpdates.stream）', () {
    testWidgets('binding 就绪时 ensureAttached 必须真的挂上 handler', (tester) async {
      // 这一句就是 release 事故的正主：挂不上 handler，后面全部回推都会丢。
      expect(DownloadUpdates.ensureAttached(), isTrue,
          reason: '有 binding 却不挂载 = 进度永久丢失');
      // 幂等：第二次不能装第二个 handler（后注册会覆盖前一个）。
      expect(DownloadUpdates.ensureAttached(), isTrue);

      final seen = <DownloadUpdate>[];
      final sub = DownloadUpdates.stream.listen(seen.add);
      addTearDown(sub.cancel);

      await _pushFromNative(tester, {
        'taskId': 'd1',
        'status': 'running',
        'done': 4 * 1024 * 1024,
        'total': 8 * 1024 * 1024,
      });

      expect(seen, hasLength(1), reason: '通道事件没到流里 = 原 bug 复现');
      expect(seen.single.taskId, 'd1');
      expect(seen.single.status, DownloadStatus.running);
      expect(seen.single.isTerminal, isFalse);
      expect(seen.single.percent, 50);
    });

    testWidgets('done 事件的 uri / 文件名 / 大小一个都不能在解码时丢掉', (tester) async {
      DownloadUpdates.ensureAttached();
      final seen = <DownloadUpdate>[];
      final sub = DownloadUpdates.stream.listen(seen.add);
      addTearDown(sub.cancel);

      await _pushFromNative(tester, {
        'taskId': 'd2',
        'status': 'done',
        'done': 8095489,
        'total': 8095489,
        'uri': 'content://com.android.externalstorage.documents/document/primary%3Aa.m4a',
        'name': 'Habit - Sekai no Owari.m4a',
        'size': 8095489,
      });

      final u = seen.single;
      expect(u.isTerminal, isTrue);
      expect(u.status, DownloadStatus.done);
      // done 之后 DownloadBox 要靠 uri + size 落 local_audio 记录
      expect(u.uri, startsWith('content://'));
      expect(u.name, 'Habit - Sekai no Owari.m4a');
      expect(u.size, 8095489);
      expect(u.percent, 100);
    });

    testWidgets('failed 的原因原样带回，缺字段也不崩', (tester) async {
      DownloadUpdates.ensureAttached();
      final seen = <DownloadUpdate>[];
      final sub = DownloadUpdates.stream.listen(seen.add);
      addTearDown(sub.cancel);

      await _pushFromNative(tester, {
        'taskId': 'd3',
        'status': 'failed',
        'error': '源站返回 403',
      });
      // 原生只给最小字段时也不能炸（缺 total = 界面该显示转圈而不是假百分比）
      await _pushFromNative(tester, {'taskId': 'd4', 'status': 'canceled'});
      // 参数不是 Map：忽略，别把垃圾塞进流
      await _pushFromNative(tester, 'not-a-map');
      // 别人的方法：与本通道无关
      await _pushFromNative(tester, {'taskId': 'd5'}, method: 'somethingElse');

      expect(seen, hasLength(2));
      expect(seen[0].error, '源站返回 403');
      expect(seen[0].percent, isNull);
      expect(seen[1].status, DownloadStatus.canceled);
    });
  });
}
