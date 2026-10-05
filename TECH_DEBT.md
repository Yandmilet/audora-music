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

### 7. rows.dart 直接 import qqmusic_dto.dart —— 1 处
- `lib/data/db/rows.dart`：`import '../../services/qqmusic/qqmusic_dto.dart' show QQSongMeta;`
- 用途：`SongRow.toSong()` → `coverUrl: QQSongMeta.coverUrlFor(albumMid)`
- **为什么留**：`QQSongMeta.coverUrlFor` 是纯工具方法（`'https://y.qq.com/...' + albumMid`），无状态无依赖。可以挪到 `MetaSong` DTO 上，但改动范围不值得。
- **清理触发条件**：当 MetaCover / CoverArt 抽成独立模块时。

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

### SourceResolver 缓存 key 双写
- `source_resolver.dart` 第 228 行：`row.cid == cidInt` — 仍在比较 VideoRow.cid（旧列）
- 步骤 6 后 VideoRow.cid 和 VideoRow.sourceSubKey 的值**应该**始终相同（Row.toMap 双写、fromMap 先读新列兜底旧列），但步骤 8 AudioSource.cid 已变成 getter（`int.tryParse(sourceSubKey)`），这里 `cidInt` 来自 AudioSource.cid getter，理论上没问题。需要确认 row.cid 和 cidInt 在迁移前的老库上是否始终一致。
