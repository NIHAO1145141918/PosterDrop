//
//  PairingStore.swift
//  PosterDrop
//
//  配对记录（.mobiledevicepairing / .plist）的导入、校验与规范化存放。
//
//  为什么需要它：RSD（Remote Service Discovery）在 iOS 17+ 上走 TLS，
//  服务端 `remotepairingd` 只认「配对过的那把 host 私钥」。没有配对记录，
//  连 TLS 握手都过不去，后面的 installation_proxy 无从谈起。
//
//  两种来源：
//    · 完整 RPPairing（要开发者模式 + 输 PIN）
//    · 从配过对的电脑 / SideStore / LiveContainer 导出后导入（本项目走这条）
//
//  导入只解决「我是谁」，不解决「设备认不认我」——后者存在设备端
//  `/var/db/remotepairing/`，必须是这台设备上配对成功过的那份记录。
//

import Foundation
import Security

struct PairingCandidate: Identifiable {
    var id: String { url.path }
    let url: URL
    let size: Int
    let source: String
}

enum PairingError: LocalizedError {
    case badFile(String)
    case noIdentity(String)

    var errorDescription: String? {
        switch self {
        case let .badFile(message):
            return message
        case let .noIdentity(message):
            return message
        }
    }
}

/// 规范化之后的配对材料。只保留 RSD 真正要用的几项。
struct PairingRecord {
    let hostID: String
    let systemBUID: String
    /// DER 形式的 X.509 证书
    let hostCertificate: Data
    /// DER 形式的 RSA 私钥（PKCS#1）
    let hostPrivateKey: Data
    let deviceCertificate: Data?
    let rootCertificate: Data?
    /// keychain 清理时用的标签（兼容旧版本写入的残留条目）
    let keychainLabel: String
}

final class PairingStore {

    static let shared = PairingStore()

    private static let altIRKKey = "posterdrop.pairingHostAltIRK"
    private static let importedAtKey = "posterdrop.pairingImportedAt"
    private static let sourceNameKey = "posterdrop.pairingSourceName"

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 规范化后的配对文件路径（RSD 侧只认这一个）
    static var canonicalURL: URL {
        documentsDirectory.appendingPathComponent("pairing.plist")
    }

    // MARK: - 状态

    var hasPairing: Bool {
        FileManager.default.fileExists(atPath: Self.canonicalURL.path)
    }

    var pairingSize: Int {
        Self.fileSize(at: Self.canonicalURL)
    }

    var importedAt: Date? {
        UserDefaults.standard.object(forKey: Self.importedAtKey) as? Date
    }

    var sourceName: String {
        UserDefaults.standard.string(forKey: Self.sourceNameKey) ?? "未知来源"
    }

    var storedAltIRK: String {
        get { UserDefaults.standard.string(forKey: Self.altIRKKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.altIRKKey) }
    }

