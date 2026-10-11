/// SQLite 表结构定义（对应设计文档 3.1 / 3.2 / 3.3）。
///
/// ## 建表的三条原则（来自设计文档）
/// 1. **时长统一用毫秒 Int**：QQ音乐返回 `interval` 是秒，入库时 ×1000；
///    B站 `timelength` 本身就是毫秒。单位对齐才不会换算错。
/// 2. **`artists` 保留原始顺序**：首位是主唱，直接影响匹配权重，不能排序。
/// 3. **绑定关系独立建表**：一首歌可能绑定多个候选音源，
///    且 `score_detail` 要存 JSON 供后续调参——塞进 Song 表就没地方放了。
library;

class Tables {
  Tables._();

  static const song = 'song';
  static const video = 'bilibili_video';
  static const binding = 'song_source_binding';
  static const liked = 'liked_song';
  static const playLog = 'play_log';
  static const playStat = 'play_stat';
  static const trackVolume = 'track_volume';
  static const matchSample = 'match_sample';
  static const localAudio = 'local_audio';
}

/// ── 表 1：Song（设计文档 3.1）────────────────────────────────
const String kCreateSongTable = '''
CREATE TABLE ${Tables.song} (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  qq_song_mid       TEXT    NOT NULL,
  meta_source_type  TEXT    NOT NULL DEFAULT 'qq',
  meta_source_id    TEXT    NOT NULL DEFAULT '',
  title             TEXT    NOT NULL,
  artists           TEXT    NOT NULL,
  album             TEXT    NOT NULL DEFAULT '',
  album_mid         TEXT    NOT NULL DEFAULT '',
  singer_mid        TEXT    NOT NULL DEFAULT '',
  singer_id         INTEGER,
  lyricist          TEXT,
  composer          TEXT,
  arranger          TEXT,
  genre             TEXT,
  release_date      INTEGER,
  duration_ms       INTEGER NOT NULL DEFAULT 0,
  cover_seed        INTEGER NOT NULL DEFAULT 0,
  lyric_offset_ms   INTEGER NOT NULL DEFAULT 0,
  lyric_slope       REAL    NOT NULL DEFAULT 1.0,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL,
  UNIQUE (qq_song_mid),
  UNIQUE (meta_source_type, meta_source_id)
);
''';

/// ── 表 2：BilibiliVideo（设计文档 3.2）───────────────────────
///
/// `cid` 是 playurl 接口的必需参数，且多分P视频的 (bvid, cid) 才是完整键，
/// 所以 bvid 作主键但 cid 必须独立存（不能用 bvid 反查）。
const String kCreateVideoTable = '''
CREATE TABLE ${Tables.video} (
  bvid                  TEXT    PRIMARY KEY,
  cid                   INTEGER NOT NULL,
  source_type           TEXT    NOT NULL DEFAULT 'bilibili',
  source_key            TEXT    NOT NULL DEFAULT '',
  source_sub_key        TEXT    NOT NULL DEFAULT '',
  title                 TEXT    NOT NULL,
  author                TEXT    NOT NULL DEFAULT '',
  mid                   INTEGER NOT NULL DEFAULT 0,
  duration_ms           INTEGER NOT NULL DEFAULT 0,
  typename              TEXT    NOT NULL DEFAULT '',
  tag                   TEXT,
  description           TEXT,
  play_count            INTEGER NOT NULL DEFAULT 0,
  pubdate               INTEGER NOT NULL DEFAULT 0,
  fetched_at            INTEGER NOT NULL,
  audio_url             TEXT,
  audio_url_expire_at   INTEGER,
  audio_quality_id      INTEGER,
  audio_bitrate         INTEGER,
  available             INTEGER NOT NULL DEFAULT 1,
  unavailable_reason    TEXT
);
''';

