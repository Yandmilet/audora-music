# 技术债记录（By Design —— 不是半成品）

> 本文档记录元数据源/音源通用化重构（步骤 1-8）后**故意保留为 B站专属**的代码位置。
> 这些不是"还没做完"，而是在当前阶段不值得改。未来接入新平台时再评估。

## 重构总览

```
步骤 1  抽象接口 + 通用 DTO          ← MetadataProvider / AudioSourceProvider
步骤 2  QQ / B站 适配器              ← QQMusicMetadataAdapter / BiliAudioSourceAdapter
步骤 3  SourceResolver typedef 泛化  ← ResolveResult / SourceSubKeyRepairer 通用化
步骤 4  LibraryRepository 注入接口   ← 构造函数 metadata: MetadataProvider
步骤 5  MatchEngine 注入接口         ← 构造函数 sourceProvider: AudioSourceProvider
步骤 6  DB v4→v5 平滑迁移 + Row 双写 ← meta_source_type/id, source_type/key/sub_key
步骤 7  领域模型双写镜像 + 消费点迁到通用字段 ← AudioSource 加通用字段
步骤 8  AudioSource getter 化 + 删 Deprecated ← bvid/cid → sourceKey/sourceSubKey getter
```

**核心可切换性已达成**：换元数据源 → 写新 MetadataProvider 实现 + `main.dart` 改一行装配；换音源 → 写新 AudioSourceProvider 实现 + `main.dart` 改一行装配。中间所有 Repository/MatchEngine/Resolver/DB 逻辑不动。

---

## 故意保留为 B站专属的位置

### 1. MatchEngine 内部 DTO —— 6 处
- `lib/services/match/match_engine.dart`
- `lib/services/match/match_scorer.dart`
- B站专属类：`VideoCandidate.bvid / VideoDetail.cid / VideoPage.cid`
- **为什么留**：MatchEngine 流水线（Stage 1-4）有 30+ 处 `.bvid` / `.cid` 引用，全部泛化成本是步骤 1-8 的总和。adapter 边界（`_toVideoCandidate` / `_toVideoDetail` / `_searchSafe`）已经负责通用 DTO ↔ B站 DTO 转换，流水线逻辑不动就能适配任何新音源。
- **清理触发条件**：当接入第二个音源时，MatchEngine 流水线内 B站 DTO 与通用 DTO 的双维护成本超过收益。

### 2. SourceResolver catch BiliApiException —— 1 处
- `lib/services/playback/source_resolver.dart`
- **为什么留**：`-400/-403/-404` 这些错误码是 B站 playurl 接口特有的。适配器应把源专属异常翻译成通用异常类型（比如 `AudioSourceUnavailable` / `AudioSourceRateLimited`），让 Resolver 不依赖 B站。但这个异常类型设计需要统一考虑所有源，泛化范围超出本次重构。
- **清理触发条件**：接入第二个音源前，或者 Resolver 需要按错误码做分支时。

### 3. DAO 方法名 —— 约 8 处
- `lib/data/db/dao/video_dao.dart`：`getByBvid(bvid)` / `getByBvids(bvids)` / `updateAudioStream(bvid: ...)` / `updateCid(bvid, cid)` / `markUnavailable(bvid, reason)` / `getValidAudioUrl(bvid)`
- `lib/data/db/dao/binding_dao.dart`：`activate(songId, bvid)` / `bindManually(... bvid ...)` / `getFailedBvids(songId)`
- **为什么留**：方法名是内部实现细节。`bvid` 在 B站语境下等于 `sourceKey`，方法内部走的是 `WHERE bvid = ?`（主键查询）。改方法名 → 改 10+ 调用者（library_repository / source_resolver / state / screens）。泛化收益为零。
- **清理触发条件**：当 DB 表名也泛化（见下一条）时，DAO 方法名自然跟着改。

### 4. DB 表名和主键列 —— schema 层
- `Tables.video = 'bilibili_video'`
- `Tables.binding = 'song_source_binding'`
- `bilibili_video.bvid` 是主键（步骤 6 后同表有 `source_key` 冗余副本）
- `song_source_binding.bvid` 是 UNIQUE 约束的一部分（步骤 6 后同表有 `source_key`）
- **为什么留**：SQLite 不支持 ALTER TABLE RENAME 加新列，只能重建表（CREATE → INSERT SELECT → DROP → RENAME），违反本次重构「只加不改」原则。表名对运行时零影响——所有代码通过 `Tables.video` 常量引用，不改常量就没变化。
- **清理触发条件**：下一次大版本 DB 迁移（v6+），同时做表重建 + 约束统一。

