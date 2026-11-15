//
//  AppNames.swift
//  PosterDrop
//
//  容器 → bundle id → 真实 App 名。
//
//  清理页原来直接显示容器 UUID，因为拿不到 containermanagerd 的索引：
//  `container_query` 在自签 App 里只返回自己，容器目录的
//  `com.apple.containermanager.identifier` 扩展属性也常被拦。
//
//  但容器里面的文件是按 bundle id 命名的，绕过索引也能反推：
//    1. xattr com.apple.containermanager.identifier   —— 一条 syscall，最准
//    2. .com.apple.mobile_container_manager.metadata.plist 的 MCMMetadataIdentifier
//    3. Library/Preferences/<bundleID>.plist          —— 存过一次 NSUserDefaults 就有
//    4. Library/Saved Application State/<bundleID>.savedState
//    5. Library/Cookies/<bundleID>.binarycookies
//    6. Library/Caches/<bundleID>                     —— 反向域名的子目录
//    7. Library/SplashBoard/Snapshots/<bundleID>-…    —— 快照目录带 bundle id 前缀
//
//  拿到 bundle id 之后再去表里换成「微信」「小红书」这种名字。表是内置的，
//  因为读取别的 App 的 Info.plist 需要 LaunchServices 权限。表里没有的
//  保留 bundle id 原样显示——它仍然是人能看懂的标识，比 UUID 强得多。
//

import Foundation

enum AppNames {

    // MARK: - 反查

    /// 容器里以 bundle id 命名的位置。顺序按「命中率 × 可信度」排：
    /// `HTTPStorages` 只有联网 App 才有、且名字就是 bundle id，几乎不会误判；
    /// 偏好设置覆盖面最广，但目录里常混着系统写入的 `com.apple.*`。
    private struct Source {
        let tag: String
        let relative: String
        /// 条目名要剥掉的后缀，比如偏好设置是 `<bundleID>.plist`。
        var suffixes: [String] = []
        /// 条目名形如 `<bundleID>-<UUID>`，取横线前的部分。
        var stripsUUID: Bool = false

        static let all: [Source] = [
            Source(tag: "http", relative: "Library/HTTPStorages"),
            Source(tag: "webkit", relative: "Library/WebKit"),
            Source(tag: "prefs", relative: "Library/Preferences", suffixes: [".plist"]),
            Source(tag: "saved", relative: "Library/Saved Application State", suffixes: [".savedState"]),
            Source(tag: "cookie", relative: "Library/Cookies", suffixes: [".binarycookies"]),
            Source(tag: "support", relative: "Library/Application Support"),
            Source(tag: "caches", relative: "Library/Caches"),
            Source(tag: "snapshot", relative: "Library/SplashBoard/Snapshots", stripsUUID: true)
        ]
    }

    private enum Lookup {
        case hit(String)
        case empty
        case unreadable(Int32)
    }

    /// 把 errno 说成人话。
    ///
    /// 原来直接打数字，`拒2` 看着像「权限被拒」，其实 2 是 ENOENT——目录压根没建过，
    /// 和「沙箱不让读」是两个完全不同的修法。日志要能直接指向原因，不能让人再查表。
    private static func describe(_ code: Int32) -> String {
        switch code {
        case 0: return "空"
        case ENOENT: return "无"          // 目录不存在（App 没建过这一级）
        case EACCES, EPERM: return "拒"   // 沙箱拒绝
        case ENOTDIR: return "非目录"
        default: return "错\(code)"
        }
    }

