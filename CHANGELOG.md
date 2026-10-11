# Changelog

本项目所有显著变更将记录在本文件。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [0.2.0] - 2026-10-11

主线是**本机音乐成体系**：扫描手机自带歌曲 + app 内下载 + 两份清单隔开 +
已下载优先播本地，并在这条链上补齐真实封面与歌词。同时落了逐字歌词
（AMLL TTML）、两点歌词校准、收藏以数据库为唯一真相、猜你想听、
以及一批只在 release 才暴露的缺陷（下载卡在「下载中」、进度通道没挂上）。

数据库从 v8 一路到 v12（match_sample / lyric_slope / local_audio / 本机身份缓存），
迁移仍是只加不改。测试 466 → 624 例，`flutter analyze` 0 error。
真机：魅族 21 / Android 16，arm64-v8a 签名 release 包。

### 新增（本机歌曲的真实封面与歌词，DB v11→v12）

本机文件（手机自带 / app 下载）以前恒为渐变占位封面、点开也没有歌词——根因是
`local_audio` 里**没有任何线上身份**：封面 URL 由 `albumMid` 拼，歌词接口只认
`songMid`，而 `fetchLyric` 第一行 `if (id == null) return null` 把扫描条目全挡了。

- **`local_audio` 加三列**：`song_mid`（取歌词）、`album_mid`（拼封面）、
  `resolved_at`（上次*尝试*的时刻）。只存 mid 不存 URL——URL 是派生值，存下来
  等于在源换域名时把整库封面一起作废；图片本身已有磁盘缓存
- **补全走 `LocalLibraryBox.syncMissingMeta`**，复用既有的
  `metadata.resolveBatch`（标题+歌手+时长三重校验），不新写匹配器：
  - 先做**零成本那一半**：下载条目回指的曲库歌往往已有真 mid，直接抄
  - 剩下的**分片跑**（一片 6 首，每片落库后刷一次清单）——批量解析是串行
    400ms/首，60 首就是半分钟，卡在进页面的 loading 上不可接受；用户应该看到
    封面一首一首变真
  - **失败分两种，处理相反**：「三重校验不通过」= 源上确实没有 → 盖
    `resolved_at` 冷却 3 天；「请求异常」= 可能只是没网 → 什么都不标，
    下次还会试。连续 3 首异常即认定不在线并收手（分片边界生效）
  - 上界用「已处理条数」而不是「已补到条数」：全被拒时后者永远不动，就是个死循环
- **不引 `connectivity_plus` 判网**。「不联网用渐变」由既有的 `CoverImage`
  结构免费提供（渐变铺底 + 网络图盖在上面，拉不到就 `SizedBox.shrink()` 露底）。
  代价说清楚：断网时进一次列表仍会撞最多 6 个请求，换掉的是为一条布尔判断加原生依赖
- **两个触发点**：进本机/下载列表 postFrame 后台跑（不阻塞）；点开某本机首歌
  时若还没身份就**单补这一首**，补到了 force 重取一次歌词（`playQueue` 里那次
  是带着空 mid 跑的，必然没词）
- **`fetchLyric(song, {midFallback})`**：曲库行的 mid 不可用（空 / `local:` /
  `ref:`）时才用备胎，行内有真 mid 永远优先。判定收进 `LibraryRepository.midUsable`
- **列表渲染 `CoverArt` → `CoverImage`**，占位 seed 沿用同一派生口径，
  所以断网时看到的和以前一模一样
- **重扫不冲掉已缓存的身份**：`LocalAudioDao.upsert` 的 UPDATE 分支故意不碰
  这三列。写进去的话每次扫描都会把攒下的封面清空一遍（`local_meta_sync_test.dart` 钉住）
- 口径是**补全不是入库**：不给扫描条目在 `song` 表建行，本机清单仍然独立、
  不进曲库数字与播放统计（理由见 `docs/design-notes.md` §14）

### 变更（歌词页：初始置顶、当前行强调、逐字行居中修正）