/// ── 表 3：SongSourceBinding（设计文档 3.3）───────────────────
///
/// `score_detail` 存 JSON —— 这是整个算法可调优的关键。
/// 每次匹配都留下「为什么给这个分」，积累几十条后就能看出哪个维度权重设错了
/// （设计文档 5.3 给了对应的 SQL 分析示例）。
const String kCreateBindingTable = '''
CREATE TABLE ${Tables.binding} (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  song_id       INTEGER NOT NULL,
  bvid          TEXT    NOT NULL,
  source_type   TEXT    NOT NULL DEFAULT 'bilibili',
  source_key    TEXT    NOT NULL DEFAULT '',
  is_active     INTEGER NOT NULL DEFAULT 0,
  match_score   REAL    NOT NULL DEFAULT 0,
  confidence    TEXT    NOT NULL DEFAULT 'REVIEW',
  score_detail  TEXT,
  match_type    TEXT    NOT NULL DEFAULT 'AUTO_MATCHED',
  matched_at    INTEGER NOT NULL,
  note          TEXT,
  UNIQUE (song_id, bvid),
  FOREIGN KEY (song_id) REFERENCES ${Tables.song}(id) ON DELETE CASCADE,
  FOREIGN KEY (bvid)    REFERENCES ${Tables.video}(bvid) ON DELETE CASCADE
);
''';

/// ── 表 4：LikedSong（收藏 / 喜欢）────────────────────────────
///
/// ## 为什么不直接在 song 表加一个 `liked` 列
/// 收藏是**用户行为**，不是歌曲的元数据属性。两者生命周期不同：
///   - 重新导入同一首歌（upsert）会覆盖 song 行的字段——若 liked 在那张表，
///     用户的红心会被一次导入悄悄抹掉。
///   - 将来要支持「收藏时间排序」「收藏但不在库里的歌」，独立表更好扩展。
/// 独立表 + 外键 CASCADE：歌被删时收藏自动清理（`PRAGMA foreign_keys=ON`
/// 已在 `AppDatabase.open` 的 onConfigure 里打开）。
const String kCreateLikedTable = '''
CREATE TABLE ${Tables.liked} (
  song_id     INTEGER PRIMARY KEY,
  liked_at    INTEGER NOT NULL,
  FOREIGN KEY (song_id) REFERENCES ${Tables.song}(id) ON DELETE CASCADE
);
''';

/// ── 表 5：PlayLog（播放流水）─────────────────────────────────
///
/// ## 为什么「流水」与「统计」分两张表
/// 两者回答的问题不同、增长方式也不同：
///   - `play_log` 是**事件流**（谁在什么时候播了什么），会无限增长，
///     用于「最近播放」「播放时段分布」。必须能定期裁剪而不影响统计。
///   - `play_stat` 是**聚合**（每首歌的累计次数 / 最近播放时间），
///     一行对一首歌，体量受曲库大小约束，用于「常听排行」。
///
/// 如果只留流水表，「常听」每次都要 `GROUP BY song_id` 全表扫；
/// 只留聚合表，则做不出「最近播放」列表。两张表各司其职。
///
/// ## 为什么要记 [played_ms]
/// 「播放次数」若只看「点了一下」会被误计数——用户点开又立刻切走
/// 不该算一次。落库时带上实际播放时长，统计时用它过滤
/// （见 `PlayStatsDao.countingThresholdMs`）。
const String kCreatePlayLogTable = '''
CREATE TABLE ${Tables.playLog} (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  song_id       INTEGER NOT NULL,
  played_at     INTEGER NOT NULL,
  played_ms     INTEGER NOT NULL DEFAULT 0,
  source_bvid   TEXT,
  FOREIGN KEY (song_id) REFERENCES ${Tables.song}(id) ON DELETE CASCADE
);
''';

/// ── 表 6：PlayStat（每首歌的播放统计）────────────────────────
///
/// `song_id` 作主键：一行对一首歌，`play_count` 是**有效播放**次数
/// （达到时长门限的那些），[last_played_at] 用于「最近常听」排序。
const String kCreatePlayStatTable = '''
CREATE TABLE ${Tables.playStat} (
  song_id         INTEGER PRIMARY KEY,
  play_count      INTEGER NOT NULL DEFAULT 0,
  total_played_ms INTEGER NOT NULL DEFAULT 0,
  last_played_at  INTEGER NOT NULL,
  FOREIGN KEY (song_id) REFERENCES ${Tables.song}(id) ON DELETE CASCADE
);
''';

