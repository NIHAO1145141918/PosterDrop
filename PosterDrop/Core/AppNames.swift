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

        // ② 容器管理器写在根目录的元数据。正常是 0600 root，读得到算意外之喜。
        if let data = readSmallFile(containerFD, ".com.apple.mobile_container_manager.metadata.plist"),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dictionary = plist as? [String: Any] {
            for key in ["MCMMetadataIdentifier", "MCMMetadataBundleIdentifier"] {
                if let value = dictionary[key] as? String, looksLikeBundleID(value) {
                    remember(container: containerName, bundleID: value)
                    return value
                }
            }
        }

        // ③ 偏好设置文件名。排除 .GlobalPreferences 这类系统文件。
        if let hit = firstBundleID(in: containerFD, relative: "Library/Preferences", suffixes: [".plist"]) {
            remember(container: containerName, bundleID: hit)
            return hit
        }

        // ④ 窗口状态存档：`Library/Saved Application State/com.xingin.xhs.savedState`。
        //    这目录只有 App 真的被系统挂起过才存在，但在常用 App 上比偏好设置还全。
        if let hit = firstBundleID(
            in: containerFD,
            relative: "Library/Saved Application State",
            suffixes: [".savedState"]
        ) {
            remember(container: containerName, bundleID: hit)
            return hit
        }

        // ⑤ Cookie 文件：`Library/Cookies/com.tencent.xin.binarycookies`。
        if let hit = firstBundleID(
            in: containerFD,
            relative: "Library/Cookies",
            suffixes: [".binarycookies"]
        ) {
            remember(container: containerName, bundleID: hit)
            return hit
        }

        // ⑥ 缓存子目录。`Library/Caches/com.tencent.xin` 这种很常见。
        if let hit = firstBundleID(in: containerFD, relative: "Library/Caches", suffixes: []) {
            remember(container: containerName, bundleID: hit)
            return hit
        }

        // ⑦ 快照目录，名字形如 `com.xingin.xhs-<UUID>`。
        if let hit = snapshotBundleID(containerFD) {
            remember(container: containerName, bundleID: hit)
            return hit
        }

        return nil
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

    private static let defaultsKey = "container.bundleIDs"
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

    // MARK: - 目录扫描

    /// 在 `relative` 目录里找第一个像 bundle id 的条目。
    /// `suffixes` 非空时先去掉后缀再判断（偏好设置是 `<bundleID>.plist`）。
    private static func firstBundleID(
        in containerFD: Int32,
        relative: String,
        suffixes: [String]
    ) -> String? {
        guard let fd = FileTree.openSubdirectory(containerFD, relative) else { return nil }
        defer { close(fd) }

        var best: String?
        let iterator = dup(fd)
        guard iterator >= 0, let directory = fdopendir(iterator) else {
            if iterator >= 0 { close(iterator) }
            return nil
        }
        defer { closedir(directory) }

        while let entry = readdir(directory) {
            var name = FileTree.entryName(entry)
            if name == "." || name == ".." { continue }
            for suffix in suffixes where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
            guard looksLikeBundleID(name) else { continue }
            // 同一目录可能有多份（比如 App 自己的 + 扩展的），取最短的那个，
            // 它通常是主 App；扩展的 bundle id 更长。
            if let current = best {
                if name.count < current.count { best = name }
            } else {
                best = name
            }
        }
        return best
    }

    /// `Library/SplashBoard/Snapshots` 里的条目叫 `com.xingin.xhs-<UUID>`。
    private static func snapshotBundleID(_ containerFD: Int32) -> String? {
        guard let fd = FileTree.openSubdirectory(
            containerFD, "Library/SplashBoard/Snapshots"
        ) else { return nil }
        defer { close(fd) }

        let iterator = dup(fd)
        guard iterator >= 0, let directory = fdopendir(iterator) else {
            if iterator >= 0 { close(iterator) }
            return nil
        }
        defer { closedir(directory) }

        while let entry = readdir(directory) {
            let raw = FileTree.entryName(entry)
            guard !raw.isEmpty, raw != ".", raw != ".." else { continue }
            // 去掉尾部 `-<UUID>`（36 字符）
            let candidate: String
            if raw.count > 38, raw[raw.index(raw.endIndex, offsetBy: -37)] == "-" {
                candidate = String(raw.dropLast(37))
            } else {
                continue
            }
            if looksLikeBundleID(candidate) { return candidate }
        }
        return nil
    }

    // MARK: - 判定

    /// 反向域名的粗判。
    ///
    /// 不追求严格：容器里还有 `Snapshots`、`imagecache` 这类普通目录，
    /// 只要「至少两段、首段是常见顶级域、字符集干净」就能挡掉绝大多数噪音。
    static func looksLikeBundleID(_ name: String) -> Bool {
        guard name.count >= 6, name.count <= 155 else { return false }
        guard !name.hasPrefix("."), !name.hasPrefix("com.apple.") else { return false }
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
        limit: Int = 32_768
    ) -> Data? {
        let fd = relative.withCString {
            openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else { return nil }
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