- **首行贴在校准条下面**。原来 ListView 上下各留 `0.3 × 屏高`，第 0 行被顶到
  视口中线以下，前奏期看起来是「空半屏才下来」。改成不对称 `topPad = 8` /
  `bottomPad = 0.3 × 屏高`：唱前面几行时定位算出负数、被 `clamp(0)` 抬平，
  于是开局贴顶、唱过中线才开始往上滚。定位公式与内边距必须同源这条红线不变
- **当前行反差从 18/15 拉到 22/13**（1.2 倍 → 1.7 倍），字重 w800 / w500。
  固定行高跟着 60→72、有译文 96→108，余量必须按「高亮行折两行」算
- **修掉一个真 bug：逐字（扫光）行偏左**。`TextAlign.center` 对**单行**
  `TextPainter` 完全不生效（实测 `layout(maxWidth: 300)` 后 `tp.width` 缩成
  文字的 54、`getOffsetForCaret(0).dx` 仍是 0），而普通行走 `Text`/RenderParagraph
  会自己居中——所以现象是「只有正在唱的这行偏左」。修法：画之前
  `canvas.translate((盒宽 - 文字宽)/2, 0)`，位移作用在 dim/fill 两层之上、
  裁剪矩形保持在段落本地坐标，否则扫光边缘会跟着错位。补偿量抽成
  `karaokeCenterDx()` 并留了实测用例，防止被当冗余删掉
- 顺带收掉一条与本次无关的红：`player_download_button_test.dart` 里
  「数据层没接」用例被 `DiagLog` 的 2 秒 flush 计时器判失败——
  残留 Timer 的不变量检查跑在 `tearDown` **之前**，复位必须写在测试体内

测试：`flutter test` 624/624 通过（新增 `lyric_layout_test.dart`、
`local_meta_sync_test.dart`，并补齐 `docs/testing.md` 里缺记的 14 个测试文件）。
真机（魅族 21 / Android 16）release 包验证：本机清单三首全部出真实封面、
本机歌播放有歌词、歌词初始贴顶、当前行居中放大。

### 新增（本机音乐：SAF 目录 / 本地扫描 / 播放页下载）

第二、三、五项，一起构成第一个成体系的「本机音乐」能力。全部改动都新增一个
仓库内 Android 插件承载，`android/app` 的 Manifest 与 Activity 一行没动
（宿主必须是 audio_service 的 `AudioServiceActivity`，原因写在那份注释里）。

- **新插件 `plugins/audora_files/`**（通道 `audora/files` + `audora/files/progress`）
  - `pickDirectory` / `describeDirectory` / `listDirectories` / `releaseDirectory`
    —— SAF 目录选择与**持久化授权**。`takePersistableUriPermission` 是关键一步：
    不拿它，用户挑的目录一重启就作废，表现为「设置里明明选了，下载时又要重选」
  - `audioTracks` —— MediaStore 音频扫描。**为什么不是遍历 SAF 树**：MediaStore
    已经解析好 ID3（歌手/专辑/时长/是否音乐），SAF 遍历只有文件名和字节数。
    SAF 在这里的角色是**圈定范围**——把选中的目录换算成路径前缀去过滤 MediaStore；
    没有 posix 路径的提供方（网盘类）自动降级为全盘扫描
  - `startDownload` / `cancelDownload` / `deleteFile` —— 立即返回 taskId，
    拷贝在单线程池里跑，进度按 1% 变化回推。**单线程是刻意的**：并发下载会把
    B站配额与手机 IO 一起打满，用户感知到的是「播放开始卡」
  - 失败与取消都会删掉自己刚创建的半成品：半截文件留在下载目录里，
    比没有这个文件糟糕得多（列表里有、点开没声、还不知道为什么）
  - 权限随插件声明（`READ_MEDIA_AUDIO`，Android 12 及以下 `READ_EXTERNAL_STORAGE`
    且 `maxSdkVersion=32`），运行时申请复用既有的 permission_handler