### 5. DB 唯一约束双轨 —— Song 表
- 旧约束：`UNIQUE (qq_song_mid)`
- 新约束：`UNIQUE (meta_source_type, meta_source_id)`
- **为什么留**：步骤 6 新库建表时同时建两个约束（旧库 v4→v5 迁移只能 ALTER ADD COLUMN，不能加 UNIQUE）。两者在 `meta_source_type='qq'` 时等价。保留双约束无负面影响（INSERT 前自动命中其一），去掉 `UNIQUE(qq_song_mid)` 需要表重建。
- **清理触发条件**：v6+ 表重建时。

### 6. Row 层 B站专属字段 —— 映射层
- `SongRow.qqSongMid` / `VideoRow.bvid` / `VideoRow.cid` / `BindingRow.bvid`
- **为什么留**：Row 是 DB → 领域模型的映射层，字段名必须跟 SQLite 列名一致（步骤 6 后表仍有旧列 + 新列两套）。领域层 Song/AudioSource 已经解耦（AudioSource 内部只持 `sourceType/sourceKey/sourceSubKey`），Row 层的旧字段不再泄漏到业务逻辑。
- **清理触发条件**：v6+ 表重建删旧列时，Row 类同时删旧字段。

### 7. 直接 import qqmusic_dto.dart 拿 coverUrlFor —— 2 处
- `lib/data/db/rows.dart`：`import '../../services/qqmusic/qqmusic_dto.dart' show QQSongMeta;`
  → `SongRow.toSong()` 的 `coverUrl: QQSongMeta.coverUrlFor(albumMid)`
- `lib/state/local_library.dart`（v12 新增）：同一个函数，给本机条目拼封面 URL
- **为什么留**：`QQSongMeta.coverUrlFor` 是纯工具方法
  （`'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albumMid.jpg'`），
  无状态无依赖。可以挪到 `MetaSong` DTO 或独立的 `CoverUrl` 模块上，但两处引用
  还不足以证明这次搬迁的收益。
- **注意它是「唯一一处领域层反向依赖源专属 DTO」**：数据层与状态层都直接认得 QQ 的
  拼图规则。换封面源时必须一起改这两处（这也是清理动机的真正版本）。
- **清理触发条件**：当 MetaCover / CoverArt 抽成独立模块，或接入第二个元数据源时。

---

## 已知 bug（非设计债）

### ~~AppState part-file 位置错误~~ ✅ 已修复
- ~~`lib/state/app_state.dart:43:1` — `enum LibraryLoadState` 声明在 `part` 指令之前~~
- **修复**：回滚到 HEAD 单文件（part 文件拆分是本次重构意外引入的，HEAD 无 part 指令），加上 `qqCatalog: QQMusicProvider?` 构造参数让 UI 层 `st.qq` 仍可用
- **结果**：369/369 tests passed，0 compile-blocked

### AppState 直接持有 QQMusicProvider（目录浏览用）
- `AppState._qqCatalog: QQMusicProvider?` — 目录浏览（榜单/歌手/歌单/新歌榜）是 QQ 专属能力，不在 `MetadataProvider` 接口里
- **设计**：LibraryRepository.metadata 只管 search/fetchDetail/fetchLyric；AppState 直接持有原始 QQMusicProvider 给 UI 层用
- **清理触发条件**：扩展 MetadataProvider 接口加目录浏览能力，或者未来目录浏览换源（不一定要 QQ 的榜单概念）

### ~~SourceResolver 缓存 key 双写~~ ✅ 审计确认为安全
- `source_resolver.dart` 第 228 行：`row.cid == cidInt` — 仍在比较 VideoRow.cid（旧列）
- **审计结论（2026-10-07，已实测验证）**：安全，不会出问题。新增列
  `source_sub_key` 的 schema 默认值是 `''`，而 `rows.dart:322` 的 `fromMap`
  只在 `source_sub_key` 非空时才用它，否则回退读 `cid`。因此凡是
  `updateCid()` 写入过的行（只写 `cid`、不写 `source_sub_key`），
  读回来的 `sourceSubKey` 必然等于刚写入的 `cid`。
  实测：插入 `cid=0` 的搜索来源行 → `updateCid(bvid, 12345)` →
  读回 `cid=12345 / sub=12345`，送给 playurl 的就是 12345，自愈有效。
