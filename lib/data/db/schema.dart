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

/// 全部建表语句（含索引），按依赖顺序排列
const List<String> kCreateAll = [
  kCreateSongTable,
  kCreateVideoTable,
  kCreateBindingTable,
  kCreateLikedTable,
  kCreatePlayLogTable,
  kCreatePlayStatTable,
  kCreateTrackVolumeTable,
  ...kCreateIndexes,
];

/// 数据库版本。改动 schema 时必须同步 +1 并提供迁移。
///
/// v1 → v2：新增 `liked_song` 表（收藏持久化）
/// v2 → v3：新增 `play_log` / `play_stat` 表（播放历史与次数统计）
/// v3 → v4：新增 `track_volume` 表（每曲音量记忆，音效功能 P0）
/// v4 → v5：新增通用化列（meta_source_type/id、source_type/key/sub_key），
///          支持多种元数据源/音源；旧列照常读写（双写模式）
/// v5 → v6：Song 表新增 `singer_mid` 列（首位歌手 mid，播放页点击进歌手详情）
/// v6 → v7：Song 表新增 `singer_id` 列（首位歌手数字 ID，fetchSingerAlbums 必需）
/// v7 → v8：Song 表新增 `lyric_offset_ms` 列（歌词手动校准偏移，方案 D 歌词对齐）
const int kDbVersion = 8;

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

const String kDbName = 'audora.db';