    /// 从容器根目录的 fd 猜 bundle id。取不到返回 nil。
    ///
    /// 全部用 containerFD 做起点，不拼全路径：既省一次前缀解析，
    /// 也避免路径里的 UUID 被后续沙箱检查重新审视一遍。
    static func bundleID(containerFD: Int32, containerName: String) -> String? {
        if let known = cachedBundleID(forContainer: containerName) { return known }

        // ① 扩展属性
        if let value = FileTree.xattr(containerFD, "com.apple.containermanager.identifier"),
           looksLikeBundleID(value) {
            remember(container: containerName, bundleID: value)
            return value
        }

        // ② 容器管理器写在根目录的元数据。正常是 0644，读得到就是一条铁证。
        var metaNote = "缺"
        var metaError: Int32 = 0
        if let data = readSmallFile(
            containerFD,
            ".com.apple.mobile_container_manager.metadata.plist",
            error: &metaError
        ) {
            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
               let dictionary = plist as? [String: Any] {
                for key in ["MCMMetadataIdentifier", "MCMMetadataBundleIdentifier"] {
                    if let value = dictionary[key] as? String, looksLikeBundleID(value) {
                        remember(container: containerName, bundleID: value)
                        return value
                    }
                }
                // 文件读到了却没有这两个键：多半是 group / 系统容器，键名不同。
                metaNote = "无键(\(dictionary.keys.sorted().prefix(3).joined(separator: "/")))"
            } else {
                metaNote = "解析失败(\(data.count)B)"
            }
        } else {
            metaNote = describe(metaError)
        }

        // ③ 逐级查目录。失败原因攒起来，识别不出来时留给诊断页。
        var trace: [String] = ["meta=\(metaNote)"]
        for source in Source.all {
            switch lookup(source, in: containerFD) {
            case .hit(let identifier):
                remember(container: containerName, bundleID: identifier)
                return identifier
            case .empty:
                trace.append("\(source.tag)=空")
            case .unreadable(let code):
                trace.append("\(source.tag)=\(describe(code))")
            }
        }

        // 还是认不出来，就把容器里实际有什么打出来。
        // 上一版只知道「空的」，看不出这些容器到底是「没用过的新容器」还是
        // 「结构完全不同的扩展容器」，只能瞎猜着补数据源。这里一次列清楚。
        if let root = briefNames(containerFD, nil) { trace.append("根[\(root)]") }
        if let library = briefNames(containerFD, "Library") { trace.append("库[\(library)]") }

        noteFailure(containerName, trace: trace)
        return nil
    }

