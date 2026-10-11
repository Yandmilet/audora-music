# 架构与数据流

## 目录结构

```
lib/
├── main.dart                  # 入口：开库 → 装配 → 加载曲库 → 启动播放
├── shell.dart                 # 应用外壳（底部 tab 导航）
├── theme.dart                 # 设计令牌（颜色 / 圆角 / 间距 / 时长）
├── models/
│   └── models.dart            # Song / AudioSource / Board / SourceStatus + kRegions
├── data/
│   ├── mock_data.dart         # 空态兜底（仅 repo==null 时装载）
│   ├── db/                    # SQLite 层（分层迁移）
│   │   ├── app_database.dart  # 单例 / PRAGMA foreign_keys / 迁移调度
│   │   ├── schema.dart        # 九表 DDL + 迁移脚本（当前 v12）
│   │   ├── rows.dart          # Row ↔ 领域对象映射
│   │   └── dao/               # Song / Video / Binding / Liked / PlayStats / Volume / MatchSample / LocalAudio
│   └── repository/
│       └── library_repository.dart  # 曲库聚合入口（读写 + 装配 + 匹配调度）
├── services/
│   ├── bilibili/              # B站 API（wbi_signer / cookie_session / api_client / dto / exception / login）
│   ├── qqmusic/               # QQ音乐（provider + dto + catalog_dto）
│   ├── metadata/              # 元数据源抽象（MetadataProvider 接口 + QQ适配器）
│   ├── source/                # 音源抽象（AudioSourceProvider 接口 + B站适配器）
│   ├── match/                 # 四阶段匹配引擎
│   │   ├── match_config.dart  # 六维权重 / 阈值 / 容差
│   │   ├── text_normalizer.dart      # 标题规范化 / 模糊匹配
│   │   ├── version_detector.dart     # 版本标识检测（live/remix/acoustic 等）
│   │   ├── title_parser.dart         # 标题解析（feat/ft./ft. 分割）
│   │   ├── match_scorer.dart  # 六维加权打分 + 降级路径
│   │   └── match_engine.dart  # 召回 → 硬过滤 → 精确校验 → 打分
│   ├── playback/              # 播放（SourceResolver + AudioPlayerController）
│   ├── lyric/                 # 歌词（LRC/TTML 解析 + 逐字字轴 + AMLL 逐字源 + 翻译）
│   ├── fx/                    # 音效（预设 + 服务）
│   ├── settings/              # 本机偏好（SettingsStore）
│   ├── net/                   # 滑动窗口限流（RateLimiter）
│   ├── diag/                  # 诊断日志
│   └── netease/               # 网易云（预留）
├── state/                     # ChangeNotifier（AppState + 叶子模块：OnlineSearch / PlayStats / BiliSession / GuessForYou / MusicDirs / LocalLibrary / Download）
├── widgets/
│   └── common.dart            # CoverArt（渐变占位）/ CoverImage（网络图压在占位上）/ SongCover / SourceBadge / MiniPlayer / EntryCard / SongRow / SwipeBack
└── screens/                   # 页面（player_screen 拆为 player/ 子目录多组件；home 拆为 home/；
                               #   列表页 song_list_page 与 local_screens 为多页共用）

plugins/
└── audora_files/              # 仓库内 Android 插件：SAF 目录选择与持久化授权 / MediaStore 音频扫描 / 下载落盘与进度回推
                               #   （宿主 Activity 必须是 audio_service 的那个，所以平台通道只能做成插件，见其文件头注释）
```

## 数据流

```
启动 → AudioService.init（前台 Service）
     → AppDatabase.open()（建表 / 迁移 / 开外键）
     → SettingsStore.open()
     → 装配 MetadataProvider + AudioSourceProvider + RateLimiter + MatchEngine
     → LibraryRepository
     → SourceResolver
     → AppState.loadLibrary()
          ├─ 曲库 / 收藏 / 播放统计 一次性读入
          └─ ⚠️ 空库就是空 —— 不回退 mock，UI 显示空状态引导

导入（两条路径）
  ├─「我的 → 导入歌曲」→ QQMusicProvider.resolveBatch（严格三重校验）
  └─「搜索页 → 在线 QQ 音乐」→ LibraryRepository.importOnline

本机文件的线上身份补全（真实封面 + 歌词的唯一入口）
  进「本地 / 下载」列表（postFrame，不阻塞）→ LocalLibraryBox.syncMissingMeta
     ├─ 先零成本回填：下载条目 → 曲库那首歌的真 mid 直接抄进 local_audio
     └─ 剩下的分片走 metadata.resolveBatch（标题+歌手+时长，串行 400ms/首）
          → 命中：写 song_mid / album_mid / resolved_at（此后离线可用）
          → 查无此歌：只写 resolved_at，冷却 3 天
          → 请求异常：什么都不标（断网不是「歌不存在」的证据），连续 3 首即收手
  播放本机歌 → 没身份就先单补这一首 → 补到则 force 重取歌词
  渲染：album_mid → QQSongMeta.coverUrlFor → CoverImage；为空/拉不到图 → CoverArt 渐变

匹配：按需（默认）/ 批量预处理
  ├─ 按需：播放时发现没音源 → 只匹配这一首（≈20 秒）
  └─ 批量：我的 →「批量匹配音源」

播放：点歌 → SourceResolver.resolve() → 落库 → just_audio 播放
     → positionStream → 累计收听时长 → PlayStatsDao（流水 + 聚合同事务）
```

## 空态契约

`repo == null`（单测 / 纯 UI 预览）才装 `MockData`；
真实运行时（`repo != null`）**库为空就显示空状态**。

早期版本空库塞 30 首 mock 歌，后果是「用户分不清已经导入成功还是看到的还是假的」。这类缺陷没有异常可抓，只能靠行为契约守住。由 `test/empty_library_test.dart` 锁死。
