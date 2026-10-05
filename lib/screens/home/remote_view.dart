/// 目录视图的公共骨架：远端 Future 的三态（加载 / 错误重试 / 内容）。
///
/// 从 home_screen.dart 拆出（P3 结构整理，纯代码搬运）——四个目录 tab
/// 都依赖这个骨架，独立成文件后 tab 之间不再互相牵连。
library;
import 'package:flutter/material.dart';

import '../../widgets/common.dart';

// ═══════════════════════════════════════════════════════════════
// 目录视图的公共骨架：远端 Future 的三态（加载 / 错误重试 / 内容）
// ═══════════════════════════════════════════════════════════════

/// 远端目录视图的三态骨架。
///
/// 目录数据来自 QQ音乐，没有 mock 兜底：加载中就是转圈，
/// 失败给原因 + 重试按钮。retriable 用 key 重挂 FutureBuilder。
class RemoteView<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext, T data) builder;
  const RemoteView({super.key, required this.load, required this.builder});

  @override
  State<RemoteView<T>> createState() => RemoteViewState<T>();
}

class RemoteViewState<T> extends State<RemoteView<T>> {
  late Future<T> _future;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  /// 公开的刷新入口。供外层通过 GlobalKey 调用来触发重新拉取
  /// （如下拉刷新、外部分类切换等场景）。
  void reload() {
    setState(() {
      _epoch++;
      _future = widget.load();
    });
  }

  void _retry() => reload();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      key: ValueKey(_epoch),
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.only(top: 48),
              child: CircularProgressIndicator(),
            ),
          );
        }
        if (snap.hasError) {
          return Center(
            child: EmptyState(
              icon: Icons.cloud_off_outlined,
              title: '加载失败',
              message: '${snap.error}\n请检查网络后重试。',
              actionLabel: '重试',
              onAction: _retry,
            ),
          );
        }
        return widget.builder(context, snap.data as T);
      },
    );
  }
}
