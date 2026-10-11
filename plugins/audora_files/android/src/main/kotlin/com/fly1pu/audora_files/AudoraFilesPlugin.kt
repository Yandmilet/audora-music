package com.fly1pu.audora_files

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.util.Log
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File

/**
 * Audora 的 Android 存储能力。当前提供 SAF 目录相关四件事：
 *
 * - `pickDirectory`     拉起系统目录选择器（ACTION_OPEN_DOCUMENT_TREE），选定后
 *                       立即 takePersistableUriPermission —— 没有这一步，用户
 *                       挑的目录在 app 重启/进程被杀后就作废，表现为「设置里
 *                       明明选了，下载时又说要重选」。
 * - `describeDirectory` 把已存的 tree uri 讲清楚：显示名 / 对应的真实路径 /
 *                       授权还在不在 / 能不能创建文件
 * - `listDirectories`   系统当前真正持有持久化授权的目录（授权被用户在系统
 *                       设置里撤掉时，这里是唯一能发现的办法）
 * - `releaseDirectory`  主动交出授权
 *
 * ## 为什么单独一个插件，而不是在 android/app 里写平台通道
 * app 的宿主 Activity 必须是 audio_service 的 `AudioServiceActivity`（原因写在
 * `android/app/src/main/AndroidManifest.xml` 的注释里：换成自定义 FlutterActivity
 * 子类或它的子类，都会让引擎 warm up 但 View 永不 attach，表现为白屏）。
 * 那个文件不该再被为了塞一个通道而改动。插件通过 ActivityAware 拿到当前
 * Activity，`GeneratedPluginRegistrant` 自动注册，app 侧零改动。
 *
 * ## 为什么本地扫描不走 SAF
 * 「扫描手机自带歌曲」要的是整台设备的音频库（含 ID3 解析好的歌手/专辑/时长），
 * 那是 MediaStore 的本职。SAF 树遍历拿不到这些元数据，只能自己解析标签。
 * 所以分工是：**扫描范围**可以是一个 SAF 挑的目录（转成路径前缀去过滤
 * MediaStore），**音频条目**本身来自 MediaStore。见 `scanAudio`（第二阶段）。
 */
class AudoraFilesPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {

    companion object {
        private const val CHANNEL = "audora/files"

        /** logcat 过滤用的标签（进度回推失败这类「看不见的原因」全靠它）。 */
        private const val TAG = "AudoraFiles"

        /** 原生 → Dart 的进度回推通道（下载中每 ~1% 报一次）。 */
        private const val PROGRESS_CHANNEL = "audora/files/progress"
        private const val REQ_PICK_DIR = 0x4146

        private const val FLAG_RW =
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION

        /** 外置存储主卷在 MediaStore 路径里的样子（primary:Music → /storage/emulated/0/Music）。 */
        private const val PRIMARY = "primary"
    }

    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private var activityBinding: ActivityPluginBinding? = null

    /** 等待 SAF 回调的那次调用。同一时刻只可能有一个选择器在前台。 */
    private var pending: MethodChannel.Result? = null

    /** 原生往 Dart 推下载进度用的通道（detach 时必须置空，否则回调打到死引擎）。 */
    private var progressChannel: MethodChannel? = null

    /**
     * 下载用的单线程池 + 取消位。
     *
     * 单线程是刻意的：一首歌一条 CDN 流，并发下载会把 B站的带宽配额和
     * 手机的 IO 一起打满，用户感知到的反而是「播放开始卡」。
     *
     * 不用 kotlinx.coroutines 是为了不给这个插件引一个新依赖；
     * 取消靠一个 AtomicBoolean，读它的位置在拷贝循环里。
     */
    private var downloadExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val cancelFlags =
        java.util.concurrent.ConcurrentHashMap<String, java.util.concurrent.atomic.AtomicBoolean>()
    private var taskSeq = 0

