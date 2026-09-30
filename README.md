# Audora 2.0

个人自用音乐播放器 —— Flutter 版。

> 元数据来自 **QQ音乐**，音源来自 **B站视频**，通过一套六维加权打分算法自动匹配。

![Flutter](https://img.shields.io/badge/Flutter-3.47-02569B?logo=flutter)
![Platform](https://img.shields.io/badge/Platform-Android%207.0%2B-3DDC84?logo=android)
![License](https://img.shields.io/badge/License-MIT-blue)
![Tests](https://img.shields.io/badge/tests-204%2F204_passing-brightgreen)

---

## 功能特性

- **在线搜索 / 导入**：QQ音乐元数据（严格三重校验：标题互含 + 歌手互含 + 时长容差）
- **自动音源匹配**：四阶段流水线（召回 → 硬过滤 → 精确校验 → 六维加权打分），详见 [docs/matching.md](docs/matching.md)
- **按需匹配**：点哪首播哪首，首首可播时间 ≈20 秒；批量预处理可选
- **后台播放**：audio_service 前台 Service，通知栏 / 锁屏媒体控制
- **收藏与播放统计**：独立建表，流水与聚合分离
- **歌词**：自动拉取 + 翻译
- **音源状态可视化**：已匹配 / 待确认 / 无音源 三态徽章，待确认项集中人工复核

## 技术栈

| 层次   | 选型                                          |
| ---- | ------------------------------------------- |
| UI   | Flutter + Material 3                        |
| 状态管理 | `ChangeNotifier`（零依赖，可平滑替换为 Riverpod）       |
| 本地存储 | sqflite（六表，分层迁移）                            |
| 网络   | dio（限流 + 指数退避重试）                            |
| 音频   | Media3 / ExoPlayer（`just_audio` 后端）          |
| 最低版本 | Android 7.0 (API 24)                        |
| 编译版本 | targetSdk 36 / compileSdk 36                |

## 目录结构

```
audora-music/
├── android/                # Android 宿主工程
├── docs/                   # 项目文档（见下方文档索引）
├── integration_test/       # 真机联网冒烟测试（不入 CI）
├── lib/                    # Flutter 源码（架构说明见 docs/architecture.md）
├── scripts/                # 本地脚本
│   └── build-arm64.bat     # ARM64 单包 release 构建脚本
├── test/                   # 单元 / 组件测试（204 项）
├── pubspec.yaml
└── README.md
```

## 快速开始

```bash
flutter pub get
flutter build apk --release --split-per-abi
```

工具链版本、路径要求（⚠️ 工程目录必须纯 ASCII）、`local.properties` 配置等，
详见 [docs/build.md](docs/build.md)。

## 测试

```bash
flutter analyze    # 0 告警
flutter test       # 204 / 204 通过
```

完整覆盖矩阵与真机联网冒烟测试见 [docs/testing.md](docs/testing.md)。

## 文档索引

| 文档                                         | 内容                                   |
| ------------------------------------------ | ------------------------------------ |
| [docs/architecture.md](docs/architecture.md) | lib/ 目录说明、完整数据流、空态契约                  |
| [docs/design-notes.md](docs/design-notes.md) | 11 条设计要点（含取舍依据与踩坑记录）、登录与限流结论          |
| [docs/matching.md](docs/matching.md)         | 音源匹配算法速览（四阶段、权重、阈值）                   |
| [docs/testing.md](docs/testing.md)           | 测试覆盖矩阵、真机冒烟、单测与迁移的坑                   |
| [docs/build.md](docs/build.md)               | 工具链、编译步骤、路径要求、local.properties        |

## 合规提示

- 本项目**仅个人自用，不公开发布**
- B站音源获取需遵守平台服务条款，仅在本地缓存、不二次分发
- NeriPlayer（GPL-3.0）仅作思路参考，未复制其代码

## License

[MIT](LICENSE)
