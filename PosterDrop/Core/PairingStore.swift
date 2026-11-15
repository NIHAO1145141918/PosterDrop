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
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ), let dictionary = plist as? [String: Any] else {
            throw PairingError.badFile("不是有效的 plist")
        }

        // 两套命名都要认：
        //   lockdown / idevicepair : HostID, HostCertificate, HostPrivateKey ...
        //   RPPairing (iOS 17+)     : hostID, hostCertificate, hostPrivateKey ...
        func value(_ names: [String]) -> Any? {
            for name in names {
                if let found = dictionary[name] { return found }
            }
            return nil
        }

        func string(_ names: [String]) -> String? {
            if let text = value(names) as? String, !text.isEmpty { return text }
            if let data = value(names) as? Data,
               let text = String(data: data, encoding: .utf8), !text.isEmpty {
                return text
            }
            return nil
        }

        func blob(_ names: [String]) -> Data? {
            if let data = value(names) as? Data, !data.isEmpty { return data }
            if let text = value(names) as? String {
                return Self.der(fromPEM: text)
            }
            return nil
        }

        let hostID = string(["HostID", "hostID"]) ?? ""
        let systemBUID = string(["SystemBUID", "systemBUID"]) ?? ""

        guard let certificateBlob = blob(["HostCertificate", "hostCertificate"]) else {
            throw PairingError.badFile("缺少 HostCertificate")
        }
        guard let keyBlob = blob(["HostPrivateKey", "hostPrivateKey"]) else {
            throw PairingError.badFile("缺少 HostPrivateKey")
        }

        // 证书必须是能解析的 DER，否则后面 SecCertificateCreateWithData 会静默返回 nil，
        // 报错会跑到 TLS 那一步，很难定位。
        guard SecCertificateCreateWithData(nil, certificateBlob as CFData) != nil else {
            throw PairingError.badFile("HostCertificate 不是有效的 DER 证书")
        }

        let altIRK = string(["AltIRK", "altIRK", "hostAltIRK"]) ?? ""
        if !altIRK.isEmpty {
            PairingStore.shared.storedAltIRK = altIRK
        }

        return PairingRecord(
            hostID: hostID,
            systemBUID: systemBUID,
            hostCertificate: certificateBlob,
            hostPrivateKey: keyBlob,
            deviceCertificate: blob(["DeviceCertificate", "deviceCertificate"]),
            rootCertificate: blob(["RootCertificate", "rootCertificate"]),
            keychainLabel: keychainLabel
        )
    }

    /// PEM → DER。配对文件里的证书有时是文本形式。
    static func der(fromPEM text: String) -> Data? {
        guard text.contains("-----BEGIN") else {
            // 不是 PEM，可能本身就是 base64 裸串
            return Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let body = text
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        return Data(base64Encoded: body)
    }

    // MARK: - TLS 身份

    /// 把证书和私钥交给 TLS 层。
    ///
    /// iOS 上没有 `SecIdentityCreateWithCertificate`（macOS 专有），也没有
    /// 「内存里的证书 + 私钥 → SecIdentity」的公开 API；往 keychain 里分别塞
    /// 证书和私钥再查 `kSecClassIdentity`，合成结果同样不保证。
    /// 但 TLS 层真正要的并不是 SecIdentity，而是 `sec_identity_t`，它有直接的
    /// 构造入口 `sec_identity_create_with_certificates`（iOS 12+）：
    /// 传证书数组 + 私钥即可，完全不碰 keychain。
    func secIdentity() throws -> sec_identity_t {
        let record = try self.record()
        return try Self.secIdentity(for: record)
    }

    static func secIdentity(for record: PairingRecord) throws -> sec_identity_t {
        do {
            return try makeIdentity(record)
        } catch {
            // 解析失败多半是私钥格式不对（PEM 没转 DER / 不是 PKCS#1）。
            // 顺手清掉上次导入可能留在 keychain 里的半套东西，免得下次更乱。
            Self.wipeIdentity(label: record.keychainLabel)
            throw error
        }
    }

    private static func makeIdentity(_ record: PairingRecord) throws -> sec_identity_t {
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

        guard let identity = sec_identity_create_with_certificates(
            [certificate] as CFArray, key
        ) else {
            throw PairingError.noIdentity("证书与私钥匹配不上，无法组成 TLS 身份")
        }
        return identity
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