- **设置里两条「歌曲目录」**（我的 → 设置）：本地目录（扫描范围，不设=全盘）、
  下载目录（落点，不设则下载按钮给一句指路的话）。两条独立键、独立授权、
  互不回退——混成一个的话，把下载目录设成 `/Music` 会让下次扫描把自己下载的歌
  当成本机自带歌曲再收一遍
  - 存的是 tree uri 而不是路径；**启动时都要向原生核对一次**，因为用户可以在
    系统设置里撤销授权，本地那串字符串说明不了任何事。文案分三档：未设置 /
    需重新授权 / 名字（下载目录不可写时显示「只读」）
  - 「换目录」与「清除」分开：只有一个更换入口的话，用户退不回未设置状态
- **「我的」页第二张入口卡「本地」**：进去是左右并列的两个功能——
  本地（扫描手机自带歌曲）与 下载（app 下载的歌），**两份清单永不混排**。
  数据层用同一张表的 `kind` 列区分（`local_audio`，DB v10→v11），
  展示层彻底分开
- **播放页底部新增「下载」**，位置就按需求放在「定时关闭」与「音效」之间
  （`test/player_download_button_test.dart` 用水平坐标钉住顺序）。三态：
  下载 → 百分比（无 Content-Length 时显示「下载中」而不是假百分比）→ 已下载；
  已下载再点是**移除**（二次确认，真删文件），不是重复下载；失败态按钮变成
  「重试」而不是无声复原
- **已下载优先播本地文件**（用户选的语义）：切歌时纯内存判定，命中就把队列里
  那一格的 `AudioSource` 换成 `localFile`，解析层看到 `sourceType == 'local'`
  直接短路——一次网络请求都不发，也不看在线/下载音质上限（文件已经是哪档就是哪档）
  - 换的是**队列里那一格**而不是局部变量，否则播放页与通知栏会显示 B站源、
    实际播的是文件
- 下载走**独立的解析路径** `resolveForDownload`，不复用播放的 `resolve()`：
  后者优先命中按在线音质挑的 URL 缓存、还会回写缓存，直接拿来下载会让
  「下载音质」设置变成摆设并污染在线缓存；下载也绝不触发自动重匹配
  （重匹配后下到的会是另一场演出）
- `local_audio` 表（DB v11）：`uri` 唯一、`kind` CHECK 二选一、`song_id`
  外键 `ON DELETE SET NULL`。扫描换血用「同一轮共用一个时间戳 + 删除更旧的」
  而不是 `NOT IN (…)`——手机媒体库轻松上千条，SQLite 默认 999 个变量上限
  一条语句就崩。**扫到 0 条时刻意不裁剪**：MediaStore 被禁用的 ROM 上
  返回空游标而不报错，直接裁会把整份清单清空且看起来像功能正常

### 新增（首页入口卡与音质偏好拆分）

- **音乐页「随便听一下」整行大卡 → 两张并列小卡片**：「猜你想听」+「最近听过」
  - 「猜你想听」**不再只回锅本地曲库**。旧的 `shufflePlay` 是「收藏 + 曲库前
    15 首随机」，听两周就永远是那十几首。新链路（`lib/state/guess_for_you.dart`）
    按口味去 QQ 音乐拿歌手热歌，再用热歌榜/新歌榜掺新，去重打散后成队列起播
  - 口味来源：常听计 2 票、收藏计 1 票，取得票前两位歌手（每个来源都是一次
    远端往返，5 位歌手会让卡片转三四秒）。常听权重更高是刻意的——收藏里躺着
    不少「当时觉得不错再没听过」的歌，常听才是当下真实口味
  - **QQ 音乐自己的个性化推荐接口用不了**，这是实测结论不是猜测：
    `music.personRec.*` / `musicTsRecommend.*` / `MUSIC.IndexTop.RecommendService`
    / `music.rec.*` / `music.musichallPlaylist.PlayListCgi` / `music.radio.UfoRadio`
    等 11 个 module·method 组合匿名请求一律 `code=500003`（风控），要 QQ 登录态。
    本应用只有 B站扫码登录，所以推荐算法放在我们这层，数据源仍全是 QQ 音乐，
    只用验证过可匿名访问的两个接口（歌手热歌 + 榜单详情）
  - 失败纪律与目录浏览同源：单个来源挂了跳过它，全部失败就一句文案，
    **不端一盘假歌**；重入（连点）静默吞掉并显示转圈
  - 「最近听过」卡片**只进列表页**，不在首页起播——「看一眼上次听到哪」和
    「开始放」是两件事。列表页从「我的」页的私有 `_SongListPage` 提成公共的
    `lib/screens/song_list_page.dart`（收藏 / 最近听过共用，第二期的本地与
    下载也走它）
  - 两卡不再被 `if (st.library.isNotEmpty)` 挡：猜你想听是在线组歌，空库也推得出来