    /// 一句话描述，给诊断页用
    var summary: String {
        guard hasPairing else { return "未导入配对文件" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(pairingSize), countStyle: .file)
        if let date = importedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            return "\(size)，\(formatter.string(from: date)) 导入"
        }
        return size
    }

    // MARK: - 导入

    /// 读入并校验，成功才覆盖现有记录。
    /// 返回文件字节数。
    @discardableResult
    func adopt(url: URL) throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PairingError.badFile("读取失败：\(error.localizedDescription)")
        }
        guard !data.isEmpty else {
            throw PairingError.badFile("文件是空的")
        }

        // 先解析再落盘：坏文件不应该把好文件覆盖掉
        _ = try Self.parse(data)

        try data.write(to: Self.canonicalURL, options: .atomic)
        UserDefaults.standard.set(Date(), forKey: Self.importedAtKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: Self.sourceNameKey)

        // 重新导入意味着换了身份。现在 TLS 身份每次从内存里的 DER 现造，
        // 不依赖 keychain；但如果旧版本往 keychain 里写过证书/私钥，清掉更干净。
        Self.wipeIdentity(label: Self.keychainLabel)
        return data.count
    }

    func delete() {
        try? FileManager.default.removeItem(at: Self.canonicalURL)
        UserDefaults.standard.removeObject(forKey: Self.importedAtKey)
        UserDefaults.standard.removeObject(forKey: Self.sourceNameKey)
        storedAltIRK = ""
        Self.wipeIdentity(label: Self.keychainLabel)
    }

    // MARK: - 解析

    private static let keychainLabel = "posterdrop.rsd.identity"

    /// 读当前文件并解析。
    func record() throws -> PairingRecord {
        guard let data = try? Data(contentsOf: Self.canonicalURL) else {
            throw PairingError.badFile("没有配对文件")
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> PairingRecord {
        guard let dictionary = plistDictionary(from: data) else {
            throw PairingError.badFile("不是有效的 plist（文件开头：\(preview(data))）")
        }

        // 只认顶层字段是之前一直「提示缺少」的原因：不同工具导出的配对记录
        // 层级不一样（有的把材料塞在 RPPairing / PairingData 子字典里，有的
        // 整个再 base64 一层），顶层直接找就会一个都找不到。
        // 现在整棵树收一遍，再按「深度浅、键名更具体」挑。
        var found: [Found] = []
        var budget = 4_000
        collect(in: dictionary, context: [], depth: 0, into: &found, budget: &budget)

        let certificateKeys: Set<String> = [
            // lockdown / idevicepair
            "hostcertificate", "hostcert", "hostcertificatedata", "hostcertificatechain",
            // SideStore / jitterbugpair 的 rp_pairing_file.plist（snake_case）
            "public_key", "publickey",
            // 兜底：只有叫 certificate / cert 的字段
            "certificate", "cert"
        ]
        let keyKeys: Set<String> = [
            "hostprivatekey", "hostkey", "hostprivatekeydata",
            "private_key", "privatekey"
        ]
        let excludes = ["root", "device", "escrow"]

        guard let certificateValue = bestValue(in: found, keys: certificateKeys, excluding: excludes),
              let certificateBlob = blob(from: certificateValue) else {
            throw PairingError.badFile("缺少 HostCertificate（文件里的键：\(keySummary(found))）")
        }
        guard let keyValue = bestValue(in: found, keys: keyKeys, excluding: excludes),
              let keyBlob = blob(from: keyValue) else {
            // 密码保护的私钥会被这里拦下，但报「缺少」会让人以为是文件不对
            if let raw = bestValue(in: found, keys: keyKeys, excluding: excludes)
                .flatMap({ text(from: $0) }), raw.contains("ENCRYPTED") {
                throw PairingError.badFile("私钥有密码保护，请导出未加密的 PKCS#1 / PKCS#8")
            }
            throw PairingError.badFile("缺少 HostPrivateKey（文件里的键：\(keySummary(found))）")
        }

        func string(_ keys: Set<String>) -> String {
            guard let value = bestValue(in: found, keys: keys, excluding: []) else { return "" }
            return text(from: value) ?? ""
        }

        let hostID = string(["hostid", "hostidentifier", "identifier", "host_id"])
        let systemBUID = string(["systembuid", "systembuidstring", "system_buid"])

        // 证书必须是能解析的 DER，否则后面 SecCertificateCreateWithData 会静默返回 nil，
        // 报错会跑到 TLS 那一步，很难定位。
        guard SecCertificateCreateWithData(nil, certificateBlob as CFData) != nil else {
            throw PairingError.badFile(
                "HostCertificate 不是有效的 DER 证书（\(certificateBlob.count) 字节，开头 \(preview(certificateBlob))）"
            )
        }

        // alt_irk 在 SideStore 的格式里是 Data，lockdown 里是字符串，两种都收。
        let altIRKKeys: Set<String> = ["altirk", "alt_irk", "hostaltirk"]
        if let value = bestValue(in: found, keys: altIRKKeys, excluding: []),
           let irk = text(from: value) ?? (value as? Data)?.base64EncodedString(),
           !irk.isEmpty {
            PairingStore.shared.storedAltIRK = irk
        }

        return PairingRecord(
            hostID: hostID,
            systemBUID: systemBUID,
            hostCertificate: certificateBlob,
            // macOS 导出的 `-----BEGIN PRIVATE KEY-----` 是 PKCS#8，
            // SecKeyCreateWithData 只吃 PKCS#1，这里先剥一层。
            hostPrivateKey: pkcs1(from: keyBlob) ?? keyBlob,
            deviceCertificate: bestValue(in: found, keys: ["devicecertificate"], excluding: [])
                .flatMap { blob(from: $0) },
            rootCertificate: bestValue(in: found, keys: ["rootcertificate"], excluding: [])
                .flatMap { blob(from: $0) },
            keychainLabel: keychainLabel
        )
    }

    // MARK: - 解析辅助

    private struct Found {
        let key: String
        let value: Any
        let context: [String]
        let depth: Int
    }

    /// plist，以及「plist 再 base64 一层」的情况。
    private static func plistDictionary(from data: Data) -> [String: Any]? {
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dictionary = plist as? [String: Any] {
            return dictionary
        }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = text.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let decoded = Data(base64Encoded: compact),
              let plist = try? PropertyListSerialization.propertyList(from: decoded, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    /// 遍历整棵 plist 树收集键值。深度和节点数都设上限，异常文件不至于把导入拖死。
    private static func collect(
        in node: Any,
        context: [String],
        depth: Int,
        into found: inout [Found],
        budget: inout Int
    ) {
        guard budget > 0, depth <= 8 else { return }
        budget -= 1

        if let dictionary = node as? [String: Any] {
            for (key, value) in dictionary {
                found.append(Found(key: key, value: value, context: context, depth: depth))
                // 只往字典/数组里继续下钻，Data 和 String 是叶子
                collect(in: value, context: context + [key], depth: depth + 1, into: &found, budget: &budget)
            }
        } else if let array = node as? [Any] {
            for (index, value) in array.enumerated() {
                collect(in: value, context: context + ["[\(index)]"], depth: depth + 1, into: &found, budget: &budget)
            }
        }
    }

    /// 按「深度浅优先、键名更具体优先」挑一个候选。
    private static func bestValue(
        in found: [Found],
        keys: Set<String>,
        excluding: [String]
    ) -> Any? {
        let candidates = found.filter { keys.contains($0.key.lowercased()) }
        guard !candidates.isEmpty else { return nil }

        // RootCertificate / DeviceCertificate / RootPrivateKey 都在同一棵树里，
        // 名字像但不是我们要的那份，先排除掉（键名和它所在的层级都看）。
        let filtered = candidates.filter { item in
            let haystack = ([item.key] + item.context).joined(separator: ".").lowercased()
            return !excluding.contains { haystack.contains($0) }
        }
        let pool = filtered.isEmpty ? candidates : filtered
        return pool.sorted {
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            return $0.key.count > $1.key.count
        }.first?.value
    }

    private static func text(from value: Any) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let data = value as? Data, let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func blob(from value: Any) -> Data? {
        if let data = value as? Data, !data.isEmpty { return data }
        guard let text = text(from: value) else { return nil }
        return der(fromPEM: text)
    }

    /// 给报错用的键名清单。用户截图这一行就能看出文件到底是什么结构。
    private static func keySummary(_ found: [Found]) -> String {
        var seen = Set<String>()
        let keys = found
            .filter { $0.depth <= 1 }
            .map(\.key)
            .filter { seen.insert($0).inserted }
        guard !keys.isEmpty else { return "空" }
        let shown = keys.prefix(10).joined(separator: ", ")
        return keys.count > 10 ? "\(shown) …共 \(keys.count) 个" : shown
    }

    private static func preview(_ data: Data) -> String {
        let head = data.prefix(16)
        let ascii = head.map { byte -> Character in
            (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "."
        }
        return "\(String(ascii)) / \(head.map { String(format: "%02X", $0) }.joined(separator: " "))"
    }

    /// PKCS#8 → PKCS#1。
    ///
    /// RSAPrivateKey ::= SEQUENCE { INTEGER 0, INTEGER n, ... }
    /// PrivateKeyInfo ::= SEQUENCE { INTEGER 0, SEQUENCE { OID, NULL }, OCTET STRING }
    /// 两者第一个元素都是 INTEGER 0，看第二个元素就能分开：INTEGER 是 PKCS#1，SEQUENCE 是 PKCS#8。
    static func pkcs1(from der: Data) -> Data? {
        let bytes = [UInt8](der)
        guard let outer = tlv(bytes, 0), outer.tag == 0x30 else { return nil }
        guard let version = tlv(bytes, outer.start), version.tag == 0x02 else { return nil }
        guard let second = tlv(bytes, version.start + version.length) else { return nil }
        if second.tag == 0x02 { return nil }        // 已经是 PKCS#1
        guard second.tag == 0x30 else { return nil }
        guard let third = tlv(bytes, second.start + second.length), third.tag == 0x04 else { return nil }

        let inner = Data(bytes[third.start..<(third.start + third.length)])
        guard inner.count > 8, inner[inner.startIndex] == 0x30 else { return nil }
        return inner
    }

    /// 读一个 DER TLV，返回标签、内容起始下标、内容长度。
    private static func tlv(_ bytes: [UInt8], _ offset: Int) -> (tag: UInt8, start: Int, length: Int)? {
        guard offset >= 0, offset + 1 < bytes.count else { return nil }
        let tag = bytes[offset]
        var cursor = offset + 1
        var length = Int(bytes[cursor])
        cursor += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count >= 1, count <= 4, cursor + count <= bytes.count else { return nil }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[cursor])
                cursor += 1
            }
        }
        guard length >= 0, cursor + length <= bytes.count else { return nil }
        return (tag, cursor, length)
    }

    /// PEM / 裸 base64 → DER。配对文件里的证书有时是文本形式。
    static func der(fromPEM text: String) -> Data? {
        guard text.contains("-----BEGIN") else {
            // 不是 PEM，可能本身就是 base64 裸串（常常带换行，先去掉空白）
            let compact = text.filter { !$0.isWhitespace }
            return Data(base64Encoded: compact)
        }
        let body = text
            .components(separatedBy: .newlines)
            // PEM 头部偶尔夹着 `Proc-Type: 4,ENCRYPTED` 这类行，带冒号的一律不是 base64
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty && !$0.contains(":") }
            .joined()
        return Data(base64Encoded: body)
    }

    // MARK: - TLS 身份

    /// 把配对记录里的证书和私钥换成一个 TLS 层能用的身份。
    ///
    /// iOS 上没有 `SecIdentityCreateWithCertificate`（macOS 专有）；
    /// `sec_identity_create_with_certificates` 也只接受「已有的 identity + 追加证书链」，
    /// 不能拿私钥现造。所以只剩 keychain 这一条路：把证书和私钥分别写进去，
    /// 系统会按公钥把它们组合成一个 identity，再查 `kSecClassIdentity` 取出来。
    func secIdentity() throws -> sec_identity_t {
        let record = try self.record()
        return try Self.secIdentity(for: record)
    }

    static func secIdentity(for record: PairingRecord) throws -> sec_identity_t {
        let identity = try identityObject(for: record)
        guard let tls = sec_identity_create(identity) else {
            throw PairingError.noIdentity("无法把这个 identity 交给 TLS 层")
        }
        return tls
    }

    static func identityObject(for record: PairingRecord) throws -> SecIdentity {
        if let existing = matchIdentity(certificate: record.hostCertificate) {
            return existing
        }
        do {
            try installToKeychain(record)
        } catch {
            // 半套条目留在 keychain 里只会让下次更难查，直接清掉。
            Self.wipeIdentity(label: record.keychainLabel)
            throw error
        }
        if let installed = matchIdentity(certificate: record.hostCertificate) {
            return installed
        }
        throw PairingError.noIdentity("证书和私钥没能配对成 identity")
    }

    /// 按证书 DER 反查 identity。
    ///
    /// 不用 label 过滤：identity 的 label 取自证书，和私钥上的 label 不是一回事，
    /// 按 label 查经常一条都查不到，所以全量取回再逐个比对证书内容。
    private static func matchIdentity(certificate der: Data) -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let result else { return nil }

        let items: [Any] = (result as? [Any]) ?? [result]
        for item in items {
            guard CFGetTypeID(item as AnyObject) == SecIdentityGetTypeID() else { continue }
            let identity = unsafeBitCast(item as AnyObject, to: SecIdentity.self)
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate else { continue }
            if (SecCertificateCopyData(certificate) as Data) == der {
                return identity
            }
        }
        return nil
    }

    private static func installToKeychain(_ record: PairingRecord) throws {
        guard let certificate = SecCertificateCreateWithData(
            nil, record.hostCertificate as CFData
        ) else {
            throw PairingError.noIdentity("证书无法解析（需要 DER 形式的 X.509）")
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            record.hostPrivateKey as CFData,
            attributes as CFDictionary,
            &error
        ) else {
            let reason = (error?.takeRetainedValue()).map { String(describing: $0) } ?? "格式不支持"
            throw PairingError.noIdentity("私钥无法解析（需要 PKCS#1 DER）：\(reason)")
        }

        // 删除和添加要用两份查询：SecItemDelete 不接受带 kSecValueRef 的字典。
        Self.wipeIdentity(label: record.keychainLabel)
        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: record.keychainLabel
        ]
        let certStatus = SecItemAdd(certQuery as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw PairingError.noIdentity("证书写入 keychain 失败（\(certStatus)）")
        }

        // 不要再写 kSecAttrKeyType / kSecAttrKeyClass：SecKey 自己带着这些属性，
        // 重复指定会让 SecItemAdd 返回 errSecParam。kSecAttrIsPermanent 必须给，
        // 否则用 kSecValueRef 添加的私钥不会真正落进 keychain，也就凑不出 identity。
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: key,
            kSecAttrLabel as String: record.keychainLabel,
            kSecAttrApplicationTag as String: Data(record.keychainLabel.utf8),
            kSecAttrIsPermanent as String: true
        ]
        let keyStatus = SecItemAdd(keyQuery as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            throw PairingError.noIdentity("私钥写入 keychain 失败（\(keyStatus)）")
        }
    }

    static func wipeIdentity(label: String) {
        let tag = Data(label.utf8)
        let queries: [[String: Any]] = [
            [kSecClass as String: kSecClassIdentity,
             kSecAttrLabel as String: label],
            [kSecClass as String: kSecClassKey,
             kSecAttrApplicationTag as String: tag],
            [kSecClass as String: kSecClassKey,
             kSecAttrLabel as String: label],
            [kSecClass as String: kSecClassCertificate,
             kSecAttrLabel as String: label]
        ]
        for query in queries {
            SecItemDelete(query as CFDictionary)
        }
    }

    // MARK: - 发现

    /// 在 Documents（含两层子目录）里找可能的配对文件，方便用户直接从「文件」App 丢进来。
    func discoveredPairingFiles() -> [PairingCandidate] {
        let documents = Self.documentsDirectory
        var results: [PairingCandidate] = []

        let knownNames = ["pairing.plist", "airlift_pairing.plist", "aircard_pairing.plist"]
        let knownExtensions: Set<String> = ["mobiledevicepairing", "mobilepair", "plist"]

        func inspect(_ directory: URL, depth: Int) {
            guard depth <= 2 else { return }
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for item in contents {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    inspect(item, depth: depth + 1)
                    continue
                }
                let name = item.lastPathComponent
                let suffix = item.pathExtension.lowercased()
                guard knownNames.contains(name) || knownExtensions.contains(suffix) else { continue }
                // 规范文件本身不算候选
                if item.standardizedFileURL == Self.canonicalURL.standardizedFileURL { continue }
                results.append(PairingCandidate(
                    url: item,
                    size: values?.fileSize ?? 0,
                    source: depth == 0 ? "文档目录" : "子目录"
                ))
            }
        }

        inspect(documents, depth: 0)
        return results
    }

    // MARK: - 工具

    static func fileSize(at url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }
}