    /// 列一个目录的前几个条目名，用于诊断。打不开返回 nil。
    private static func briefNames(_ parent: Int32, _ relative: String?, limit: Int = 6) -> String? {
        let fd: Int32
        if let relative {
            fd = relative.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
        } else {
            fd = parent
        }
        guard fd >= 0 else { return nil }
        let owned = relative != nil
        defer { if owned { close(fd) } }

        let iterator = dup(fd)
        guard iterator >= 0, let directory = fdopendir(iterator) else {
            if iterator >= 0 { close(iterator) }
            return nil
        }
        defer { closedir(directory) }

        var names: [String] = []
        while let entry = readdir(directory), names.count < limit {
            let name = FileTree.entryName(entry)
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        guard !names.isEmpty else { return "空" }
        return names.joined(separator: ",")
    }

    // MARK: - 单级查找

    private static func lookup(_ source: Source, in containerFD: Int32) -> Lookup {
        // 不用 FileTree.openSubdirectory：它内部会先碰一次 rlimit 初始化，
        // 那一行可能改掉 errno，诊断里就会把 EPERM 写成别的码。
        let fd = source.relative.withCString {
            openat(containerFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else { return .unreadable(errno) }
        defer { close(fd) }

        let iterator = dup(fd)
        guard iterator >= 0, let directory = fdopendir(iterator) else {
            if iterator >= 0 { close(iterator) }
            return .unreadable(errno)
        }
        defer { closedir(directory) }

        var names: [String] = []
        while let entry = readdir(directory) {
            var name = FileTree.entryName(entry)
            if name.isEmpty || name == "." || name == ".." { continue }

            for suffix in source.suffixes where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
            if source.stripsUUID {
                guard let stripped = stripTrailingUUID(name) else { continue }
                name = stripped
            }
            if looksLikeBundleID(name) { names.append(name) }
        }

        guard !names.isEmpty, let best = pick(from: names) else { return .empty }
        return .hit(best)
    }

    /// 同级多个候选时的取舍。
    ///
    /// 第三方优先：`Library/Preferences` 里常有系统代写的 `com.apple.*.plist`，
    /// 直接取最短的那个会张冠李戴。只有整级没有第三方条目时，才接受
    /// `com.apple.*`——而且必须在内置名称表里，否则 `com.apple.security` 之类
    /// 的公共前缀会被当成 App 名。
    private static func pick(from names: [String]) -> String? {
        let thirdParty = names.filter { !$0.lowercased().hasPrefix("com.apple.") }
        // 表里认识的直接锁定，避免容器的 SDK 缓存目录（`com.foo.sdk` 这种更短的名字）抢位
        if let known = thirdParty.first(where: { table[$0.lowercased()] != nil }) { return known }
        if let best = thirdParty.min(by: { $0.count < $1.count }) { return best }
        return names.first { table[$0.lowercased()] != nil }
    }

    /// `<bundleID>-<36 位 UUID>` → `<bundleID>`。不像就别用。
    private static func stripTrailingUUID(_ name: String) -> String? {
        guard name.count > 38 else { return nil }
        let tail = name.suffix(37)
        guard tail.first == "-" else { return nil }
        let uuid = tail.dropFirst()
        guard uuid.count == 36, uuid.filter({ $0 == "-" }).count == 4 else { return nil }
        return String(name.dropLast(37))
    }

    // MARK: - 失败诊断

    private static let failureLock = NSLock()
    private static var failures: [String] = []

    private static func noteFailure(_ container: String, trace: [String]) {
        let short = String(container.prefix(8))
        let line = "\(short)：\(trace.joined(separator: " "))"
        failureLock.lock()
        if failures.count < 5 { failures.append(line) }
        failureLock.unlock()
    }

    /// 取出失败样本（取完即清），由调用方一次性写进日志。
    static func drainFailureSamples() -> [String] {
        failureLock.lock()
        defer { failureLock.unlock() }
        let result = failures
        failures.removeAll()
        return result
    }

    // MARK: - 显示名

    /// bundle id → 界面上的标题。
    /// 表里没有就返回 bundle id 本身；连 bundle id 都没有，调用方给兜底文案。
    static func display(bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return table[bundleID.lowercased()] ?? bundleID
    }

    /// 副标题：标题已经是名字时，下面一行用 bundle id 提示它是什么。
    static func subtitle(bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return table[bundleID.lowercased()] == nil ? nil : bundleID
    }

    // MARK: - 持久化

    /// 换 key 是为了让 1.1.1 那批可能记错的映射失效重算。
    /// 旧版本把 `com.apple.*` 判成「未识别」，算出来的短 ID 会一直粘在容器上。
    private static let defaultsKey = "container.bundleIDs.v2"
    private static let lock = NSLock()
    private static var cache: [String: String] = readCache()

    private static func cachedBundleID(forContainer name: String) -> String? {
        guard !name.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return cache[name]
    }

    private static func remember(container name: String, bundleID: String) {
        guard !name.isEmpty, bundleID.count <= 155 else { return }
        lock.lock()
        if cache[name] == bundleID {
            lock.unlock()
            return
        }
        cache[name] = bundleID
        let snapshot = cache
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: defaultsKey)
    }

    private static func readCache() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    // MARK: - 判定

    /// 反向域名的粗判。
    ///
    /// 不追求严格：容器里还有 `Snapshots`、`imagecache` 这类普通目录，
    /// 只要「至少两段、首段是常见顶级域、字符集干净」就能挡掉绝大多数噪音。
    static func looksLikeBundleID(_ name: String) -> Bool {
        guard name.count >= 6, name.count <= 155 else { return false }
        guard !name.hasPrefix(".") else { return false }
        guard name.contains("."), !name.contains("..") else { return false }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_")
        guard name.lowercased().unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return false
        }

        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }

        let known: Set<String> = [
            "com", "org", "net", "io", "tv", "me", "co", "cn", "app", "dev", "xyz",
            "info", "us", "uk", "jp", "kr", "de", "fr", "ru", "in", "sg", "hk", "tw",
            "ai", "gg", "to", "fm", "sh", "gg", "so", "ly", "name", "biz", "mobi"
        ]
        return known.contains(parts[0].lowercased())
    }