- **设置的「音质偏好」拆成两条独立上限**：「在线音质」与「下载音质」，
  各三档（标准 132Kbps / 高品质 192Kbps / 自动）。合在一条时做不到
  「在线听省点流量、下载留最好的」
  - 两个持久化键独立（`quality_ceiling` 沿用老键名，装机用户的设置不丢；
    新增 `download_quality_ceiling`，默认 192K——下载是要留下来的文件，
    自动可能一次拉进几十 MB 的 Hi-Res）
  - 改在线音质仍会**立即换档并保住进度**；改下载音质不碰正在播的这一次拉流
  - 「省流 64Kbps」档下线：B站 64K 实际是带强噪声的降级流。老值读到后映射到
    标准 132K，**不是**落到「自动」——否则下线一个档就是一次静默升档
  - 下载器尚未接入（第二期），「下载音质」一行如实标注「下载功能开发中」，
    不装成已经生效
- 播放页「音源」面板的「音质上限」一行改名「在线音质上限」，与新设置对齐

### 新增（逐字歌词）

- **播放页歌词支持逐字（卡拉OK式连续扫光）**，无需任何设置项，有字轴即生效：
  - **真实逐字轴来自 AMLL TTML**（`lib/services/lyric/amll_ttml_provider.dart`）。
    选型是实测出来的，不是猜的：QQ音乐 `GetPlayLyricInfo` 返回体的 `qrc` 标志位
    对 8 首热门歌**恒为 0**、`Default/GetLyric` 等接口匿名一律 `500003`；
    网易 `/api/song/lyric?kv=1` 的 `klyric` 字段结构在但 12 首歌**全返回空串**。
    即两家平台的逐字轴都要登录态，匿名拿不到。AMLL 站 20 首中外热门歌命中 11 首，
    且命中条目 11/11 确实带 `<span begin end>` 字级时间轴，无「命中但无字轴」的假阳性
  - **按已存的 `qqSongMid` 精确命中**：搜索响应带 `qqIds`，不需要按标题模糊匹配；
    标题查只作降级路径，并过「标题+歌手评分 ≥70（歌手对不上直接一票否决）」
    与「末行时间 vs 音频时长（偏短容差 30–60s、偏长收紧 12–30s）」两道门禁。
    原则是**宁缺毋滥**——把别的歌的字轴安过来，比没有逐字更难看
  - **命中后整条歌词替换 LRC**（含 TTML 自带的 `x-translation` 译文），
    不做逐行文本对齐：AMLL 与 QQ 的行切分不同源，对齐错一行就整句节奏错位
  - **未命中时按字数均分兜底**（`applyWordTiming`），扫光照样动，只是跟不上真实语速；
    行尾时间受「自然演唱速度」钳制，避免两行间隔很久时每个字拖几秒
  - 分字规则：中文/假名/韩文按字，拉丁文按单词（标点跟随前字，不单独占一拍）；
    字轴用 `charCount` 承载而不是每字存文本，从结构上消除「拼接后与原文不符」
  - **性能不退化**：扫光需要的毫秒位置**不进任何通知链**——当前位置由歌词的
    当前行自持 `Ticker`，每帧向 `AppState.karaokeLyricMs()` 拉一次「上次采样 + 单调时钟
    外推（钳 1s）」的值。`posTick` 保持秒粒度原样，整树/整列表的重建频率不变
  - 歌词页校准条新增来源标识「逐字 · 精确 / 近似」，便于判断「扫光不准」是数据问题还是偏移问题