- **仍存在的脆弱点（暂不修）**：只有当**两副本都已有值且不一致**时才会
  分叉（如 `cid=0` 且 `source_sub_key='999'`，实测此时自愈值会被丢弃）。
  当前没有任何写入路径能造出这种状态——`VideoDao.upsert` 走
  `ON CONFLICT(bvid) DO UPDATE` 且写入的是同一个 `VideoRow` 的两份副本，
  `updateAudioStream` 的最小插入则让新列为空（走 fromMap 回退）。
- **清理触发条件**：将来若新增一条**只写 `source_sub_key` 不写 `cid`**
  （或反之）的写入路径，这个回退保证就不再成立，必须同时补写两列。

---

## 2026-10-07 审计批次：已修复

以下 6 项均为并发/异步边界缺陷，`flutter analyze` 0 告警、455/455 测试通过。

### 1. 定时关闭从不暂停真实播放器 ✅
- `app_state.dart` `setSleepTimer`：回调只翻 `_playing = false` +
  停 mock ticker，**没有 `_player?.pause()`**。UI 却承诺「播放将在设定
  时间后自动停止」。真机上音频一直放到自然结束，而界面显示暂停态；
  `playingStream` 是变更流不会补发 `true` 自愈，导致 `_playing` 与
  just_audio 永久失步，播放按钮再也按不动。
- **修复**：回调内 `unawaited(_player?.pause())`，并顺带结算播放时长。

### 2. 风控 -412/-352 把用户静默踢回匿名 ✅
- `bili_api_client.dart` 风控分支调 `session.setUserSession()` **无参**，
  而那是 `logout()` 的语义（`_sessdata`/`_userCookieHeader` 双 null）。
  注释写的是「作废**匿名** Cookie 缓存」，实际连用户登录态一起清掉：
  一次普通限流就丢掉 192K 音质，且无任何 UI 提示。
- **修复**：新增 `BiliCookieSession.invalidateAnonymousCookie()`，
  只清匿名指纹缓存、保留登录态；风控分支改调它。

### 3. 三处 `await` 之后缺 `mounted` 保护 ✅
- `onPlaybackError`（播放失败默认路径，会跑完整重匹配）、
  `loadLibrary` 入口、`_matchAndActivate` 的 `showToast`（≈20 秒）
  都在 `await` 之后 `notifyListeners()`，dispose 后抛
  「used after being disposed」。代码库自己在 `loadLyricForCurrent`
  写了注释承认这个坑，只是漏了这三处。
- **修复**：三处补 `if (!mounted) return;`；`showToast` 自身
  （含 3 秒后的 Timer 回调）也加了防御性判断。

### 4. 详情缓存缺在途去重 ✅
- `_detailOf` 先查缓存再 `await`，缓存只在请求返回后写入。
  单次 `match()` 内 `_mergeAndTrim` 已按 bvid 去重，所以**不是**
  「同歌内重复」；真正会重叠的是**跨歌**——批量匹配循环里相邻两首歌
  搜到同一个合集视频、或点播重解析与批量匹配撞上同一个 bvid
  （共用 repository 里那一个 MatchEngine 实例）。重叠时两路同时
  读到缓存 miss，各发一次请求，白烧一份 30 次/分钟额度。
- **修复**：新增 `_detailInFlight` 在途表，`finally` 清键（失败不毒化）。
  回归测试见 `test/detail_inflight_test.dart`（实测关掉去重会变成 2 次）。

### 5. 提前终止判定跨量纲相减 ✅
- `_enrichAndScore` 里 `best.total - nextCoarse >= earlyStopGap`：
  前者是 MatchScorer 六维总分（扣 penalty），后者是 RecallScorer 召回分
  （权重不同、含分区/播放量微调）。两把不同的尺子相减得到的「领先幅度」
  没有量纲意义，可能错误提前终止而砍掉正确候选。
