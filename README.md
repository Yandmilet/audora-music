# Audora

个人自用音乐播放器 —— Flutter + Android。

元数据来自 QQ音乐，音源来自 B站视频，通过四阶段流水线自动匹配。

![Flutter](https://img.shields.io/badge/Flutter-3.47-02569B?logo=flutter)
![Android](https://img.shields.io/badge/Android-7.0%2B-3DDC84?logo=android)
![Tests](https://img.shields.io/badge/tests-624%2F624_passing-brightgreen)

## 功能

- **在线搜索与导入**：QQ音乐元数据，严格三重校验（标题互含 + 歌手互含 + 时长容差）
- **自动音源匹配**：四阶段流水线（召回 → 硬过滤 → 精确校验 → 六维加权打分）
- **按需匹配**：点哪首播哪首，单首匹配 ≈20 秒；批量预处理可选
- **本机音乐**：扫描手机自带歌曲（MediaStore）+ app 内下载，两份清单永不混排；
  已下载优先播本地文件（一次请求都不发）
- **本机歌曲自动补真封面与歌词**：按 标题+歌手+时长 换一次线上身份并缓存，
  联网出真图、断网出渐变占位
- **后台播放**：audio_service 前台 Service，通知栏/锁屏媒体控制
- **收藏与播放统计**：独立建表，流水与聚合分离
- **歌词**：自动拉取 + 翻译 + AMLL 逐字（真实字轴）扫光，逐行/均分两级兜底
- **音源状态可视化**：已匹配/待确认/无音源 三态徽章
- **歌手库浏览与榜单**：QQ音乐目录（含华语=内地+港台自行合并的筛选）

## 技术栈

| 层次 | 选型 |
|------|------|
| UI | Flutter 3.47 + Material 3 |
| 状态管理 | ChangeNotifier |
| 本地存储 | sqflite（九表，分层迁移，当前 v12） |
| 网络 | dio（限流 + 指数退避重试） |
| 音频 | Media3/ExoPlayer（just_audio 后端） |
| 平台通道 | 仓库内插件 `plugins/audora_files`（SAF 目录 / 扫描 / 下载落盘） |
| compileSdk | 37 |
| minSdk | 24（Android 7.0+） |
| 包名 | `com.fly1pu.audoramusic` |

## 构建

```bash
flutter pub get
scripts\build-arm64.bat    # ARM64 单包 release，约 20MB
```

路径必须纯 ASCII（非 ASCII 目录会导致 release 构建失败）。

## 测试

```bash
flutter analyze    # 0 error（残留若干 prefer_initializing_formals info）
flutter test       # 624 / 624 通过
```

## 目录结构

```
audora-music/
├── android/                # Android 宿主（仅 arm64）
├── docs/                   # 项目文档
├── integration_test/       # 真机联网冒烟测试
├── lib/                    # Flutter 源码
├── plugins/audora_files/   # 仓库内 Android 插件（SAF 目录 / 扫描 / 下载）
├── scripts/                # 构建脚本
├── test/                   # 单元测试（624 项 / 51 个文件）
└── pubspec.yaml
```

## 文档

| 文档 | 内容 |
|------|------|
| [docs/architecture.md](docs/architecture.md) | lib/ 目录说明、数据流、空态契约 |
| [docs/matching.md](docs/matching.md) | 音源匹配算法（四阶段、权重、阈值） |
| [docs/lyrics-matching.md](docs/lyrics-matching.md) | 歌词匹配方案（质量分级、AMLL 逐字、来源扩展、ASR 兜底） |
| [docs/toolchain-lock.md](docs/toolchain-lock.md) | 工具链版本锁定清单（Flutter/AGP/Gradle/Kotlin/SDK、配置缓存教训、复现步骤） |
| [docs/design-notes.md](docs/design-notes.md) | 设计要点与取舍 |
| [docs/build.md](docs/build.md) | 工具链、编译步骤、路径要求 |
| [docs/testing.md](docs/testing.md) | 测试覆盖矩阵、真机冒烟 |
| [TECH_DEBT.md](TECH_DEBT.md) | 故意保留的 B站专属代码位置 |

## 合规

- 本项目**仅个人自用**，不公开发布
- B站音源遵守平台服务条款，仅本地缓存、不二次分发
