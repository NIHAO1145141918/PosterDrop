import Foundation

/// 直接从 LaunchServices 的 `csstore` 里挖 App 清单和容器 UUID。
///
/// 3105 的 `ContainerStore.launchServicesStoreIdentifiers()` 用的是同一招：
/// 从 `com.apple.lsd` 容器的 `Library/Caches/com.apple.LaunchServices-*-v2.csstore`
/// 里把 bundleID 全捞出来，一次读文件换掉一整轮 inode 扫描。
///
/// 我们多挖一样东西：csstore 里同时存了 `DataContainerURL`，也就是
/// `/var/mobile/Containers/Data/Application/<UUID>` 这类字符串。
/// 所以除了 bundleID，还能直接拿到容器路径——连 `container_query` 都不用问。
///
/// 这条路的价值在于成本：读一个几十 MB 的文件约 0.3 秒，
/// 而 `fsgetpath` 枚举 1.2 亿个 object id 要 250 秒。
/// 成本差三个数量级，所以哪怕三个候选目录只有一成希望能签通，也值得先试。
enum LaunchServicesStore {
    struct Harvest {
        /// csstore 里出现的 bundleID（去重、已剔除 group./systemgroup.）
        let identifiers: [String]
        /// `Data/Application/<UUID>` 形式的容器路径
        let containers: [String]
        /// 命中的 csstore 文件路径，只用于日志
        let source: String
    }

    /// 候选目录，按命中概率排序。
    /// 前两个是同一条路的两种写法（`/var` 与 `/private/var`），
    /// `/var/db/lsd` 是 3105 列的旧布局兜底。
    static let candidateDirectories = [
        "/var/mobile/Library/Caches",
        "/private/var/mobile/Library/Caches",
        "/var/db/lsd"
    ]

    /// 单个 csstore 的上限。3105 用的也是 64MB，超过不读——正常的库只有几 MB。
    private static let sizeLimit = 64 * 1024 * 1024
    /// 候选数量上限，跟 3105 一致。真实设备上系统 App + 用户 App 大约 300–500 个。
    private static let maximumCandidates = 65_536
    /// 用字节数组而不是 `Data`：内层循环要走 64MB，每轮构造一次临时数组会拖垮性能。
    private static let needleBytes = Array("Data/Application/".utf8)
    private static let uuidLength = 36

    /// 尝试从 csstore 直接捞出容器列表。
    /// 任何一步不通都返回 nil，调用方回落到 `fsgetpath` 扫描，不会抛错也不会卡住。
    static func harvest(log: (String) -> Void) -> Harvest? {
        for directory in candidateDirectories {
            guard let names = listDirectory(directory) else { continue }

            // csstore 的名字形如 com.apple.LaunchServices-014501-v2.csstore。
            // 不同系统版本后缀有出入，所以只卡前缀和后缀。
            let stores = names.filter {
                $0.hasPrefix("com.apple.LaunchServices") && $0.hasSuffix(".csstore")
            }
            guard !stores.isEmpty else { continue }

            for name in stores {
                let path = (directory as NSString).appendingPathComponent(name)
                guard let data = readFile(path) else { continue }
                guard data.count > 1_024 else { continue }

                let result = extract(from: data, log: log)
                if !result.containers.isEmpty || result.identifiers.count > 20 {
                    log("   csstore 命中：\(path)（\(data.count / 1024) KB）")
                    return Harvest(
                        identifiers: result.identifiers,
                        containers: result.containers,
                        source: path
                    )
                }
            }
        }
        return nil
    }

    // MARK: - 读目录 / 读文件

    /// 只做纯文件读，**不签发扩展**。
    ///
    /// 这里刻意不去调 `SandboxEscape.grant`：探测发生在清理流程内部，此时
    /// `beginBatch` 已经把本 App 的 `Library/Caches` 换成了交换链接，
    /// 再对另一个路径签一次会 retarget 掉那个链接，后面几百个容器的统计会全部错位。
    /// 用一次可能失败的探测换一次整轮数据错误，不划算。
    ///
    /// 如果真机上这条路读得到，说明 `/var/mobile/Library/Caches` 对我们的沙盒
    /// 本来就是可读的；读不到就走 `fsgetpath`，行为跟之前完全一致。
    private static func listDirectory(_ path: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    private static func readFile(_ path: String) -> Data? {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?
            .int64Value ?? 0
        guard size > 0, size <= Int64(sizeLimit) else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    }

    // MARK: - 解析

    /// csstore 是 LaunchServices 的二进制库，没有公开格式，也不需要解。
    /// 3105 的做法就是把它当字节流扫 ASCII 串，我们照做，只是多扫一种模式：
    /// 除了 bundleID，还找 `Data/Application/<UUID>`。
    private static func extract(
        from data: Data,
        log: (String) -> Void
    ) -> (identifiers: [String], containers: [String]) {
        var identifiers: [String] = []
        var containers: [String] = []
        var seenIdentifiers = Set<String>()
        var seenContainers = Set<String>()

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count
            var index = 0

            while index < count, identifiers.count < maximumCandidates {
                guard isIdentifierByte(base[index]) else {
                    index += 1
                    continue
                }
                let start = index
                while index < count, isIdentifierByte(base[index]) {
                    index += 1
                }
                let length = index - start
                guard length >= 3, length <= 255 else { continue }

                // bundleID：至少一个点，且不是 group 容器名（那些是签名里的，不是 App）
                let token = String(decoding: UnsafeBufferPointer(start: base + start, count: length), as: UTF8.self)
                guard token.contains("."),
                      !token.hasPrefix("group."),
                      !token.hasPrefix("systemgroup."),
                      isValidBundleIdentifier(token) else { continue }
                if seenIdentifiers.insert(token).inserted {
                    identifiers.append(token)
                }
            }

            // 第二遍找容器路径。UUID 里的连字符和标识符字节重叠，
            // 混在上面那趟里会被切断，所以单独扫一遍。
            let needleCount = needleBytes.count
            var cursor = 0
            needleBytes.withUnsafeBufferPointer { needleBuffer in
                guard let needleBase = needleBuffer.baseAddress else { return }
                while cursor + needleCount + uuidLength <= count, containers.count < maximumCandidates {
                    guard memcmp(base + cursor, needleBase, needleCount) == 0 else {
                        cursor += 1
                        continue
                    }
                    let uuidStart = cursor + needleCount
                    let candidate = String(
                        decoding: UnsafeBufferPointer(start: base + uuidStart, count: uuidLength),
                        as: UTF8.self
                    )
                    if UUID(uuidString: candidate) != nil {
                        if seenContainers.insert(candidate).inserted {
                            containers.append("/private/var/mobile/Containers/Data/Application/\(candidate)")
                        }
                        cursor = uuidStart + uuidLength
                    } else {
                        cursor += 1
                    }
                }
            }
        }

        log("   csstore 解析：\(identifiers.count) 个 bundleID，\(containers.count) 个容器路径")
        return (identifiers, containers)
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 45, 46:                       // - .
            return true
        case 48...57, 65...90, 97...122:   // 0-9 A-Z a-z
            return true
        case 95:                           // _
            return true
        default:
            return false
        }
    }

    /// 反向域名，至少两段，每段非空且首字符不是数字。
    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        for part in parts {
            guard !part.isEmpty else { return false }
            guard let first = part.unicodeScalars.first, !(48...57).contains(first.value) else {
                return false
            }
        }
        return true
    }
}
