# Changelog

本项目所有显著变更将记录在本文件。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增

- **歌手库筛选**：地区（全部 / 华语 / 日本 / 韩国 / 欧美）、类型（全部 / 男 / 女 / 组合）、
  首字母（右侧竖直索引条：热 / # / A-Z）三个维度可任意组合
- 歌手列表改用 `Music.SingerListServer/get_singer_list`，筛选由服务端真实生效
  （旧接口 `v8.fcg?channel=singer` 的 `area`/`key` 参数被服务端忽略，只能显示标签）
- 歌手列表展示**真实头像**（服务端 `singer_pic`，约 6.5 KB/张）；加载失败回退首字母圆片
- 「华语」= 内地 + 港台两档合并混排（服务端无「中文」单档，周杰伦等港台歌手不在内地档）

### 修复

- 华语档列表行尾的「内地 / 港台」标签不显示：反查函数遍历 `kSingerAreas` 找单项，
  而华语是把两档合成的一项 `('华语', [200, 2])`，列表里没有 `[200]` / `[2]` 单项
  → 反查恒为 `null`。改为用独立的 `kSingerSubAreaLabels` 维护「华语的组成档」（真机装机验证发现）
- 华语档尾部混入其他档的越界数据：服务端对越过 `total` 的 `sin` **仍会返回数据**
  （实测港台 `total=1538`，第 22 页仍返回 80 条；内地 `total=3364`，第 44 页返回 80 条）。
  单档时 `hasMore` 在 `total` 处收口所以看不出来，多档合并时港台那一路会把越界数据带进
  内地仍在产出的页里（真机表现：华语第 43 页 84 条，应为 4 条）。改为按各档 `total` 主动截断
  （真机复验：第 43 页 4 条且全部 `areaId == 200`）
- 榜单卡片预览行歌手名过长导致右侧溢出（真机上表现为卡片右缘黄黑相间 overflow 条纹 +
  竖排红字「RIGHT OVERFLOWED BY 143 PIXELS」遮盖内容）：`Row` 内歌手名 `Text` 未加
  `Expanded`/`Flexible` 约束，按 intrinsic 宽度布局溢出。改为歌名 `Expanded(flex:3)` +
  歌手名 `Flexible(flex:2, textAlign:right)` 且均 `TextOverflow.ellipsis`；`ToplistCard`
  提为公开类便于单测。`test/toplist_card_overflow_test.dart` 用实抓欧美榜第 39 周前 3 行
  （第 2 行歌手串 `HEARTSTEEL (心之钢)/英雄联盟/伯贤 (백현)/Connor Price/Anderson .Paak/Nic D`
  长达 70+ 字符）验证，280dp 窄屏同样无溢出
- 播放中整树每秒多次重建导致 UI 切 tab / 滑列表卡顿迟滞：`positionStream` 每推进一秒就
  `notifyListeners()`，根部 `AnimatedBuilder` 订阅整个 `AppState` → 重建
  `MaterialApp→Shell→IndexedStack→Home→4 个 tab`。将秒级进度拆为独立
  `ValueNotifier<int> posTick`（`_position` 走 setter 随写随发，原有 11 处赋值点无需逐个改），
  播放页进度条 / 歌词 / 迷你条改用 `ValueListenableBuilder` 局部订阅；索引条拖动高亮 `_dragId`
  亦改 `ValueNotifier<int?>` 避免整 tab 重建；歌手头像 `Image.network` 加 `cacheWidth` 按 40dp
  解码。`test/playback_rebuild_test.dart` 断言播放推进时 `AppState` 监听者调用次数为 0、
  低频事件（切歌 / 播放暂停 / 歌词替换）仍 `notifyListeners()`
- 安装包仅出 arm64 未固化到 Gradle：`flutter run`/IDE 不带 `--target-platform` 时默认编
  3 个 ABI（`armeabi-v7a`/`arm64-v8a`/`x86_64`）使包翻倍。在 `defaultConfig` 内新增
  `ndk { abiFilters.clear(); abiFilters += "arm64-v8a" }`（belt-and-suspenders，
  与既有 `packaging.jniLibs.excludes` 双保险）。`flutter build apk --release` 实测 19.7 MB、
  `lib/` 仅 `arm64-v8a`

### 测试

- 新增 `test/singer_filter_test.dart`（筛选取值表 / 别名拆分 / 头像归一 / 索引条命中计算 / 华语成员档标签）
- 新增 `test/singer_list_provider_test.dart`（筛选参数编码 / 多档交错合并 / 分页 hasMore 边界）
- 新增 `integration_test/live_singer_filter_test.dart`（真机联网验证筛选真实生效、头像可取、尾部不截断）
- 新增 `test/toplist_card_overflow_test.dart`（欧美榜超长拼接歌手名在常规 / 280dp 窄屏下均无 RenderFlex 溢出，歌名与歌手名不被挤成 0 宽）
- 新增 `test/playback_rebuild_test.dart`（播放推进不触发 `AppState` 整树重建、秒级进度经 `posTick` 局部推送、`seekTo` 后 `posTick.value == position`）

## [2.0.0] - 2026-09-30

### 新增

- 音源匹配引擎：四阶段流水线（召回 → 硬过滤 → 精确校验 → 六维加权打分），
  `enrichTopK` 预筛将单首匹配从 ≈68 秒降至 ≈20 秒
- 按需匹配：点播时只匹配当前歌曲，已有音源短路（0 次请求）
- QQ音乐元数据接入：搜索 / 详情 / 批量导入（严格三重校验）
- B站音源接入：Wbi 签名、匿名指纹 Cookie 三态会话、滑动窗口限流（30 次/分钟）
- 播放：just_audio（Media3/ExoPlayer）+ audio_service 后台播放、通知栏 / 锁屏控制
- 收藏（`liked_song`）与播放统计（`play_log` 流水 / `play_stat` 聚合）独立建表
- 歌词拉取与翻译
- 音源状态三态徽章（已匹配 / 待确认 / 无音源）+ 待确认项人工复核页
- 点播 REVIEW 兜底激活（≥0.60 最高分候选）与全局 toast 错误提示
- 数据库 v1→v2→v3 分层迁移

### 测试

- 单元 / 组件测试全部通过；真机联网冒烟测试（`integration_test/live_smoke_test.dart`）

### 工程化

- 构建脚本归位 `scripts/build-arm64.bat`