    // MARK: - 读文件

    /// 读根目录下的一个小文件（plist 之类）。限制长度，避免撞上大文件。
    private static func readSmallFile(
        _ parent: Int32,
        _ relative: String,
        error: inout Int32,
        limit: Int = 32_768
    ) -> Data? {
        let fd = relative.withCString {
            openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            error = errno
            return nil
        }
        defer { close(fd) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    // MARK: - 名称表

    /// 常见 App。源表按可读性写，查询时统一转小写（bundle id 大小写在实际
    /// 安装记录里并不一致，`com.apple.Music` 和 `com.apple.music` 都出现过）。
    ///
    /// 只收「确认无误」的：错一条比缺一条坏得多，所以宁缺毋滥。
    /// 表里没有的会原样显示 bundle id，仍然可读。
    private static let table: [String: String] = {
        var result: [String: String] = [:]
        result.reserveCapacity(rawTable.count)
        for (key, value) in rawTable { result[key.lowercased()] = value }
        return result
    }()

    private static let rawTable: [String: String] = [
        // 社交 / 通讯
        "com.tencent.xin": "微信",
        "com.tencent.mqq": "QQ",
        "com.tencent.tim": "TIM",
        "com.tencent.ww": "企业微信",
        "com.tencent.wework": "企业微信",
        "com.tencent.qqmail": "QQ 邮箱",
        "com.tencent.mtt": "QQ 浏览器",
        "com.sina.weibo": "微博",
        "com.zhihu.ios": "知乎",
        "com.douban.frodo": "豆瓣",
        "com.burbn.instagram": "Instagram",
        "net.whatsapp.whatsapp": "WhatsApp",
        "org.telegram.telegram-ios": "Telegram",
        "com.tinyspeck.chatlyio": "Slack",
        "com.hammerandchisel.discord": "Discord",
        "com.atebits.tweetie2": "X",
        "com.linkedin.linkedin": "LinkedIn",
        "com.facebook.facebook": "Facebook",
        "com.toyopagroup.picaboo": "Snapchat",
        "com.pinterest.pinterest": "Pinterest",
        "com.reddit.reddit": "Reddit",
        "com.linecorp.line": "LINE",
        "jp.naver.line": "LINE",
        "com.kakao.talk": "KakaoTalk",

        // 短视频 / 内容
        "com.ss.iphone.ugc.aweme": "抖音",
        "com.ss.iphone.article.news": "今日头条",
        "com.zhiliaoapp.musically": "TikTok",
        "com.bilibili.fateugc": "哔哩哔哩",
        "tv.danmaku.bilianime": "哔哩哔哩",
        "com.jkyssocial.jkyssocial": "快手",
        "com.kuaishou.nebula": "快手极速版",
        "com.xingin.xhs": "小红书",
        "com.tencent.qqlive": "腾讯视频",
        "com.tencent.weishi": "微视",
        "com.qiyi.iphone": "爱奇艺",
        "com.youku.YouKu": "优酷",
        "com.hunantv.iphone": "芒果 TV",
        "com.google.ios.youtube": "YouTube",
        "com.netflix.Netflix": "Netflix",
        "com.amazon.aiv.AIVApp": "Prime Video",

        // 音乐 / 音频
        "com.netease.cloudmusic": "网易云音乐",
        "com.tencent.qqmusic": "QQ 音乐",
        "com.kugou.kugou1002": "酷狗音乐",
        "com.kuwo.kwmusic": "酷我音乐",
        "com.spotify.client": "Spotify",
        "com.apple.Music": "音乐",
        "com.ximalaya.tinglite": "喜马拉雅",
        "com.dedao.iphone": "得到",

        // 电商 / 生活
        "com.alipay.iphoneclient": "支付宝",
        "com.taobao.taobao4iphone": "淘宝",
        "com.taobao.tmall4iphone": "天猫",
        "com.taobao.idletreasure": "闲鱼",
        "com.jd.jdmobilelite": "京东",
        "com.xunmeng.pinduoduo": "拼多多",
        "com.suning.SuningEBuy": "苏宁易购",
        "com.meituan.imeituan": "美团",
        "com.sankuai.meituan": "美团",
        "com.dianping.dpmobile": "大众点评",
        "me.ele.ios.eleme": "饿了么",
        "com.taobao.trip": "飞猪",
        "com.ctrip.ctrip": "携程",
        "com.qunar.iphoneclient": "去哪儿",
        "com.amazon.Amazon": "Amazon",
        "com.ebay.iphone": "eBay",
        "com.ubercab.UberClient": "Uber",
        "com.airbnb.app": "Airbnb",
        "com.yelp.yelpiphone": "Yelp",

        // 地图 / 出行
        "com.autonavi.amap": "高德地图",
        "com.baidu.BaiduMap": "百度地图",
        "com.google.Maps": "Google 地图",
        "com.didi.didi": "滴滴出行",
        "com.taxis99": "99",

        // 效率 / 办公
        "com.microsoft.Office.Word": "Word",
        "com.microsoft.Office.Excel": "Excel",
        "com.microsoft.Office.Powerpoint": "PowerPoint",
        "com.microsoft.Office.Outlook": "Outlook",
        "com.microsoft.teams": "Teams",
        "com.microsoft.skydrive": "OneDrive",
        "com.apple.Pages": "Pages",
        "com.apple.Numbers": "Numbers",
        "com.apple.Keynote": "Keynote",
        "com.apple.mobilemail": "邮件",
        "com.apple.MobileSMS": "信息",
        "com.apple.mobilesafari": "Safari",
        "com.apple.mobilenotes": "备忘录",
        "com.apple.reminders": "提醒事项",
        "com.apple.mobilecal": "日历",
        "com.apple.mobileslideshow": "照片",
        "com.notion.id": "Notion",
        "com.todoist.ios": "Todoist",
        "com.getdropbox.Dropbox": "Dropbox",
        "com.box.box-ios": "Box",
        "com.google.Drive": "Google 云端硬盘",
        "com.google.ios.chrome": "Chrome",
        "com.google.ios.gmail": "Gmail",
        "com.adobe.PhotoshopExpress": "Photoshop",
        "com.readdle.PDFExpert5": "PDF Expert",
        "com.goodnotes.goodnotes5": "Goodnotes",
        "com.flexcil.flexcil": "Flexcil",

        // 金融 / 银行
        "com.unionpay.chsp": "云闪付",
        "com.icbc.iphoneclient": "中国工商银行",
        "com.chinamworld.main": "中国建设银行",
        "com.bankcomm.iphone": "交通银行",
        "com.cmbchina.MobileBank": "招商银行",
        "com.paypal.iphone": "PayPal",
        "com.venmo.venmo": "Venmo",
        "com.squareup.cash": "Cash App",

        // 游戏 / 其他
        "com.mojang.minecraftpe": "Minecraft",
        "com.valvesoftware.SteamLink": "Steam Link",
        "com.tencent.tmgp.sgame": "王者荣耀",
        "com.tencent.tmgp.pubgmhd": "和平精英",
        "com.miHoYo.Yuanshen": "原神",
        "com.miHoYo.hkrpg": "崩坏：星穹铁道",
        "com.riotgames.league.wildrift": "英雄联盟手游",

        // 系统（会出现在其他 App 列表里时给个名字）
        "com.apple.PosterBoard": "PosterBoard",
        "com.apple.springboard": "主屏幕",
        "com.apple.mobileslideshow.Photos": "照片"
    ]
}
