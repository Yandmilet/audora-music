# 测试指南

```bash
flutter analyze             # 0 error（残留若干 prefer_initializing_formals info）
flutter test                # 624 / 624 通过（51 个测试文件）
```

## 覆盖矩阵

| 测试文件 | 覆盖重点 |
|----------|----------|
| `match_scorer_test.dart` | 文本规范化 / 六维打分 / 降级路径 / 权重自洽 |
| `match_pipeline_test.dart` | 匹配请求数 / 预筛不丢正确音源 / 详情缓存 / 无结果不无限递归 |
| `detail_inflight_test.dart` | 详情缓存在途去重（跨歌并发撞同一 bvid 只发一次请求） |
| `audit_fixes_test.dart` | 风控不得踢用户下线 / 发布先验天边界 / 定时关闭 / dispose 后通知安全 |
| `song_dao_scope_test.dart` | 排除口径枚举（anyBinding vs activeBinding）/ LIKE 通配符按字面量匹配 |
| `match_v04_test.dart` | 匹配引擎 v04 版本回归 |
| `match_p0_test.dart` | P0 四项增量：RecallScorer / VersionDetector.classify / Contradiction 强制降级 / Best-vs-Second Margin |
| `match_p1_duration_test.dart` | P1 连续平滑时长打分（控制点之间不能是断崖） |
| `match_p1_titleparser_test.dart` | P1 TitleParser 2.0 接入评分链路 |
| `match_p1_uploader_test.dart` | P1 已验证 UP 主贝叶斯 bonus（`min(0.25, 0.08 + count×0.04)`） |
| `db_test.dart` | DAO / 外键 CASCADE / 激活唯一性 / JSON 往返 |
| `integration_test.dart` | Repository ↔ AppState 装配 / 确认落库 / 刷新保位 |
| `lyric_mid_test.dart` | 真实 songMid 必须落库 |
| `lyric_translation_test.dart` | 歌词翻译 |
| `lrc_parser_test.dart` | LRC 歌词解析 |
| `lyric_word_test.dart` | 字轴全部纯逻辑：分字 / 均分填充计算 / TTML 解析 / AMLL 匹配门禁 / 文件名安全 |
| `lyric_karaoke_test.dart` | 逐字扫光渲染层：当前行只 1 个 Ticker / 连续推帧不溢出 / 长行折 2 行不压破固定行高 / 无字轴时回落整行高亮 |
| `lyric_layout_test.dart` | 歌词页布局：首行贴在校准条下面（初始不滚动）/ 唱到中间行仍垂直居中 / 当前行 22 其余 13 / **单行 TextPainter 的 `textAlign.center` 不生效**（居中补偿不可删的实证） |
| `lyric_calibration_test.dart` | 时间轴校准：slope/offset 映射、两点校准求斜率、`alignLyricLine` |
| `empty_library_test.dart` | 空态契约（空库不填假数据 / dispose 后 async 落点） |
| `online_search_test.dart` | 在线搜索只读不落库 / 结果带真实 mid / 重复导入幂等 |
| `liked_test.dart` | 收藏幂等 / 重导不抹收藏 / 级联清理 / 迁移 |
| `liked_source_of_truth_test.dart` | 收藏以 DB 为唯一真相：计数走 `liked_song` 行数、列表现查、红心按 song_id 判；本机文件（无 song 行）不做只活内存的假收藏 |
| `play_stats_test.dart` | 计数门限 / 常听排序 / 流水聚合分离 / 迁移 |
| `source_resolver_test.dart` | 拉流 / 缓存 / 失效重匹配 / 音质上限透传 |
| `on_demand_match_test.dart` | 按需匹配 / 队列对象就地替换 / 已有音源 0 请求 |
| `online_play_test.dart` | 浏览点歌即播 / REVIEW 兜底激活 / 激活唯一性红线 |
| `playback_rebuild_test.dart` | 播放推进不触发 AppState 整树重建 |
| `playback_error_clear_test.dart` | 播放错误横幅自动清除 |
| `stall_watchdog_test.dart` | 停滞看门狗状态机：「PLAYING 但位置冻结」的死流判定 / 预算 / 清零（不起播放器） |
| `toplist_card_overflow_test.dart` | 超长歌手名不溢出 |
| `singer_filter_test.dart` | 歌手筛选 / 索引条命中 / 华语成员档标签 |
| `singer_list_provider_test.dart` | 筛选参数编码 / 多档交错合并 / 分页边界 |
| `player_route_return_test.dart` | 路由返回 / 播放页开关不重建主内容层 |
| `bili_login_test.dart` | B站登录 |
| `widget_test.dart` | 主页面渲染 |
| `home_cards_test.dart` | 首页两张入口卡（猜你想听 / 最近听过）形态 + 只进列表不起播 + 失败给文案 |
| `guess_for_you_test.dart` | 猜你想听：口味计票与取前 2 位 / 榜单兜底 / 跨来源去重 / 滤掉最近听过 / 单来源失败不拖垮整批 / 全失败绝不起播 / 重入吞掉 |
| `music_dirs_test.dart` | 歌曲目录：存过 ≠ 还能用（授权失效 / 只读 / 提供方挂）/ 两个目录互不回退 / 非 Android 退化 |
| `local_audio_test.dart` | local_audio 建表与 v10→v11 迁移（含迁移中断后的重跑）/ 两个 kind 隔离 / 换血裁剪的时间戳语义 / FK 与 999 变量上限 |
| `local_pages_test.dart` | 「本地」入口页两块卡并列、点进去是两份独立清单、扫描失败给原因 |
| `local_meta_sync_test.dart` | 本机文件的线上身份补全（DB v12）：v11→v12 迁移补三列 / 重扫不冲掉已缓存身份 / 冷却与「网络异常不冷却」/ 断网早停在分片边界 / 下载条目零成本回填 / 条目→Song 的封面 URL 映射 |
| `download_box_test.dart` | 下载状态机：三态按钮 / 参数一条不缺 / 取消与失败各有去处 / 完成后落 download 记录 / 过期事件不回灌 |
| `player_download_button_test.dart` | 播放页底部五颗按钮的顺序（下载必须在定时与音效之间） |
| `mine_settings_test.dart` | 我的设置（含在线音质与下载音质互相独立） |
| `mine_cover_test.dart` | 「收藏」列表左侧必须是真实专辑封面（不是渐变占位） |
| `mine_footer_test.dart` | 「我的」页底部关于区文案（版本号 / 署名）不漂移 |
| `diag_log_test.dart` | 诊断日志 |
| `fx_test.dart` | 扩展功能 |