/// ── 表 7：TrackVolume（每曲音量记忆）─────────────────────────
///
/// ## 为什么它进 audora.db 而不是 SharedPreferences
/// 「这首歌要放多响」是**跟着歌走的用户数据**（与 liked/play_stat 同
/// 性质），不是本机偏好——换设备时理应跟着曲库一起备份迁移；且
/// shared_preferences 是整块加载，积累几千首歌的音量会拖慢启动。
///
/// ## 为什么需要这张表（2026-09-30 音效功能 P0）
/// B站音源由 UP 自行混音，无平台级响度归一化，连播时忽大忽小。
/// 自动 LUFS 归一需要测量响度（RECORD_AUDIO 权限或原生管线改造），
/// 而「用户调一次、切歌自动恢复」以近零成本覆盖最高频的痛感。
const String kCreateTrackVolumeTable = '''
CREATE TABLE ${Tables.trackVolume} (
  song_id     INTEGER PRIMARY KEY,
  volume      REAL    NOT NULL DEFAULT 1.0,
  updated_at  INTEGER NOT NULL,
  FOREIGN KEY (song_id) REFERENCES ${Tables.song}(id) ON DELETE CASCADE
);
''';

/// v4 → v5：通用化列，支持多种元数据源/音源
///
/// ## 为什么先加列 + 双写，不直接删旧列
/// - **无损**：用户已有曲库行一夜之间多了套通用列，但旧列照常读写
/// - **可滚**：新列出问题时可以继续按旧列跑，不阻塞业务
/// - **步骤 7 再接**：等领域模型也有了 sourceType/sourceKey，就可以逐步让
///   新写入只走通用列；旧列直到确认没人用了（步骤 8）再删
///
/// 迁移脚本：每个表只加列 + 回填，不删不重建。
const List<String> kMigrateV4ToV5 = [
  // Song 表：元数据源通用化
  "ALTER TABLE ${Tables.song} ADD COLUMN meta_source_type TEXT NOT NULL DEFAULT 'qq';",
  "ALTER TABLE ${Tables.song} ADD COLUMN meta_source_id   TEXT NOT NULL DEFAULT '';",
  "UPDATE ${Tables.song} SET meta_source_type = 'qq', meta_source_id = qq_song_mid;",

  // Video 表：音源通用化
  "ALTER TABLE ${Tables.video} ADD COLUMN source_type    TEXT NOT NULL DEFAULT 'bilibili';",
  "ALTER TABLE ${Tables.video} ADD COLUMN source_key     TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE ${Tables.video} ADD COLUMN source_sub_key TEXT NOT NULL DEFAULT '';",
  "UPDATE ${Tables.video} SET source_type = 'bilibili', source_key = bvid, source_sub_key = CAST(cid AS TEXT);",

  // Binding 表：音源通用化（song_source_binding 重命名为 source_binding，
  // 但 SQLite 不支持 ALTER TABLE RENAME，且改表名牵连 DAO SQL，
  // 所以这里**暂不改表名**，只加通用列。步骤 7 接领域模型后再评估要不要迁移表名）
  "ALTER TABLE ${Tables.binding} ADD COLUMN source_type TEXT NOT NULL DEFAULT 'bilibili';",
  "ALTER TABLE ${Tables.binding} ADD COLUMN source_key  TEXT NOT NULL DEFAULT '';",
  "UPDATE ${Tables.binding} SET source_type = 'bilibili', source_key = bvid;",

  // Song 表建表语句也要更新（新安装直接带通用列）
  // ⚠️ SQLite 不支持 ALTER TABLE 加 UNIQUE，所以建表时把 (qq_song_mid) 改成
  // (meta_source_type, meta_source_id) 双列 UNIQUE —— 但旧库已经有 UNIQUE(qq_song_mid)
  // 了，ALTER TABLE 加列不能改约束，所以旧库保持 (qq_song_mid) 唯一，
  // 新库用 (meta_source_type, meta_source_id) 唯一。两者效果等价：
  //   - 旧库：qq_song_mid 对 QQ 歌唯一，meta_source_type/meta_source_id 只是冗余副本
  //   - 新库：(meta_source_type, meta_source_id) 对任何源唯一
  // 步骤 8 统一后两套约束会合并。
];