    // ── FlutterPlugin ────────────────────────────────────────────────

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        appContext = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
        progressChannel = MethodChannel(flutterPluginBinding.binaryMessenger, PROGRESS_CHANNEL)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        progressChannel = null
        appContext = null
        // 引擎都没了，进度回调没有接收方。取消所有在途任务，并把线程池
        // 换一个新的——下次 attach 时旧的已经 shutdown，复用会直接拒任务。
        cancelFlags.values.forEach { it.set(true) }
        downloadExecutor.shutdownNow()
        downloadExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
    }

    // ── ActivityAware ───────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        // Activity 没了却还挂着一次等待中的选择：如实报错，
        // 不要让 Dart 侧永远停在「转圈」上。
        pending?.error("no_activity", "界面已切换，目录选择被中断", null)
        pending = null
    }

    // ── MethodCallHandler ───────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext
        if (ctx == null) {
            result.error("no_context", "插件尚未附着到引擎", null)
            return
        }
        when (call.method) {
            "pickDirectory" -> pickDirectory(ctx, call, result)
            "describeDirectory" -> describeOrError(ctx, call.argument<String>("uri"), result)
            "listDirectories" -> result.success(listDirectories(ctx))
            "releaseDirectory" -> releaseDirectory(ctx, call.argument<String>("uri"), result)
            "audioTracks" -> scanAudio(ctx, call.argument<String>("pathPrefix"), result)
            "startDownload" -> startDownload(ctx, call, result)
            "cancelDownload" -> cancelDownload(call.argument<String>("taskId"), result)
            "deleteFile" -> deleteFile(ctx, call.argument<String>("uri"), result)
            else -> result.notImplemented()
        }
    }

    /**
     * 扫描手机自带音乐（MediaStore 音频库）。
     *
     * ## 为什么用 MediaStore 而不是遍历 SAF 目录
     * MediaStore 已经把 ID3 解析好了（歌手 / 专辑 / 时长 / 是否音乐），
     * 自己遍历 SAF 树只能拿到文件名和字节数——用户看到的是「01.mp3 未知歌手」。
     * SAF 在这里的角色是**圈定范围**：把选中的目录换成路径前缀去过滤。
     *
     * ## 权限
     * 缺授权时抛 `need_permission` 而不是返回空列表：返回空会被上层当成
     * 「这台手机没有歌」，而真相是「我们还没被允许看」。
     */
    private fun scanAudio(
        ctx: Context,
        pathPrefix: String?,
        result: MethodChannel.Result,
    ) {
        if (!hasAudioPermission(ctx)) {
            result.error(
                "need_permission",
                "没有读取音频的权限",
                mapOf("needs" to if (Build.VERSION.SDK_INT >= 33) "READ_MEDIA_AUDIO" else "READ_EXTERNAL_STORAGE"),
            )
            return
        }

        val collection = android.provider.MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val args = ArrayList<String>()
        // IS_MUSIC 由系统按「是不是当音乐存的」判定，能滤掉大部分铃声；
        // 时长下限再兜一道——几秒的提示音不该出现在歌单里。
        val where = StringBuilder(
            "${android.provider.MediaStore.Audio.Media.IS_MUSIC} != 0" +
                " AND ${android.provider.MediaStore.Audio.Media.DURATION} >= 5000",
        )
        if (!pathPrefix.isNullOrBlank()) {
            where.append(" AND ${android.provider.MediaStore.Audio.Media.DATA} LIKE ?")
            args.add(pathPrefix.trimEnd('/') + "/%")
        }

        val projection = arrayOf(
            android.provider.MediaStore.Audio.Media._ID,
            android.provider.MediaStore.Audio.Media.DATA,
            android.provider.MediaStore.Audio.Media.TITLE,
            android.provider.MediaStore.Audio.Media.ARTIST,
            android.provider.MediaStore.Audio.Media.ALBUM,
            android.provider.MediaStore.Audio.Media.DURATION,
            android.provider.MediaStore.Audio.Media.SIZE,
            android.provider.MediaStore.Audio.Media.DATE_ADDED,
        )

        try {
            val out = ArrayList<Map<String, Any?>>()
            ctx.contentResolver.query(collection, projection, where.toString(),
                args.toTypedArray(),
                "${android.provider.MediaStore.Audio.Media.DATE_ADDED} DESC")
                ?.use { c ->
                    val idCol = c.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media._ID)
                    val dataCol = c.getColumnIndex(android.provider.MediaStore.Audio.Media.DATA)
                    val titleCol = c.getColumnIndex(android.provider.MediaStore.Audio.Media.TITLE)
                    val artistCol = c.getColumnIndex(android.provider.MediaStore.Audio.Media.ARTIST)
                    val albumCol = c.getColumnIndex(android.provider.MediaStore.Audio.Media.ALBUM)
                    val durCol = c.getColumnIndex(android.provider.MediaStore.Audio.Media.DURATION)
                    val sizeCol = c.getColumnIndex(android.provider.MediaStore.Audio.Media.SIZE)
                    val addedCol = c.getColumnIndex(android.provider.MediaStore.Audio.Media.DATE_ADDED)

                    while (c.moveToNext()) {
                        val id = c.getLong(idCol)
                        // "<unknown>" 是 MediaStore 对无标签文件的字面值，
                        // 原样显示会很难看，统一收成空串交给上层决定文案。
                        val artist = c.getStringSafe(artistCol)
                            ?.takeUnless { it.equals("<unknown>", ignoreCase = true) } ?: ""
                        out.add(
                            mapOf(
                                "mediaId" to id,
                                "uri" to Uri.withAppendedPath(collection, id.toString()).toString(),
                                "path" to c.getStringSafe(dataCol),
                                "title" to (c.getStringSafe(titleCol) ?: ""),
                                "artist" to artist,
                                "album" to (c.getStringSafe(albumCol) ?: ""),
                                "durationMs" to (if (durCol >= 0) c.getLong(durCol) else 0L),
                                "sizeBytes" to (if (sizeCol >= 0) c.getLong(sizeCol) else 0L),
                                "dateAddedSec" to (if (addedCol >= 0) c.getLong(addedCol) else 0L),
                            ),
                        )
                    }
                }
            result.success(out)
        } catch (e: Exception) {
            result.error("scan_failed", "扫描音频失败：${e.message}", null)
        }
    }

    private fun hasAudioPermission(ctx: Context): Boolean {
        val permission = if (Build.VERSION.SDK_INT >= 33) {
            android.Manifest.permission.READ_MEDIA_AUDIO
        } else {
            @Suppress("DEPRECATION")
            android.Manifest.permission.READ_EXTERNAL_STORAGE
        }
        return ctx.checkSelfPermission(permission) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    private fun android.database.Cursor.getStringSafe(index: Int): String? =
        if (index >= 0 && !isNull(index)) getString(index) else null

    // ── 下载 ────────────────────────────────────────────────────────

    /**
     * 把一条 CDN 音频流下到用户选的 SAF 目录里。
     *
     * 调用**立即返回** taskId，真正的拷贝在后台线程跑，进度和结果通过
     * [progressChannel] 回推。不这么做的话，一次几十 MB 的下载会把平台
     * 通道的那次 invokeMethod 挂住几十秒，Dart 侧整个 UI 都在等一个 Future。
     *
     * ## 失败与取消都会把半成品删掉
     * 半截的 mp3 留在下载目录里，比没有这个文件糟糕得多：列表会显示它、
     * 点开会失败、用户还不知道为什么。删掉自己刚创建的那个文档是安全的
     * ——它不是用户放进去的文件。
     *
     * ## 没有断点续传
     * DASH 直链带过期时间（B站约 100 分钟），断点续传要处理「旧链接已失效
     * 但本地已有半截文件」的组合，收益抵不上复杂度。当前语义是：失败/取消
     * 就清干净，重下从 0 开始。
     */
    private fun startDownload(
        ctx: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val url = call.argument<String>("url")
        val destTree = call.argument<String>("destUri")
        val fileName = call.argument<String>("fileName")
        if (url.isNullOrBlank() || destTree.isNullOrBlank() || fileName.isNullOrBlank()) {
            result.error("bad_argument", "缺少 url / 目标目录 / 文件名", null)
            return
        }

        @Suppress("UNCHECKED_CAST")
        val headers = (call.argument<Map<String, String>>("headers") ?: emptyMap())
        val mime = call.argument<String>("mime") ?: "application/octet-stream"

        val taskId = "d${++taskSeq}"
        val cancel = java.util.concurrent.atomic.AtomicBoolean(false)
        cancelFlags[taskId] = cancel

        // 先应答，再把活丢后台。上层拿到 taskId 后才能马上支持「取消」。
        result.success(mapOf("taskId" to taskId))

        try {
            downloadExecutor.execute {
                runDownload(taskId, cancel, url, destTree, fileName, mime, headers)
            }
        } catch (e: Exception) {
            // 线程池已 shutdown（引擎刚 detach）——以失败事件收尾，
            // 别让 Dart 侧永远等在「下载中」。
            cancelFlags.remove(taskId)
            report(taskId, status = "failed", error = "下载线程不可用")
        }
    }

    private fun runDownload(
        taskId: String,
        cancel: java.util.concurrent.atomic.AtomicBoolean,
        url: String,
        destTree: String,
        fileName: String,
        mime: String,
        headers: Map<String, String>,
    ) {
        val ctx = appContext ?: run {
            // 引擎都没了也要给个终态：静默 return 的话，Dart 侧那条任务
            // 永远停在「下载中」，而且用户点取消也救不回来（2026-10-11）。
            cancelFlags.remove(taskId)
            report(taskId, status = "failed", error = "界面已退出，下载中止")
            return
        }
        var docUri: Uri? = null
        var conn: java.net.HttpURLConnection? = null
        try {
            val tree = Uri.parse(destTree)
            val treeDocId = DocumentsContract.getTreeDocumentId(tree)
            val dirUri = DocumentsContract.buildDocumentUriUsingTree(tree, treeDocId)
            docUri = DocumentsContract.createDocument(ctx.contentResolver, dirUri, mime, fileName)
                ?: throw IllegalStateException("目标目录不允许创建文件")

            conn = java.net.URL(url).openConnection() as java.net.HttpURLConnection
            conn.requestMethod = "GET"
            conn.instanceFollowRedirects = true
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            // B站 CDN 少了 Referer 就是 403，请求头必须由 Dart 侧传进来
            // （哪条源要什么头只有各自的适配器知道，这里不硬编码）。
            headers.forEach { (k, v) -> conn.setRequestProperty(k, v) }

            val code = conn.responseCode
            if (code != java.net.HttpURLConnection.HTTP_OK) {
                throw IllegalStateException("源站返回 $code")
            }
            val total = conn.contentLength.toLong()
            var written = 0L
            var lastReport = -1

            ctx.contentResolver.openOutputStream(docUri, "w")?.use { out ->
                conn.inputStream.use { input ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        if (cancel.get()) {
                            discard(ctx, docUri)
                            report(taskId, status = "canceled", done = written, total = total)
                            return
                        }
                        val n = input.read(buf)
                        if (n <= 0) break
                        out.write(buf, 0, n)
                        written += n
                        // 每变化 1% 报一次；总长未知就每 2MB 报一次
                        val beat = if (total > 0) {
                            ((written * 100) / total).toInt() != lastReport
                        } else {
                            (written / (2 * 1024 * 1024)).toInt() != lastReport
                        }
                        if (beat) {
                            lastReport = if (total > 0) {
                                ((written * 100) / total).toInt()
                            } else {
                                (written / (2 * 1024 * 1024)).toInt()
                            }
                            report(taskId, status = "running", done = written, total = total)
                        }
                    }
                    out.flush()
                }
            }

            // 声称有 12MB、只写进去 3MB = 被掐断的流。当失败处理并清掉半成品，
            // 否则会留下一条「列表里有、点开没声」的歌。
            if (total > 0 && written < total) {
                discard(ctx, docUri)
                throw IllegalStateException("下载不完整（$written / $total 字节）")
            }

            val finalSize = if (written > 0) written else writtenOf(ctx, docUri)
            report(
                taskId,
                status = "done",
                done = finalSize,
                total = if (total > 0) total else finalSize,
                uri = docUri.toString(),
                name = displayName(ctx, docUri) ?: fileName,
                size = finalSize,
            )
        } catch (e: Exception) {
            docUri?.let { discard(ctx, it) }
            report(taskId, status = "failed", error = e.message ?: e.javaClass.simpleName)
        } finally {
            runCatching { conn?.disconnect() }
            cancelFlags.remove(taskId)
        }
    }

    private fun cancelDownload(
        taskId: String?,
        result: MethodChannel.Result,
    ) {
        if (taskId == null) {
            result.error("bad_argument", "缺少 taskId", null)
            return
        }
        val flag = cancelFlags[taskId]
        if (flag == null) {
            // ⚠️ 报完错必须 return。旧写法是
            //   cancelFlags[taskId]?.set(true) ?: result.error("no_task", ...)
            //   result.success(null)
            // 任务已经结束时等于**回了两次**，平台线程直接抛
            // "Reply already submitted"——取消一条刚下完的任务就能把 app 炸掉。
            result.error("no_task", "这个下载已经结束了", null)
            return
        }
        flag.set(true)
        result.success(null)
    }

    /** 删掉一个我们自己在 SAF 目录里创建的文档（移除已下载条目用）。 */
    private fun deleteFile(
        ctx: Context,
        uriString: String?,
        result: MethodChannel.Result,
    ) {
        if (uriString.isNullOrBlank()) {
            result.error("bad_argument", "缺少 uri", null)
            return
        }
        val uri = Uri.parse(uriString)
        val ok = runCatching {
            if (DocumentsContract.isDocumentUri(ctx, uri)) {
                DocumentsContract.deleteDocument(ctx.contentResolver, uri)
            } else {
                ctx.contentResolver.delete(uri, null, null) > 0
            }
        }.getOrDefault(false)
        if (ok) {
            result.success(true)
        } else {
            result.error("delete_failed", "没能删掉这个文件", null)
        }
    }

    private fun discard(ctx: Context, uri: Uri) {
        runCatching { DocumentsContract.deleteDocument(ctx.contentResolver, uri) }
    }

    private fun writtenOf(ctx: Context, uri: Uri): Long = runCatching {
        ctx.contentResolver.query(uri, arrayOf(android.provider.DocumentsContract.Document.COLUMN_SIZE), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getLong(0) else 0L }
            ?: 0L
    }.getOrDefault(0L)

    private fun displayName(ctx: Context, uri: Uri): String? = runCatching {
        ctx.contentResolver.query(uri, arrayOf(android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    }.getOrNull()

    /**
     * 往 Dart 推一条进度/结果。
     *
     * MethodChannel 只能在平台线程上调，而这里跑在下载线程上——所以先
     * post 回主线程。忘了这一步在 debug 模式下会直接抛
     * "Methods marked with @UiThread must be executed on the main thread"。
     */
    private fun report(
        taskId: String,
        status: String,
        done: Long = 0,
        total: Long = 0,
        uri: String? = null,
        name: String? = null,
        size: Long = 0,
        error: String? = null,
    ) {
        val sink = progressChannel ?: return
        val payload = mapOf(
            "taskId" to taskId,
            "status" to status,
            "done" to done,
            "total" to total,
            "uri" to uri,
            "name" to name,
            "size" to size,
            "error" to error,
        )
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            runCatching { sink.invokeMethod("download", payload) }
                .onFailure { e ->
                    // 这里**不能**静默：回推丢了 Dart 侧就永远等不到终态，
                    // 界面上是「一直下载中」，而原生这边看起来一切正常。
                    // 至少让 logcat 留得下这句话（进度通道 MissingPluginException
                    // 是真实存在的一种丢法：引擎 detach 后 handler 已经不在）。
                    Log.w(TAG, "进度回推失败 ${payload["status"]} ${payload["taskId"]}: ${e.message}")
                }
        }
    }

    private fun describeOrError(
        ctx: Context,
        uriString: String?,
        result: MethodChannel.Result,
    ) {
        if (uriString.isNullOrBlank()) {
            result.error("bad_argument", "缺少 uri", null)
            return
        }
        result.success(describe(ctx, uriString))
    }

    // ── 选目录 ──────────────────────────────────────────────────────

    private fun pickDirectory(ctx: Context, call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "已经有一个目录选择器在前台", null)
            return
        }
        val activity: Activity = activityBinding?.activity ?: run {
            result.error("no_activity", "当前没有可用于拉起系统选择器的界面", null)
            return
        }

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            // ⚠️ **不要** addCategory(CATEGORY_OPENABLE)（2026-10-11 真机定位，
            // 魅族 21 / Android 16）。那个类别是给 OPEN_DOCUMENT / GET_CONTENT
            // 用的；DocumentsUI 的 OPEN_DOCUMENT_TREE filter 里没有它，于是
            // 隐式解析直接 0 命中，抛 ActivityNotFoundException。
            // 对照实验（adb shell 侧）：
            //   query-activities -a OPEN_DOCUMENT_TREE
            //     → com.android.documentsui/.picker.PickActivity
            //   query-activities -a OPEN_DOCUMENT_TREE -c ...OPENABLE
            //     → No activities found
            // 不给 WRITE 标志的话，系统选择器里「使用此文件夹」会只读授权，
            // 下载目录必须带 WRITE。
            addFlags(FLAG_RW)
            // 注意：这里**不**再传标题。旧写法把意图包进 chooser 只是为了显示
            // 一行标题，代价见下面 pickDirectory 里的真机事故记录。系统选择器
            // 自己会写「选择文件夹」，而 call.argument("reason") 那句话现在
            // 只进诊断日志（Dart 侧记），不再参与界面。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // 从上次选过的目录打开，比每次回到存储根更好找。
                // 非法/过期的 initialUri 会让部分厂商 ROM 直接崩在选择器里，
                // 所以解析失败就退化成不带初始位置。
                (call.argument<String>("initialUri"))?.let { raw ->
                    runCatching {
                        putExtra(
                            DocumentsContract.EXTRA_INITIAL_URI,
                            Uri.parse(raw),
                        )
                    }
                }
            }
        }

        // ⚠️ **不要**用 Intent.createChooser 包一层（2026-10-11 真机定位）。
        // 魅族 21 / Android 16 上的现场：包了 chooser 之后 logcat 只有
        //   START ... act=android.intent.action.CHOOSER
        //   cmp=com.android.intentresolver/.ChooserActivityLauncher
        // 紧跟着 ChooserActivity 立刻 destroy，界面一秒都没露，Dart 侧收到
        // RESULT_CANCELED → 用户看到的就是「点本地目录没反应」。
        // 根因是 Android 11+ 的包可见性：chooser 要枚举能处理内层 intent 的
        // 应用，而调用方没有对应的 <queries> 声明时它看到一个都没有，于是
        // 直接关闭。而 ACTION_OPEN_DOCUMENT_TREE 本来就只有系统 DocumentsUI
        // 一个处理者（`cmd package query-activities` 实测 1 个），
        // 包 chooser 没有任何收益，纯增加一个失败模式。
        //
        // 这里也**不做** `resolveActivity != null` 的预检查（第一版这么写了，
        // 结果在真机上把选择器拦死）：可见性规则的 intent 要连
        // `CATEGORY_OPENABLE` 一起声明才匹配得上 DocumentsUI 的 filter，
        // 少一个类别就查出 0 个候选，明明是有的。而 `startActivityForResult`
        // 本身不受包可见性限制——直接投，失败由下面的异常如实说。
        pending = result
        try {
            activity.startActivityForResult(intent, REQ_PICK_DIR)
        } catch (e: ActivityNotFoundException) {
            pending = null
            result.error(
                "no_picker",
                "系统里没有可用的文件夹选择器：${e.message}",
                null,
            )
        } catch (e: Exception) {
            pending = null
            result.error("picker_failed", "无法打开系统目录选择器：${e.message}", null)
        }
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ): Boolean {
        if (requestCode != REQ_PICK_DIR) return false
        val reply = pending ?: return false
        pending = null

        val ctx = appContext ?: run {
            reply.error("no_context", "插件已脱离引擎", null)
            return true
        }
        if (resultCode != Activity.RESULT_OK) {
            reply.success(null) // 用户取消：不是错误
            return true
        }
        val taken = pickedUri(data) ?: run {
            reply.error("empty_result", "选择器没有返回目录", null)
            return true
        }
        val treeUri = normalizeTreeUri(taken) ?: run {
            reply.error("bad_uri", "返回的不是目录 uri：$taken", null)
            return true
        }

        val persisted = takePersistable(ctx, treeUri)
        reply.success(
            // granted 在这里**不能**照抄 describe 的算法：describe 看的是
            // persistedUriPermissions，而 takePersistable 失败时系统给的是一次性
            // 授权、不在这份列表里。刚选完这一刻肯定是能用的，所以 granted 恒真，
            // 「能不能活到下次开机」由 persisted 这个字段单独说。
            describe(ctx, treeUri.toString()).toMutableMap().apply {
                put("granted", true)
                put("exists", true)
                put("persisted", persisted)
            },
        )
        return true
    }

    /**
     * 从返回的 Intent 里把目录 uri 挖出来。
     *
     * 正常路径是 `data`；但部分 ROM/提供方会把结果塞进 [Intent.getClipData]
     * 或 [Intent.EXTRA_STREAM]（AOSP 自己的 Files 走前者，一些三方文档提供器
     * 走后者）。漏掉这两种就是「选了目录却没反应」，而用户完全看不出区别。
     */
    private fun pickedUri(data: Intent?): Uri? {
        data ?: return null
        data.data?.let { return it }
        data.clipData?.let { clip ->
            if (clip.itemCount > 0) clip.getItemAt(0).uri?.let { return it }
        }
        @Suppress("DEPRECATION")
        val single: Uri? = data.getParcelableExtra(Intent.EXTRA_STREAM)
        @Suppress("DEPRECATION")
        val many: ArrayList<Uri>? = data.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
        return many?.firstOrNull() ?: single
    }

    /**
     * 返回持久化授权是否真的拿到了。
     *
     * `takePersistableUriPermission` 对某些提供方会抛 SecurityException
     * （拿到的是一次性授权）。这时候**不能**报错——目录这次是可用的，
     * 但要把「persisted=false」告诉上层，让它提示「重启后需重新选择」。
     */
    private fun takePersistable(ctx: Context, uri: Uri): Boolean = try {
        ctx.contentResolver.takePersistableUriPermission(uri, FLAG_RW)
        true
    } catch (e: Exception) {
        false
    }

    private fun normalizeTreeUri(uri: Uri): Uri? {
        // ACTION_OPEN_DOCUMENT_TREE 正常返回 content://<provider>/tree/<docId>。
        // 个别 ROM 会回一个带完整 document 后缀的 uri，这里统一成 tree 形态。
        if (!DocumentsContract.isTreeUri(uri)) return null
        val docId = DocumentsContract.getTreeDocumentId(uri) ?: return null
        return DocumentsContract.buildTreeDocumentUri(uri.authority, docId)
    }

    // ── 描述 / 列举 / 释放 ──────────────────────────────────────────

    private fun listDirectories(ctx: Context): List<Map<String, Any?>> =
        ctx.contentResolver.persistedUriPermissions
            .filter { it.uri.toString().contains("/tree/") }
            .map { describe(ctx, it.uri.toString()) }

    private fun releaseDirectory(
        ctx: Context,
        uriString: String?,
        result: MethodChannel.Result,
    ) {
        if (uriString.isNullOrBlank()) {
            result.error("bad_argument", "缺少 uri", null)
            return
        }
        val uri = Uri.parse(uriString)
        runCatching { ctx.contentResolver.releasePersistableUriPermission(uri, FLAG_RW) }
        result.success(null)
    }

    private fun describe(ctx: Context, uriString: String): Map<String, Any?> {
        val uri = Uri.parse(uriString)
        val doc = DocumentFile.fromTreeUri(ctx, uri)
        val granted = hasReadWrite(ctx, uri)
        return mapOf(
            "uri" to uri.toString(),
            // 显示名取 tree 文档的 leaf（"Music" / "Download"），不是整串 uri，
            // 设置页要给用户看得懂的东西。
            "name" to (doc?.name ?: lastSegment(uri)),
            "posixPath" to treeUriToPosixPath(uri),
            "granted" to granted,
            "exists" to (doc?.exists() == true),
            "writable" to (granted && dirSupportsCreate(ctx, uri)),
        )
    }

    private fun hasReadWrite(ctx: Context, uri: Uri): Boolean =
        ctx.contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission && it.isWritePermission
        }

    /**
     * 能不能在这个目录里创建文件——读文档的 FLAGS，而不是「建一个探针文件再删掉」。
     *
     * 探针法能给出更硬的答案，但它要在**用户挑的目录**里创建并删除文件；
     * 万一删除失败就留下一个垃圾文件，而那是一个真实用户目录。用框架自己
     * 依据的 FLAG_DIR_SUPPORTS_CREATE 判断，代价是极少数提供方谎报标志位，
     * 真写的时候再如实失败——那时用户会看到失败原因，比凭空多出个文件好。
     */
    private fun dirSupportsCreate(ctx: Context, treeUri: Uri): Boolean {
        val docId = DocumentsContract.getTreeDocumentId(treeUri) ?: return false
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
        val flags: Int = runCatching {
            ctx.contentResolver.query(
                docUri,
                arrayOf(DocumentsContract.Document.COLUMN_FLAGS),
                null,
                null,
                null,
            )?.use { c -> if (c.moveToFirst()) c.getInt(0) else null }
        }.getOrNull() ?: return false
        return flags and DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE != 0
    }

    // ── tree uri ↔ 真实路径 ────────────────────────────────────────

    /**
     * SAF tree uri → MediaStore 用的 posix 路径前缀。
     *
     * 只有 `com.android.externalstorage.documents`（机身存储与 SD 卡）能这样换算；
     * SAF 提供方还能是网盘、蓝牙之类的文档提供器，那些没有 posix 路径，返回
     * null 让上层降级成「不按目录过滤」。
     */
    private fun treeUriToPosixPath(uri: Uri): String? {
        if (uri.authority != "com.android.externalstorage.documents") return null
        val docId = DocumentsContract.getTreeDocumentId(uri) ?: return null
        val sep = docId.indexOf(':')
        val volume = if (sep < 0) PRIMARY else docId.substring(0, sep)
        val relative = if (sep < 0) "" else docId.substring(sep + 1)
        val root = when {
            volume == PRIMARY -> Environment.getExternalStorageDirectory().absolutePath
            volume == "sdcard" -> Environment.getExternalStorageDirectory().absolutePath
            else -> File("/storage/$volume").absolutePath
        }
        return File(root, relative).absolutePath
    }

    private fun lastSegment(uri: Uri): String =
        uri.lastPathSegment?.substringAfterLast(':') ?: "已选目录"
}