- 新增测试 `test/lyric_word_test.dart`（38 例）、`test/lyric_karaoke_test.dart`（7 例）。
  TTML 用例的 fixture 是从天上抓下来的《晴天》《Lemon》原文，恰好覆盖
  `00:29.231` / `1.372` / `3:58.431` 三种时间写法，不是手写理想样例

### 修复

- **定时关闭从不暂停真实播放器**：回调只翻 `_playing = false` + 停 mock
  ticker，没有 `_player?.pause()`，而界面承诺「播放将在设定时间后自动停止」。
  真机上音频一直放到自然结束、界面却显示暂停态；`playingStream` 是变更流
  不会补发 `true` 自愈，`_playing` 与 just_audio 永久失步，播放按钮再也按不动。
  改为回调内真正 `pause()`，并顺带结算这一段播放时长
- **风控 -412/-352 把用户静默踢回匿名**：风控分支调 `setUserSession()`
  **无参**版本，而那是 `logout()` 的语义——一次普通限流就清掉 SESSDATA、
  丢掉 192K 音质且无 UI 提示。新增 `invalidateAnonymousCookie()` 只作废
  匿名指纹缓存、保留登录态
- **三处 `await` 之后缺 `mounted` 保护**：`onPlaybackError`（播放失败默认
  路径，会跑完整重匹配）、`loadLibrary` 入口、点播匹配成功后的 `showToast`
  （≈20 秒）都可能 dispose 后再通知，抛「used after being disposed」。
  代码库在 `loadLyricForCurrent` 已写注释承认该风险，只是漏了这三处
- **发布先验 gapDays 向零截断**：`(pubdate - releaseSec) ~/ 86400` 对负数
  向零截断，早于发行 30.9 天会掉进「预热档 0.65」而本该判「不可能 0.00」。
  改为负值分支按符号做 floor 取整
- **提前终止详情请求的判定跨量纲**：`best.total`（MatchScorer 六维总分）
  直接减 `nextCoarse`（RecallScorer 召回分），两把不同的尺子相减得到的
  「领先幅度」没有量纲意义，可能错误地砍掉正确候选。改用粗排分折算的
  保守上界参与比较
- **详情缓存缺在途去重**：缓存只在请求返回后写入，跨歌并发匹配撞上同一
  bvid 时两路会同时读到 miss、各发一次请求，白烧一份限流额度。新增在途表，
  `finally` 清键（失败不毒化）
- **`getAllExcluding` 的注入 sink**：签名 `getAllExcluding(String notInSubSelect)`
  把调用方字符串原样拼进 `id NOT IN (...)`。当时只有两个调用方、都传常量，
  所以不可利用，但接口本身是注入 sink。穷举成 `ExcludeScope` 枚举
  （`anyBinding` / `activeBinding`），拼接点变成 DAO 内部唯一的 switch
  且全为编译期常量
- **`search()` 的 LIKE 未转义通配符**：搜 `%` 会匹配整库、搜 `a_b` 会把
  `axb` 也算命中（值是参数化的，不构成注入，但结果与输入不符）。加
  `ESCAPE '\'` 子句，并把 `%` / `_` / 反斜杠本身一并转义