## 真机联网冒烟

需要真机 + 网络，**不要放进 CI**：

```bash
flutter test integration_test/live_smoke_test.dart -d <device>
flutter test integration_test/live_singer_filter_test.dart -d <device>
```

## 五个坑

> **内存库不要用 `inMemoryDatabasePath`** —— 在 sqflite_common_ffi 下它等价于 `file::memory:?cache=shared`，同进程内所有测试共享同一个库，数据会串。正确写法：`file:unique_name_N?mode=memory&cache=shared`。

> **测迁移不能用内存库** —— 内存库在最后一个连接关闭时内容销毁，"造旧库 → 关闭 → 新版本打开"会开出全新空库。必须用真实临时文件（`Directory.systemTemp.createTemp()`）。

> **`testWidgets` 里不能有一条活的 sqflite 连接** —— sqflite_common_ffi 的后台
> isolate 与 `testWidgets` 的 fake-async 区冲突：测试体哪怕已经跑完并打出结果，
> 整个用例也**永远不会 complete**，报的是 `did not complete [E]` 而不是断言失败
> （实测：`await AppDatabase.open()` 后查询、连 `db.close()` 都执行了，仍然挂到超时）。
> 所以要么 widget 测试完全不碰库（`home_cards_test.dart` 就是这个形状：全用
> `AppState()` mock），要么把库的生命周期收在 `setUp` / `tearDown`（区外，正常
> await）。「入库 → 统计 → 界面」这种跨层链路，拆成纯 `test()` 覆盖数据侧 +
> `testWidgets` 覆盖形态侧，别在同一个用例里两头都要。

> **构造 AppState 的那条链路上不能挂 MethodChannel handler** ——
> `MethodChannel.setMethodCallHandler` 在 binding 初始化之前会直接断言失败
> （`_binaryMessenger != null || BindingBase.debugBindingType() != null`）。
> 仓库里大量纯 `test()` 只 `new AppState()` 看看状态，不开界面、没有 binding，
> 所以任何「AppState 构造期顺手注册的原生回调」都会一次性打挂几十个用例
> （实测 7 个无关文件同时红）。测试要喂进度就走 `DownloadBox.handleUpdate`
> （可 await，顺带避开上一条坑）。
>
> **但挡 binding 的判据绝对不能用 `BindingBase.debugBindingType()`** ——
> 它的赋值写在 `assert(() { ... return true; }())` 里（flutter 的
> `BindingBase.initInstances`），release 包把 assert 整块剥掉，于是这个 API 在
> **任何 release 构建里恒返回 null**，哪怕 binding 早就 `ensureInitialized()`
> 好了。插件侧曾拿它当守卫，结果 release 装机后 `audora/files/progress` 的
> handler 一次都没挂上：原生每条进度/完成回推都被 `MissingPluginException`
> 静默吃掉，界面上是「点了下载永远卡在下载中」，而文件其实 8MB 几秒就下完了。
> **debug 与全量单测都是绿的** —— 这类「只在 release 失效」的 bug 单测抓不住。
> 正确写法是 `try { ServicesBinding.instance; return true; } on Object { return false; }`
> （真没 binding 时 debug 抛 FlutterError、release 走 `instance!` 抛 TypeError，
> 两者都是 `Object`，三种构建模式行为一致）。见
> `download_progress_channel_test.dart` / `download_progress_attach_guard_test.dart`。
> 推而广之：**任何 runtime 分支都不要依赖 `debug*` / `_debug*` 这类 debug-only API**。

> **残留 Timer 的复位必须写在测试体里，`tearDown` 救不了** ——
> `testWidgets` 的「不允许残留 Timer」不变量跑在**测试体之后、`tearDown` 之前**，
> 所以只在 `tearDown` 里 `dispose()` / `resetForTest()` 等于没做：用例照样红，
> 而且报的是框架异常，不是你的断言。仓库里两处同形：
> `AppState.playQueue` 在无播放器时起的那个 1 秒周期模拟计时器（歌词/首页那批
> widget 测试全部在测试体末尾 `st.dispose()`），以及 `DiagLog` 的 2 秒 flush
> 计时器（任何走到 `DiagLog.w` 的分支都会留一条，`player_download_button_test.dart`
> 里「数据层没接」那条用例就是这么红的——`DownloadBox._refuse` 会写一行诊断）。
> 判据很简单：**这条用例有没有间接调用到会排计时器的东西**，有就在测试体末尾清掉。
