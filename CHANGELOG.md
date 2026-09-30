# Changelog

本项目所有显著变更将记录在本文件。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

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

- 204 项单元 / 组件测试全部通过；真机联网冒烟测试（`integration_test/live_smoke_test.dart`）

### 工程化

- 按 GitHub 标准整理仓库：README 瘦身、文档拆分至 `docs/`、
  补充 LICENSE (MIT)、CHANGELOG、CI 工作流、Issue / PR 模板、`.gitattributes`
- 构建脚本归位 `scripts/build-arm64.bat`