- **修复**：改为用粗排分折算的**保守上界**
  `nextCoarse * earlyStopGap` 参与比较，不再直接相减。

### 6. 发布先验 gapDays 向零截断 ✅
- `_publishScore` 的 `(video.pubdate - releaseSec) ~/ 86400` 向零截断，
  早于发行 **30.9 天**会截成 -30，掉进 `gapDays < 0` 的「预热档 0.65」，
  而本该判「不可能 0.00」。
- **修复**：负值分支按符号做 floor 取整，与 `< -30` / `< 0` 分档边界对齐。

### 7. `getAllExcluding` 的原始子查询拼接（注入 sink）✅
- 旧签名 `getAllExcluding(String notInSubSelect)` 把调用方给的字符串
  **原样拼进 WHERE**：`id NOT IN ($notInSubSelect)`。当时只有两个调用方、
  都传常量，所以**不可利用**；但接口本身是注入 sink，将来任何一处传入
  用户/接口派生内容都是真实的 SQL 注入。
- **修复**：穷举成 `ExcludeScope` 枚举（`anyBinding` / `activeBinding`），
  拼接点变成 DAO 内部唯一的 switch 且全为编译期常量，调用方不可能再拼出
  注入。表名不能参数化（SQLite 不允许绑定标识符），这是能做到的上限。
  两个调用点（`unmatchedQueue` / `_unmatchedSongs`）已改为传枚举。

### 8. `search()` 的 LIKE 未转义通配符 ✅
- 原来直接 `'%$keyword%'`，用户搜 `%` 会匹配到整库、搜 `a_b` 会把 `axb`
  也算命中。值是参数化的（**不构成注入**），但结果与用户输入不符。
- **修复**：加 `ESCAPE '\'` 子句，并把 `%` / `_` / 反斜杠本身一起转义
  （`ESCAPE` 的标准要求：否则用户输入的 `\` 会把紧随其后的 `%`/`_`
  还原成通配符）。

### 9. `AudioPlayerController.dispose()` 死代码 / 看门狗 Timer 泄漏 ✅
- `lib/` 内无任何调用点；且 `bind()` 里两个 `just_audio` 流的
  `.listen(...)` **把 StreamSubscription 丢了**，即使 dispose 被调用也只停
  得下看门狗 Timer，订阅仍会继续往已释放的 handler 推数据。
- **修复**：
  - `_stateSub` / `_procStateSub` 存下订阅句柄，`bind()` 用 `??=` 保证
    可重复调用而不重复订阅；`shutdown()` 里 `cancel()` 并置空。
  - `shutdown()` **可重入**（`_disposed` 幂等）；旧 `dispose()` 保留为
    `@Deprecated` 转发。
  - 接到 `onTaskRemoved()`：**仅在非播放态**被划掉时（此时前台 Service
    本来就要 `stopSelf`，没有正在放的歌）才 `stop()` + `shutdown()`。
    播放态刻意不碰 —— 否则会掐断后台播放，那是产品语义不是泄漏。
  - `main.dart` 仍**不**调 shutdown（界面 dispose ≠ 停止播放），
    注释已同步说明释放走哪条路。

### 附带清理
- 删除死常量 `MatchConfig.minRecallCandidates`（引擎已按注释移除该门槛，
  无任何引用）。

---

## 审计中被**推翻**的疑似问题（勿照着改）

多 agent 审计产出里有 3 条高危结论经实测**不成立**，记录在此避免重复排查：

1. **「双写导致 cid 自愈失效」** ❌ → 见上面 SourceResolver 一节，实测自愈有效。
2. **「`upsertAll` 在新库上会撞 UNIQUE 冲突」** ❌ → 实测同 mid 连续两次
   批量导入正常走 UPDATE，行数=1、标题正确更新；SQLite 先命中
   `UNIQUE(qq_song_mid)`。
3. **「`match_sample` 两个索引没建」** ❌ → `schema.dart` 里
   `kCreateMatchSampleTable` 末尾那两行不是悬空字符串（Dart 相邻字面量
   会拼接），实测 14 个索引全部存在。

### 本轮结束后仍然保留的次要项
- `DiagLog._flushSync` 在内存模式（`dir == null`）下会先清空 `_pending`
  再发现写不出去，等于静默丢弃一个批次的日志；且与在途的 `flush()`
  不互斥，崩溃条目可能被后写的旧批次追加到后面、破坏时间序。
  属于「诊断日志」这一非关键路径的取舍，本轮不动。

---

## 本机音乐（SAF 目录 / 扫描 / 下载）留的坑（2026-10-11）

同一份立场：下面是**当前阶段故意不改**的，不是半成品。

1. **下载不做断点续传**。DASH 直链约 100 分钟过期，续传要处理「旧链已失效但本地
   有半截文件」的组合；当前语义是失败/取消就删掉半成品，重下从 0 开始。
2. **下载是单线程串行**。原生用 `newSingleThreadExecutor`，播放页同时对第二首歌
   的按钮是禁用态。并发的代价（配额 + IO + 播放卡顿）大于收益，除非将来加队列 UI。
3. **`_data` 路径列只用于「按目录过滤」**，不用于开文件。Android 10+ 分区存储下
   它可能读得到却打不开；播放一律用 `content://` uri。MediaStore 若在某 ROM 上不
   填 `_data`，SAF 选的目录过滤会静默失效（退化成全盘扫）——真机验证点。