/// 索引：按「找某首歌的激活音源」「找待匹配的歌」「找失效音源」三种查询建
/// ── 表 9：LocalAudio（本机音频文件：自带扫描 + app 下载）───────
///
/// ## 为什么单独一张表，而不是给 song 加个 local_path 列
/// 1. **两个列表必须隔开**（产品要求）：「本地」是扫描手机自带歌曲，
///    「下载」是 app 落盘的文件。混在 song 里就得靠一个布尔列分家，
///    且清理逻辑会互相误伤——重扫一遍本机不该把下载记录抹掉。
/// 2. **主键语义不同**：`song` 的一行是「一首歌」（title|artist + QQ mid），
///    这张表的一行是「一个文件」。同一首歌可能既有手机里的 FLAC 又有
///    app 下的 MP3，塞进 song 就必须丢掉其中一个。
/// 3. song 的行靠 `qq_song_mid` upsert，本机文件靠 uri upsert，两套
///    唯一性放一张表里只会互相打架。
///
/// ## 为什么 uri 是唯一键、path 只作展示
/// MediaStore 的 `content://media/external/audio/media/<id>` 与 SAF 文档 uri
/// 都能进这一列，且都是系统认可的稳定标识。分区存储（Android 10+）下
/// `path` 可能读得到路径却打不开文件，所以**播放一律用 uri**。
///
/// ## song_id 是这座桥
/// 下载条目记上它来自曲库的哪首歌，「已下载优先播本地」才能一步查到
/// （见 `LocalAudioDao.downloadedOfSong`）。扫描条目没有这个对应关系，留 null。
const String kCreateLocalAudioTable = '''
CREATE TABLE ${Tables.localAudio} (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  kind            TEXT    NOT NULL CHECK (kind IN ('local','download')),
  uri             TEXT    NOT NULL UNIQUE,
  path            TEXT    NOT NULL DEFAULT '',
  title           TEXT    NOT NULL,
  artist          TEXT    NOT NULL DEFAULT '',
  album           TEXT    NOT NULL DEFAULT '',
  duration_ms     INTEGER NOT NULL DEFAULT 0,
  size_bytes      INTEGER NOT NULL DEFAULT 0,
  -- 文件系统/媒体库时间（秒）。导入工具常写任意值，只当参考。
  mtime_sec       INTEGER NOT NULL DEFAULT 0,
  -- 我们第一次 / 最近一次在扫描里见到它。last_seen 用来标「文件已不在」。
  first_seen      INTEGER NOT NULL,
  last_seen       INTEGER NOT NULL,
  -- 下载条目回指曲库的歌；扫描条目为 null。
  song_id         INTEGER REFERENCES ${Tables.song}(id) ON DELETE SET NULL,
  -- 下载时用的 B站音质 ID（30280 / 30232 …）；扫描条目为 0。
  quality_id      INTEGER NOT NULL DEFAULT 0,
  -- v12：本机文件的「线上门户」。文件本身没有 mid，但按 标题+歌手+时长
  -- 能去元数据源换回一个真实身份，换到就缓存下来：
  --   song_mid  → 取歌词（QQ 的 songMid，歌词接口只认它）
  --   album_mid → 拼封面 URL（派生值，不落 URL 本身，与 song 表同一口径）
  -- 换不到就是空串，UI 继续走渐变占位。
  song_mid        TEXT    NOT NULL DEFAULT '',
  album_mid       TEXT    NOT NULL DEFAULT '',
  -- 上一次**尝试**补全的时刻（秒），0 = 从没试过。命中与否都会盖这个时刻：
  -- 没命中的歌下次进页面要不要再打一次请求，靠它做冷却，不靠内存记仇。
  resolved_at     INTEGER NOT NULL DEFAULT 0
);
''';

const List<String> kCreateIndexes = [
  'CREATE INDEX idx_binding_song_active ON ${Tables.binding}(song_id, is_active);',
  'CREATE INDEX idx_binding_confidence ON ${Tables.binding}(confidence);',
  'CREATE INDEX idx_video_available ON ${Tables.video}(available);',
  'CREATE INDEX idx_song_created ON ${Tables.song}(created_at);',
  'CREATE INDEX idx_liked_at ON ${Tables.liked}(liked_at DESC);',
  // 最近播放按时间倒序取，流水表会很大，这个索引是必须的
  'CREATE INDEX idx_playlog_at ON ${Tables.playLog}(played_at DESC);',
  'CREATE INDEX idx_playlog_song ON ${Tables.playLog}(song_id);',
  // 常听排行按次数倒序
  'CREATE INDEX idx_playstat_count ON ${Tables.playStat}(play_count DESC);',
];