- **`AudioPlayerController` 的 Timer 与订阅泄漏**：`dispose()` 是死代码
  （lib/ 内无调用点），且 `bind()` 里两个 just_audio 流的 `.listen(...)`
  把 StreamSubscription 丢了 —— 2 秒看门狗 Timer 与两个订阅都没有回收路径。
  存下订阅句柄（`bind()` 用 `??=` 防重复订阅）、新增**可重入**的
  `shutdown()`，并接到 `onTaskRemoved()`：**仅在非播放态**被划掉时才
  `stop()` + `shutdown()`（那时 Service 本就要 stopSelf，没有正在放的歌）；
  播放态刻意不碰，避免掐断后台播放

### 移除

- 删除死常量 `MatchConfig.minRecallCandidates`：引擎早已按注释移除该门槛，
  无任何引用

### 测试

- 测试总数 412 → **466**（`flutter analyze` 0 告警，466/466 通过）
- 新增 `test/audit_fixes_test.dart`（风控不得踢用户下线 / 发布先验天边界
  含 30.9 天负向边界 / 定时关闭 / dispose 后通知安全）
- 新增 `test/detail_inflight_test.dart`（跨歌并发撞同一 bvid 只发一次详情请求；
  零延迟边界下同样成立；失败后在途表必须清键）
- 新增 `test/song_dao_scope_test.dart`（两种排除口径的行为差异 / 同歌多条
  候选绑定 / LIKE 通配符按字面量匹配，含转义符自身）
- 修正 README / docs/testing.md 中与实际不符的测试数（412、369 → 466）
- TECH_DEBT.md 新增「2026-10-07 审计批次」，并记录 3 条**经实测推翻**的
  疑似问题（cid 双写自愈失效 / upsertAll UNIQUE 冲突 / match_sample 索引缺失），
  避免重复排查

### 新增（歌手库筛选与 UI 修复，同批未发布）

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

### 修复（真机三问：收藏口径 / 目录选择器 / 设置区瘦身）

用户报三条，全部先在魅族 21 / Android 16 上**复现再修**（`adb uiautomator dump` 抓界面
现场 + 诊断日志抓调用现场，取证脚本留在 `tool/ui_dump.py`）。

- **收藏写着「N 首」却点不进歌单** —— 计数和列表是两套口径：计数走内存红心集合，
  列表走 `library.where(isLiked)`，而 `library` 只是曲库**最近 500 行**的窗口
  （`listSongs(limit: 500)`）。在窗口外的歌（榜单点进来的、本机下载/扫描的）上点心，
  计数 +1、列表按窗口筛就是空。现在**计数、红心、列表三者同源于数据库**：
  - `isLiked` 有 id 时按 `song_id` 判——同一首歌的不同对象实例（队列里那份 /
    曲库里那份）结论必须一致
  - `likedCount` = `liked_song` 行数，与曲库窗口无关
  - 收藏页改为**进页面现查**：`SongListPage` 新增 `loader`，走 `repo.likedSongs()`
    按收藏时间倒序，支持下拉刷新；不再吃「点卡片那一刻」的内存快照
  - 没有 song 行的本机文件不再做「只在内存里活一次」的假收藏，点心如实提示
  - 装机现场：计数从假的 1 首变成数据库真值 **7 首**，7 首全部列出
- **本地目录 / 下载目录点了没反应** —— 两层原因叠在一起，逐个用日志钉掉：
  1. 原生把意图包进 `Intent.createChooser`，只为显示一行标题。Android 11+ 的包可见性
     让 chooser 枚举到 0 个候选 → `com.android.intentresolver` 起了就 destroy →
     Flutter 只收到 RESULT_CANCELED → Dart 判成「用户取消」，**全程零反馈**。
     实测 `ACTION_OPEN_DOCUMENT_TREE` 在这台机上只有 documentsui 一个处理者，
     包 chooser 没有任何收益：去掉。
  2. 去掉后仍失败，`ActivityNotFoundException` 把原因说得很直接——经典 SAF 片段里的
     `addCategory(CATEGORY_OPENABLE)` 是给 `OPEN_DOCUMENT` / `GET_CONTENT` 用的，
     DocumentsUI 的**树**选择 filter 里没有这个类别，于是隐式解析 0 命中。对照实验：
     `query-activities -a OPEN_DOCUMENT_TREE` → PickActivity；
     再加 `-c android.intent.category.OPENABLE` → No activities found。删掉该类别。
  3. `<queries>` 只声明 action（规则会拿类别一起比，写 OPENABLE 反而一条都匹配不上）。
  修完焦点确实落在 `com.android.documentsui/.picker.PickActivity`。
  另外目录选择的**拉起 / 取消 / 失败**三条路径全部写诊断日志：下次再出
  「点了没反应」，「我的 → 诊断日志」里直接有原因，不用靠猜。