4. **SAF 可写性判断读的是 `FLAG_DIR_SUPPORTS_CREATE`，不是「建个探针文件再删」**。
   后者答案更硬，但要在用户真实目录里创建并删除文件，删除失败就留下垃圾。
   代价：极少数谎报标志位的提供方要等到真正下载时才失败（那时错误会说清楚）。
5. **扫描到 0 条时不裁剪清单**。宁可留一份可能过期的列表，也不静默删光
   （MediaStore 被禁用的 ROM 返回空游标且不报错）。副作用：手机上真把歌全删了，
   app 里的本地清单要等到有一次非空扫描才会清掉。
6. **下载文件不进 MediaStore**。我们自己的 `local_audio` 记录是唯一真相，
   所以用户在系统音乐 app / 文件管理器里删掉文件后，app 这边只有等到播放失败
   才可能察觉。缺一个「播放前校验文件还在」的动作。
7. **本机音乐主路径已在真机验证**（2026-10-11，魅族 21 / Android 16，release 包）。
   SAF 选择器、MediaStore 扫描、CDN 落盘、已下载优先播本地、本机清单真实封面、
   本机歌播放取到歌词——都跑过一轮。Dart 侧 624 个用例 + `flutter build apk --release`。
   仍未覆盖的是几条边界：换目录后重启授权是否仍在、下载中途杀掉进程、
   扫描目录设得很窄时的提示文案。
8. **补全链路靠 `r.reason.startsWith('请求异常')` 区分「没网」和「没这首歌」**。
   这个前缀是 `QQMusicProvider.resolveBatch` 自己拼的字符串（它把单首异常 catch 成
   带原因的 rejection），等于两层之间有一条**没有类型保护的字符串契约**。
   改成 `BatchRejection` 带一个 `kind` 枚举才算干净。
   - **清理触发条件**：`BatchRejection` 再加一个来源字段，或接入第二个元数据源时。
9. **断网早停只在分片边界生效**，一片 6 首会全部撞完才收手。想更省就得给
   `resolveBatch` 加取消回调，但中途抛异常会把它已经解析到的结果一起丢掉——
   当前宁可多撞 3 次。
10. **只补「两个 mid 都为空」的条目**。所以「换到了 songMid 但源没给 albumMid」
    这种半截结果永远不会被重试，那首歌会长期没有封面（歌词是好的）。
    - **清理触发条件**：出现真实反馈「有词没封面」时，把 `unresolved` 的条件放宽成
      按缺的那一项分别判定，并对缺封面的走一次 `fetchDetail`。
11. **补全没有进度、结果与手动入口**。用户看到的是封面自己一首一首变出来；
    没补出来的那部分也没有「再试一次」的按钮，只能等 3 天冷却过期。
    现在能挂的位置是「我的 → 设置」那 5 行（`settings_sheets.dart`），
    加行要先想清楚值不值一行。
12. **`resolved_at` 是「尝试时刻」不是「命中时刻」**，语义上把失败也盖住了：
    查不到到底有多少本机歌曲是「源上真没有」还是「我们没试」，因为两者都只有
    `resolved_at > 0` + 空 mid。要分清楚得再加一列结果码，或让 `unresolved`
    把两者分开统计。
