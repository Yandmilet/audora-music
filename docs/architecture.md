# 架构与数据流

> 本文由原 README「目录说明（lib/）」「数据流」「空态契约」章节迁出。

---

## 目录说明（lib/）

```
lib/
├── main.dart                  # 入口 + 启动引导（开库 → 装配 → 加载曲库）+ 应用外壳
├── theme.dart                 # 设计令牌（颜色 / 圆角 / 间距 / 时长）
├── models/
│   └── models.dart            # Song / AudioSource / Board / SourceStatus + kRegions
├── data/
│   ├── mock_data.dart         # 演示数据（仅当数据层未接入时使用，见下方「空态契约」）
│   ├── db/                    # SQLite 层
│   │   ├── app_database.dart  # 开库 / 单例 / PRAGMA foreign_keys / 分层迁移
│   │   ├── schema.dart        # 六表 DDL + 迁移脚本
│   │   │                      #   song / bilibili_video / song_source_binding
│   │   │                      #   liked_song / play_log / play_stat
│   │   ├── rows.dart          # 行 ↔ 领域对象映射（SongRow / VideoRow / BindingRow）
│   │   └── dao/               # SongDao / VideoDao / BindingDao / LikedDao / PlayStatsDao
│   └── repository/
│       └── library_repository.dart  # 曲库聚合入口（读写 + 装配 + 匹配调度）
├── services/
│   ├── bilibili/              # B站 API 层
│   │   ├── wbi_signer.dart    # Wbi 签名（64 位重排表 → mixinKey → w_rid）
│   │   ├── bili_cookie_session.dart  # 三态 Cookie（匿名指纹 / 可选 SESSDATA）
│   │   ├── bili_api_client.dart      # Dio 封装（限流 + 指数退避重试）
│   │   ├── bili_api.dart      # 业务接口（搜索 / 详情 / 分P / 播放地址）
│   │   ├── bili_dto.dart      # VideoCandidate / VideoPage / ...
│   │   └── bili_exception.dart       # 风控错误码语义化
│   ├── qqmusic/               # QQ音乐 provider
│   │   ├── qqmusic_provider.dart     # search / fetchDetail / resolveFirstMatching（严格三重校验）/ resolveBatch
│   │   └── qqmusic_dto.dart          # QQSongMeta / BatchQuery / ResolvedEntry / BatchResolveResult / QQCredits
│   ├── match/                 # 四阶段匹配引擎
│   │   ├── match_config.dart  # 六维权重 / 阈值 / 容差 / 枚举
│   │   ├── text_normalizer.dart      # 标题规范化 / 模糊匹配 / 编辑距离
│   │   ├── match_scorer.dart  # 六维加权打分 + 降级路径
│   │   └── match_engine.dart  # 召回 → 硬过滤 → 精确校验 → 打分
│   └── net/
│       └── rate_limiter.dart  # 滑动窗口限流（30 次/分钟）
├── state/
│   └── app_state.dart         # 全局状态（曲库 / 播放 / 收藏 / 播放统计 / 搜索 / 导入 / 偏好）
├── widgets/
│   └── common.dart            # CoverArt / SourceBadge / MiniPlayer / SectionHeader / EmptyState
└── screens/
    ├── home_screen.dart       # 主页：搜索 / 随便听一下 / 新歌推荐 / 排行榜
    ├── mine_screen.dart       # 我的：资料 / 数据 / 收藏与本地 / 音源匹配管理 / 设置
    ├── player_screen.dart     # 播放页：黑胶 + 歌词 + 进度 + 音源详情
    ├── search_screen.dart     # 搜索页：历史 / 常听 / 本地结果 + 在线 QQ 音乐结果
    ├── import_flow.dart       # 导入入口（首页 / 搜索 / 我的 共用同一份行为）
    └── api_self_check_page.dart  # API 自检页（kApiSelfCheckMode 开启时进入）
```

---

## 数据流

```
启动 → AudioService.init（前台 Service）
     → AppDatabase.open()（建表 / 迁移 / 开外键）
     → SettingsStore.open()（本机偏好）
     → 装配 RateLimiter + BiliApiClient + MatchEngine + QQMusicProvider
     → LibraryRepository
     → SourceResolver（接上 repo，用于失效重匹配）
     → AppState.loadLibrary()
          ├─ 曲库 / 收藏 / 播放统计 一次性读入
          └─ ⚠️ 空库就是空 —— 不回退 mock，UI 显示空状态引导

导入（两条路径，都落真实 song_mid）
  ├─「我的 → 导入歌曲」：每行「歌名 - 歌手」
  │    → QQMusicProvider.resolveBatch（严格三重校验：标题互含 + 歌手互含 + 时长容差）
  └─「搜索页 → 在线 QQ 音乐」：搜到直接点「导入」
       → LibraryRepository.importOnline(List<OnlineSong>)
  → SongRow 落库（mid 取值顺序：真实 songMid > refId > local:title|artist）

匹配：按需（默认路径）/ 批量预处理
     ├─ 按需：播放时发现没音源 → AppState.ensurePlayableSource（只匹配这一首，~20 秒）
     │        → 成功后就地替换播放队列里的旧对象 → 继续解析播放
     │        ⚠️ 已有音源的歌直接返回，0 次请求（见设计要点 10）
     └─ 批量：我的 →「批量匹配音源」→ LibraryRepository.matchAllUnmatched
     → MatchEngine.match（召回 → 硬过滤 → 预筛 → 精确校验 → 六维打分）
     → BindingDao.saveMatch（激活唯一性在一个事务内保证）
     → AppState.refreshLibrary()（按 key 保留播放位置 + 同步队列对象）

播放：点歌 → SourceResolver.resolve()
     → URL 有效？用缓存 : 调 BiliApi.fetchAudioStream(qualityCeiling:)
     → pickBestAudio(ceiling) 挑流 → 落库 → just_audio 播放
     → positionStream → 累计收听时长 → PlayStatsDao.recordPlay（流水 + 聚合同事务）
```

---

## 空态契约（重要，别改回去）

`repo == null`（单测 / 纯 UI 预览）才装 `MockData`；
真实运行时（`repo != null`）**库为空就显示空状态**。

> 早期版本用 mock 给空库兜底，后果是「首页显示 30 首假歌、用户以为已经导入了」，
> 而且导入真歌后也看不出区别。这类**静默填假数据**没有任何异常可抓，
> 只能靠断言行为契约守住 —— 见 `test/empty_library_test.dart`。
