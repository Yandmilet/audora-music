# 测试指南

```bash
flutter analyze             # 0 告警
flutter test                # 369 / 369 通过
```

## 覆盖矩阵

| 测试文件 | 覆盖重点 |
|----------|----------|
| `match_scorer_test.dart` | 文本规范化 / 六维打分 / 降级路径 / 权重自洽 |
| `match_pipeline_test.dart` | 匹配请求数 / 预筛不丢正确音源 / 详情缓存 / 无结果不无限递归 |
| `match_v04_test.dart` | 匹配引擎 v04 版本回归 |
| `db_test.dart` | DAO / 外键 CASCADE / 激活唯一性 / JSON 往返 |
| `integration_test.dart` | Repository ↔ AppState 装配 / 确认落库 / 刷新保位 |
| `lyric_mid_test.dart` | 真实 songMid 必须落库 |
| `lyric_translation_test.dart` | 歌词翻译 |
| `lrc_parser_test.dart` | LRC 歌词解析 |
| `empty_library_test.dart` | 空态契约（空库不填假数据 / dispose 后 async 落点） |
| `online_search_test.dart` | 在线搜索只读不落库 / 结果带真实 mid / 重复导入幂等 |
| `liked_test.dart` | 收藏幂等 / 重导不抹收藏 / 级联清理 / 迁移 |
| `play_stats_test.dart` | 计数门限 / 常听排序 / 流水聚合分离 / 迁移 |
| `source_resolver_test.dart` | 拉流 / 缓存 / 失效重匹配 / 音质上限透传 |
| `on_demand_match_test.dart` | 按需匹配 / 队列对象就地替换 / 已有音源 0 请求 |
| `online_play_test.dart` | 浏览点歌即播 / REVIEW 兜底激活 / 激活唯一性红线 |
| `playback_rebuild_test.dart` | 播放推进不触发 AppState 整树重建 |
| `toplist_card_overflow_test.dart` | 超长歌手名不溢出 |
| `singer_filter_test.dart` | 歌手筛选 / 索引条命中 / 华语成员档标签 |
| `singer_list_provider_test.dart` | 筛选参数编码 / 多档交错合并 / 分页边界 |
| `player_route_return_test.dart` | 路由返回 / 播放页开关不重建主内容层 |
| `bili_login_test.dart` | B站登录 |
| `widget_test.dart` | 主页面渲染 |
| `mine_settings_test.dart` | 我的设置 |
| `diag_log_test.dart` | 诊断日志 |
| `fx_test.dart` | 扩展功能 |

## 真机联网冒烟

需要真机 + 网络，**不要放进 CI**：

```bash
flutter test integration_test/live_smoke_test.dart -d <device>
flutter test integration_test/live_singer_filter_test.dart -d <device>
```

## 两个坑

> **内存库不要用 `inMemoryDatabasePath`** —— 在 sqflite_common_ffi 下它等价于 `file::memory:?cache=shared`，同进程内所有测试共享同一个库，数据会串。正确写法：`file:unique_name_N?mode=memory&cache=shared`。

> **测迁移不能用内存库** —— 内存库在最后一个连接关闭时内容销毁，"造旧库 → 关闭 → 新版本打开"会开出全新空库。必须用真实临时文件（`Directory.systemTemp.createTemp()`）。