/// v11 新增的索引（跟着 local_audio 一起来）。
///
/// 单独一组而不是并到 [kCreateIndexes] 里，是为了让「造一个升级前的 v10 库」
/// 的测试能精确复刻旧形状——不然它得把历史索引抄一份，而抄的那份一旦
/// 与这里不同步，迁移测试就是在测一个不存在的库。
const List<String> kCreateLocalAudioIndexes = [
  'CREATE INDEX idx_local_kind ON ${Tables.localAudio}(kind, last_seen DESC);',
  'CREATE INDEX idx_local_song ON ${Tables.localAudio}(song_id);',
];

/// 全部建表语句（含索引），按依赖顺序排列
const List<String> kCreateAll = [
  kCreateSongTable,
  kCreateVideoTable,
  kCreateBindingTable,
  kCreateLikedTable,
  kCreatePlayLogTable,
  kCreatePlayStatTable,
  kCreateTrackVolumeTable,
  kCreateMatchSampleTable, // v9；漏掉会让全新安装静默零采集（只有升级路径有这张表）
  kCreateLocalAudioTable, // v11；同理——全新装机必须就有这张表
  ...kCreateIndexes,
  ...kCreateLocalAudioIndexes,
];

/// 数据库版本。改动 schema 时必须同步 +1 并提供迁移。
///
/// v1 → v2：新增 `liked_song` 表（收藏持久化）
/// v2 → v3：新增 `play_log` / `play_stat` 表（播放历史与次数统计）
/// v3 → v4：新增 `track_volume` 表（每曲音量记忆，音效功能 P0）
/// v4 → v5：新增通用化列（meta_source_type/id、source_type/key/sub_key），
///          支持多种元数据源/音源；旧列照常读写（双写模式）
/// v7 → v8：Song 表新增 `lyric_offset_ms` 列（歌词手动校准偏移，方案 D 歌词对齐）
/// v8 → v9：新建 match_sample 表（V0.9 数据闭环 — Golden Dataset）
/// v9 → v10：Song 表新增 `lyric_slope` 列（两点歌词校准的斜率，默认 1.0）
/// v10 → v11：新建 local_audio 表（本机音频文件：自带扫描 + app 下载）
/// v11 → v12：local_audio 加 song_mid / album_mid / resolved_at
///            （本机文件补全线上身份，用来取真实封面与歌词）
const int kDbVersion = 12;

/// 迁移脚本：v1 → v2
///
/// 只**加表**，不动既有数据。用户曲库与绑定关系一律保留。
const List<String> kMigrateV1ToV2 = [
  kCreateLikedTable,
  'CREATE INDEX idx_liked_at ON ${Tables.liked}(liked_at DESC);',
];

/// 迁移脚本：v2 → v3
const List<String> kMigrateV2ToV3 = [
  kCreatePlayLogTable,
  kCreatePlayStatTable,
  'CREATE INDEX idx_playlog_at ON ${Tables.playLog}(played_at DESC);',
  'CREATE INDEX idx_playlog_song ON ${Tables.playLog}(song_id);',
  'CREATE INDEX idx_playstat_count ON ${Tables.playStat}(play_count DESC);',
];

/// 迁移脚本：v3 → v4（只加表，不动既有数据）
const List<String> kMigrateV3ToV4 = [
  kCreateTrackVolumeTable,
];

/// 迁移脚本：v5 → v6（加 singer_mid 列）
///
/// 只加列，不动既有数据。旧数据 singer_mid 默认空字符串。
/// 下次播放时若从目录类入口点歌（persistOnline 带 singerMid），
/// 会覆盖 upsert 把新列填上。
const List<String> kMigrateV5ToV6 = [
  'ALTER TABLE ${Tables.song} ADD COLUMN singer_mid TEXT NOT NULL DEFAULT \'\';',
];

/// 迁移脚本：v6 → v7（加 singer_id 列）
///
/// singer_id 是 fetchSingerAlbums 的必需数字 ID，空值时 SingerDetailScreen 降级。
const List<String> kMigrateV6ToV7 = [
  'ALTER TABLE ${Tables.song} ADD COLUMN singer_id INTEGER;',
];

/// 迁移脚本：v7 → v8（加 lyric_offset_ms 列）
///
/// 歌词手动校准偏移（毫秒）。默认 0 = 不偏移，由用户在播放页歌词面板微调后写入。
const List<String> kMigrateV7ToV8 = [
  'ALTER TABLE ${Tables.song} ADD COLUMN lyric_offset_ms INTEGER NOT NULL DEFAULT 0;',
];