- **设置项太多** —— 7 行收成 5 行：
  - 「音质偏好」一个弹窗装下在线 / 下载两条上限。**入口合并、偏好没合并**——
    两档仍各选各的（当初拆开的理由不变），合并行右侧同时显示两个真实生效值
  - 「歌曲目录」一个子页面装下本地 / 下载两个目录，选择与清除各一行直达；
    顺手把从没在界面露过面的 `dirsNote`（授权失效 / 不可写 / 平台不支持）显示出来
  - 删除 `downloadFeaturePending` 常量：下载器已经上线，那句「功能开发中」是假话

### 修复（本机文件点开没声——同一批真机日志里撞出来的）

`just_audio` 一旦收到 `headers` 就把流改走它自己的 Dart 端 HTTP 代理，而代理只认
http/https；本机文件是 `content://media/external/audio/media/xxx`，于是抛
`Invalid argument(s): Unsupported scheme 'content'`（当天 13 条）。
现在只在 http/https 才传 headers——本机文件本来就不需要任何头。

### 修复（下载卡在「下载中」不动了）

用户反馈：点下载之后按钮一直停在「下载中」，再点也没反应。真机日志对得上——
06:47:38 一条 `playurl` 请求之后**没有任何「解析成功」**，说明解析那步死了。

- **主因：`DownloadBox.start()` 只给「发起下载」包了 try，解析地址那段没有。**
  解析一抛（B站风控 / 网络异常 / 适配器报错），`_current` 就永久挂着，
  而旧界面在解析阶段也显示「下载中」→ 看起来就是「下载坏了且取消不掉」。
  现在解析、发起两段各自 try/catch，异常一律清状态 + 回一句人话。
- **解析没有超时** → 加 `resolveTimeout`（默认 90s；全局限流 30 次/分钟时
  一次请求可能排队几十秒，不限时就是无限「下载中」）。
- **解析阶段点取消没出口**：旧 `cancel()` 在 `taskId == null` 时直接 return null，
  什么都不做。现在这个阶段点取消会清状态并说明「已取消（还没开始传输）」。
- **取消不再依赖原生回推**：本地立刻落回空闲（原生只负责删半成品）。
  旧写法把清态完全交给 `canceled` 事件，那条回推一丢就永远挂着。
- **新增掉线看门狗**（`stallTimeout` 默认 60s）：拿到任务后连续 60s 没有任何
  进度 → 判失败，按钮变「重试」，并顺手 cancel 掉原生的僵尸任务。
  判的是「静默」而不是「总时长」，所以下得慢的长文件不会被误杀，
  每条进度都会喂狗（有测试钉住这条）。
- **状态文案更诚实**：解析阶段显示「准备中」，拿到任务才显示「下载中 / 百分比」。
- **原生三处**：`runDownload` 在 `appContext == null` 时原本静默 return（Dart
  永远等不到终态），现在回一条 failed；`report()` 的 `runCatching` 不再无声吞异常，
  失败写 logcat（进度通道丢事件是「一直下载中」的另一条路）；
  **`cancelDownload` 修掉双回复**——旧写法 `cancelFlags[taskId]?.set(true) ?:
  result.error(...)` 之后无条件 `result.success(null)`，取消一条已结束的任务
  等于回两次，平台线程直接抛 "Reply already submitted"。
