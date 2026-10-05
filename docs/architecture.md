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
│   │   ├── schema.dart        # 六表 DDL + 迁移脚本
│   │   ├── rows.dart          # Row ↔ 领域对象映射
│   │   └── dao/               # SongDao / VideoDao / BindingDao / LikedDao / PlayStatsDao / VolumeDao
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
│   ├── lyric/                 # 歌词（LRC 解析 + 翻译）
│   ├── fx/                    # 音效（预设 + 服务）
│   ├── settings/              # 本机偏好（SettingsStore）
│   ├── net/                   # 滑动窗口限流（RateLimiter）
│   ├── diag/                  # 诊断日志
│   └── netease/               # 网易云（预留）
├── state/                     # ChangeNotifier（AppState / OnlineSearch / PlayStats / BiliSession）
├── widgets/
│   └── common.dart            # CoverArt / SourceBadge / MiniPlayer / SectionHeader / EmptyState
└── screens/                   # 页面（player_screen 拆为 player/ 子目录多组件；home 拆为 home/）
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
