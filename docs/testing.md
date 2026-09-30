# 测试指南

> 本文由原 README「测试」章节迁出。

```bash
flutter analyze             # 0 告警
flutter test                # 204 / 204 通过
```

## 覆盖矩阵

| 测试文件                             | 覆盖                                                                                                                                                  |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test/match_scorer_test.dart`    | 26 项：文本规范化 / 黄金测试集 / 时长分档 / 发布先验 / 降级路径 / 权重自洽                                                                                                      |
| `test/db_test.dart`              | 22 项：DAO / 外键 CASCADE / **激活唯一性不变式** / JSON 往返                                                                                                      |
| `test/integration_test.dart`     | Repository ↔ AppState 装配 / 确认落库 / 刷新保位                                                                                                              |
| `test/lyric_mid_test.dart`       | 11 项：**真实 songMid 必须落库**（`local:` 前缀不得穿透歌词接口）                                                                                                       |
| `test/empty_library_test.dart`   | 11 项：**空态契约**（空库不填假数据 / 空队列播放控制安全 / dispose 后 async 落点）                                                                                             |
| `test/online_search_test.dart`   | 12 项：在线搜索只读不落库 / 结果带真实 mid / 重复导入幂等 / 端到端取到歌词                                                                                                       |
| `test/liked_test.dart`           | 13 项：收藏幂等 / **重导不抹收藏** / 级联清理 / **v1→v2 迁移**                                                                                                        |
| `test/play_stats_test.dart`      | 21 项：计数门限 / 常听排序 / 最近播放去重 / **裁流水不缩统计** / **v2→v3 迁移**                                                                                              |
| `test/source_resolver_test.dart` | 拉流 / 缓存 / 失效重匹配 / **音质上限透传**                                                                                                                        |
| `test/match_pipeline_test.dart`  | 12 项：**匹配请求数**（详情 ≤ `enrichTopK` / 池子翻倍请求不变）/ 预筛不丢正确音源 / 详情缓存 / **无结果不无限递归**                                                                        |
| `test/on_demand_match_test.dart` | 10 项：**按需匹配**（无音源现匹配 / 队列对象就地替换 / 已有音源 0 请求 / 等待可见 / 匹配不到不抛错）                                                                                       |
| `test/online_play_test.dart`     | 10 项：**浏览点歌即播**（persistOnline 带 id / 同批重复去重保序 / upsert 幂等 / 点哪首播哪首 / 点击项按 key 对齐去重后位置 / mock 模式安全返回）+ **REVIEW 兜底激活**（激活最高分候选 / 底线拒绝 / **激活唯一性红线**） |
| `test/widget_test.dart`          | 三项主页面渲染不崩                                                                                                                                           |

> `match_pipeline_test.dart` 刻意测的是**请求数**而不是「选得对不对」——
> 功能正确性由 `match_scorer_test.dart` 覆盖，但那个文件完全测不出
> 「选一次要发多少次请求」，而请求数直接决定用户等多久。
> 它用 `_FakeBili extends BiliApi` 记账，不发网络请求，
> **不需要给生产代码加抽象层**。

## 真机联网冒烟（`integration_test/live_smoke_test.dart`）

需要真机 + 网络，**不要放进 CI**：

```bash
flutter test integration_test/live_smoke_test.dart -d <device>
```

覆盖：QQ音乐三重校验 → B站单曲匹配 → 拉流落库 → 歌词 → 在线搜索端到端。

## 单测与迁移的两个坑

> ⚠️ **内存库不要用 `inMemoryDatabasePath`**——在 sqflite_common_ffi 下它
> 等价于 `file::memory:?cache=shared`，同进程内所有测试共享同一个库，数据会串。
> 正确写法：`file:unique_name_N?mode=memory&cache=shared`，名字带唯一序号。

> ⚠️ **测迁移不能用内存库**：内存库在最后一个连接关闭时内容就被销毁，
> 「造旧库 → 关闭 → 用新版本打开」会开出全新的空库，迁移根本没被触发。
> 必须用真实临时文件（`Directory.systemTemp.createTemp()`）。