- 下载全程写诊断日志：受理 / 接单 / 完成 / 失败 / 超时 / 取消，下次一看就知道死在哪。
- 新增 6 条测试（`test/download_box_test.dart` 的「永久下载中的出口」组），
  钉住的原则只有一句：**任何一条路径都必须让按钮回到可点状态**。

#### 上面那批没有修好它：真根因在进度通道的守卫（同日二次真机）

同一天用户再次反馈「还是一直下载中」。这一轮的日志把话说死了：三次下载
（07:12 / 07:13 / 07:15）都是 `原生已接单` 之后**连续 60s 零回推**、被看门狗
判失败，而磁盘上 `02Audora/` 里躺着三个**完整**的 `Habit - Sekai no Owari.m4a`
（各 8,095,489 字节，几秒就写完了）。传输一直是好的，坏的是「原生 → Dart」
这条回推通道：

- **根因：`DownloadUpdates.ensureAttached()` 用 `BindingBase.debugBindingType()`
  判 binding。** 那个值是写在 `assert(() { ... return true; }())` 里的，
  release 包把 assert 整块剥掉 → **release 下它恒返回 null**，于是守卫永远早退，
  `audora/files/progress` 的 Dart handler 一次都没挂上过。原生每条
  `invokeMethod` 都撞上 `MissingPluginException`，被 `runCatching` 只写进 logcat
  的 `Log.w` 吃掉。表现就是「文件早就下完、按钮永远下载中、清单里也没有它」。
- **为什么上一轮没发现**：上一轮的判据是为了挡「纯 `test()` 里注册 handler 会
  断言崩」而加的，而 debug 与单测里 assert 都开着、守卫照样通过 ——
  这是一个**只在 release 生效**的 bug，全量单测天生抓不住。
- **改法**：判据换成三种构建模式一致的 `try { ServicesBinding.instance; } on Object`
  （真没 binding 时 debug 抛 FlutterError、release 走 `instance!` 抛 TypeError）。
  守卫本身保留，纯 Dart 单测仍然不会被炸；`ensureAttached()` 改为返回 bool，
  且早退时不记「已挂载」，binding 晚于对象构造出现时下一次还会再试。
- **不再靠猜的兜底**：`DownloadBox.start()` 在 Android 上若挂不上通道，立刻写一条
  `download_channel_not_attached` 诊断错误 —— 这类事件事后从日志一眼可辨，
  不用再看门狗超时反推。
- 新增 5 条测试：`download_progress_channel_test.dart` 用**真通道**
  （`handlePlatformMessage` 模拟原生 `invokeMethod`）钉住「事件必须到达
  `DownloadUpdates.stream`」以及 done 的 uri/size/name 解码；
  `download_progress_attach_guard_test.dart` 钉住守卫的另一半（无 binding 时
  安静早退、不抛）。
- 原则进 `docs/testing.md`：**runtime 分支不要依赖 `debug*` 这类 debug-only API**。

### 其它（同批）

- 下载目录未设置时的指路文案跟着新的入口层级改成
  「我的 → 歌曲目录 → 下载目录」。

### 变更（开源协议与底部文案）

- **LICENSE：MIT → GPL-3.0**（换成 GNU 官方全文，逐字未改）。
- 「我的」页底部文案：`Audora 2.0 · 个人自用 · 基于 Flutter` →
  `Audora v0.1.0 · 基于 Flutter 开发 · 开源协议 GPL-3.0`。版本号回到
  **实际发版号**——原「2.0」是原型设计稿的年代号，与 pubspec 对不上。
- 版本字符串收敛为 `kAppVersion` 常量（`mine_screen.dart`）；新增
  `test/mine_footer_test.dart`：逐字断言 pubspec.yaml ↔ 常量一致、
  LICENSE 必须是 GPL-3.0 全文——改版号忘同步或协议回退都会直接红。

## [0.1.0] - 2026-09-30

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
