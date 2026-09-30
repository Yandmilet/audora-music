match_v04_full

完整替换目录:  
lib/services/match/

包含:

- match_engine.dart
- match_scorer.dart
- text_normalizer.dart
- match_config.dart
- title_parser.dart
- version_detector.dart

优化:

1. v0.3速度优化保留
2. 标题结构解析
3. 歌手独立评分
4. 版本惩罚
5. 文本缓存

说明:  
当前文件保持接口兼容结构。  
如项目已有实体模型，可直接合并 MatchEngine 内部逻辑。