/// ── 表 8：match_sample（V0.9 Golden Dataset）───────────────────────
///
/// ## 为什么需要独立表
/// binding 表只存最终激活结果——它是"结果"而非"过程"。
/// Golden Dataset 需要存**每次匹配的完整候选打分快照**：
/// song + all candidates（bvid + title + 各维度分数 + total + confidence）+
/// 最终决策 + 后续用户反馈（绑定/推翻）。
///
/// 这些数据是后续调参的唯一基准——没有它，P0/P1 的改进全凭感觉。
///
/// ## 写入时机
/// MatchEngine.match() 返回后立即写入（非事务、失败静默）。
/// 后续 library_repository 激活绑定时回填 user_decision。
const String kCreateMatchSampleTable = '''
CREATE TABLE ${Tables.matchSample} (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at      INTEGER NOT NULL,

  -- 歌曲快照（匹配时的 Song 字段）
  song_id         INTEGER NOT NULL,
  song_title      TEXT    NOT NULL,
  song_artist     TEXT    NOT NULL,
  song_album      TEXT    NOT NULL,
  song_duration   INTEGER NOT NULL,  -- 毫秒
  song_release    INTEGER,           -- unix ms，可空

  -- 匹配结果
  best_bvid       TEXT    NOT NULL,
  best_title      TEXT    NOT NULL,
  best_total      REAL    NOT NULL,
  best_confidence TEXT    NOT NULL,    -- AUTO / REVIEW / REJECTED
  best_detail     TEXT    NOT NULL,    -- JSON: S1~S6 + penalty + contradiction

  -- 候选池快照（JSON 数组）
  candidates_json TEXT    NOT NULL,    -- [{bvid, title, total, detail, confidence}, ...]
  margin          REAL    NOT NULL DEFAULT 0.0,  -- best - runnerUp

  -- 用户反馈回填（初始 null）
  user_decision   TEXT,              -- 'accept' / 'reject' / null(待决策)
  decision_bvid   TEXT,              -- 用户最终绑定的 bvid（可能 ≠ best_bvid）
  decided_at      INTEGER,
  FOREIGN KEY (song_id) REFERENCES ${Tables.song}(id) ON DELETE CASCADE
);
'''
  'CREATE INDEX idx_match_sample_song ON ${Tables.matchSample}(song_id);'
  'CREATE INDEX idx_match_sample_created ON ${Tables.matchSample}(created_at DESC);';

/// v8 → v9：新建 match_sample 表（V0.9 Golden Dataset）
const List<String> kMigrateV8ToV9 = [
  kCreateMatchSampleTable,
];

/// v9 → v10：加 lyric_slope 列（两点歌词校准的斜率）
///
/// 歌词映射 `lrcMs = realMs * slope + offsetMs`：
/// slope=1.0 是纯平移（片头/片尾/尾奏场景）；用户在两个位置各做一次
/// 「本句对齐」后算出非 1 斜率，覆盖 UP 主整曲变速场景。
/// 老数据默认 1.0，与旧的纯偏移校准行为兼容。
const List<String> kMigrateV9ToV10 = [
  'ALTER TABLE ${Tables.song} ADD COLUMN lyric_slope REAL NOT NULL DEFAULT 1.0;',
];

/// v10 → v11：新建 local_audio 表（本机音频文件：自带扫描 + app 下载）
///
/// 只加表加索引，不动任何既有数据。老装机用户升上来是一张空表，
/// 第一次进「本地」点扫描才会有内容——这本来就是新功能，不存在回填。
const List<String> kMigrateV10ToV11 = [
  kCreateLocalAudioTable,
  ...kCreateLocalAudioIndexes,
];

/// v11 → v12：local_audio 加 `song_mid` / `album_mid` / `resolved_at`
///
/// 本机文件要能对上真实封面与歌词，前提是记住「这个文件对应线上哪首歌」。
/// 三条 ADD COLUMN 都带默认值，旧行升上来就是「没匹配过」，语义天然正确。
const List<String> kMigrateV11ToV12 = [
  "ALTER TABLE ${Tables.localAudio} ADD COLUMN song_mid TEXT NOT NULL DEFAULT '';",
  "ALTER TABLE ${Tables.localAudio} ADD COLUMN album_mid TEXT NOT NULL DEFAULT '';",
  'ALTER TABLE ${Tables.localAudio} ADD COLUMN resolved_at INTEGER NOT NULL DEFAULT 0;',
];

const String kDbName = 'audora.db';
