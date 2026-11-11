//
//  AppModel.swift
//  PosterDrop
//
//  全局状态与业务编排：导入 → 解析 → 注入 → 刷新 → respring。
//

import Foundation
import UIKit
import Combine

struct Banner: Identifiable, Equatable {
    enum Kind: Equatable {
        case success
        case error
        case info
    }

    let id = UUID()
    let kind: Kind
    let message: String

    static func success(_ message: String) -> Banner { Banner(kind: .success, message: message) }
    static func error(_ message: String) -> Banner { Banner(kind: .error, message: message) }
    static func info(_ message: String) -> Banner { Banner(kind: .info, message: message) }
}

@MainActor
final class AppModel: ObservableObject {

    private enum Keys {
        static let container = "posterdrop.containerPath"
        static let resetProtections = "posterdrop.resetProtections"
        static let dualInject = "posterdrop.dualInject"
        static let manualVersion = "posterdrop.manualStructVersion"
        static let autoVersion = "posterdrop.autoStructVersion"
        static let direct = "posterdrop.directChannel"
        static let appGroup = "posterdrop.appGroupID"
    }

    // MARK: 壁纸库

    @Published var items: [WallpaperItem] = []
    @Published var banner: Banner?

    // MARK: 任务状态

    @Published var isWorking = false
    @Published var busyLabel = ""
    @Published var progress: Double = 0
    @Published var lastReport: InstallReport?
    @Published var isRespringing = false

    // MARK: 配对 / 容器

    @Published var containerPath: String = UserDefaults.standard.string(forKey: Keys.container) ?? "" {
        didSet { UserDefaults.standard.set(containerPath, forKey: Keys.container) }
    }
    @Published var pairingSize: Int = 0

    // MARK: 选项

    @Published var resetProtections: Bool {
        didSet { UserDefaults.standard.set(resetProtections, forKey: Keys.resetProtections) }
    }
    @Published var dualInject: Bool {
        didSet { UserDefaults.standard.set(dualInject, forKey: Keys.dualInject) }
    }
    @Published var autoStructVersion: Bool {
        didSet { UserDefaults.standard.set(autoStructVersion, forKey: Keys.autoVersion) }
    }
    @Published var manualStructVersion: Int {
        didSet { UserDefaults.standard.set(manualStructVersion, forKey: Keys.manualVersion) }
    }

    /// 直连通道（沙箱扩展）：不需要配对，但依赖系统签发缺陷
    @Published var directEnabled: Bool {
        didSet { UserDefaults.standard.set(directEnabled, forKey: Keys.direct) }
    }
    /// 直连通道的跳板 App Group；留空表示用自身容器
    @Published var appGroupID: String {
        didSet { UserDefaults.standard.set(appGroupID, forKey: Keys.appGroup) }
    }
    /// 诊断页自检结果
    @Published var directStatus: String = ""

    private let store = WallpaperStore.shared
    private let pairingStore = PairingStore.shared
    private let installer = PosterBoardInstaller.shared

    init() {
        resetProtections = UserDefaults.standard.object(forKey: Keys.resetProtections) as? Bool ?? true
        dualInject = UserDefaults.standard.object(forKey: Keys.dualInject) as? Bool ?? true
        SandboxEscape.recoverPendingSwaps()

        autoStructVersion = UserDefaults.standard.object(forKey: Keys.autoVersion) as? Bool ?? true
        directEnabled = UserDefaults.standard.object(forKey: Keys.direct) as? Bool ?? false
        appGroupID = UserDefaults.standard.string(forKey: Keys.appGroup) ?? ""
        let storedVersion = UserDefaults.standard.object(forKey: Keys.manualVersion) as? Int ?? 61
        manualStructVersion = storedVersion

        items = store.loadLibrary()
        refreshPairingState()
    }

    // MARK: - 派生状态

    var selectedItems: [WallpaperItem] {
        return items.filter { $0.isSelected }
    }

    var selectedCount: Int {
        return selectedItems.count
    }

    var hasPairing: Bool {
        return pairingSize > 0
    }

    var effectiveStructVersion: Int {
        if autoStructVersion {
            let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            return major >= 17 ? 61 : 59
        }
        return manualStructVersion
    }

    var pairingPath: String {
        return pairingStore.activePath
    }

    func refreshPairingState() {
        pairingSize = pairingStore.activePairingSize
        if pairingSize == 0 {
            // 尝试自动采纳 Documents 里已有的配对文件
            if let candidate = pairingStore.discoveredPairingFiles().first,
               (try? pairingStore.adopt(url: candidate.url)) != nil {
                pairingSize = pairingStore.activePairingSize
            }
        }
    }

    // MARK: - 壁纸库操作

    func reloadLibrary() {
        items = store.loadLibrary()
    }

    func persistLibrary() {
        store.saveLibrary(items)
    }

    /// 保存勾选状态（用户逐个勾选时不会立即写盘，切走页面时补写）
    func persistSelection() {
        store.saveLibrary(items)
    }

    func toggleSelectAll() {
        let allSelected = !items.isEmpty && items.allSatisfy { $0.isSelected }
        for index in items.indices {
            items[index].isSelected = !allSelected
        }
        persistLibrary()
    }

    func delete(_ item: WallpaperItem) {
        store.delete(item)
        items.removeAll { $0.id == item.id }
        persistLibrary()
        banner = .info("已删除「\(item.name)」。已注入到系统的壁纸不会自动移除。")
    }

    func importURLs(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }

        isWorking = true
        progress = 0
        busyLabel = "正在导入壁纸…"

        var imported: [WallpaperItem] = []
        var failures: [String] = []

        for (index, url) in urls.enumerated() {
            busyLabel = "正在解析 \(url.lastPathComponent)…"
            do {
                let item = try await store.importWallpaper(from: url)
                imported.append(item)
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
            progress = Double(index + 1) / Double(urls.count)
        }

        for item in imported {
            items.removeAll { $0.fileName == item.fileName }
            items.insert(item, at: 0)
        }
        persistLibrary()

        isWorking = false
        progress = 0
        busyLabel = ""

        if !imported.isEmpty {
            banner = .success("已导入 \(imported.count) 个壁纸包。")
        }
        if !failures.isEmpty {
            banner = .error(failures.joined(separator: "\n"))
        }
    }

    /// 扫描“文件”App 里放进 PosterDrop 文档目录的壁纸
    func importFromDocuments() async {
        let found = store.discoverInDocuments()
        let existingNames = Set(items.map { $0.fileName })
        let fresh = found.filter { !existingNames.contains($0.lastPathComponent) }

        guard !fresh.isEmpty else {
            banner = .info("文档目录里没有新的 .tendies / .zip 壁纸包。")
            return
        }
        await importURLs(fresh)
    }

    func handleIncoming(url: URL) {
        let fileExtension = url.pathExtension.lowercased()
        if ["mobiledevicepairing", "mobilepair"].contains(fileExtension)
            || (fileExtension == "plist" && url.lastPathComponent.lowercased().contains("pair")) {
            do {
                let size = try pairingStore.adopt(url: url)
                refreshPairingState()
                banner = .success("已导入配对记录（\(size) 字节）。")
            } catch {
                banner = .error(error.localizedDescription)
            }
            return
        }

        Task {
            await importURLs([url])
        }
    }

    // MARK: - 应用壁纸

    func applySelected() async {
        await apply(items: selectedItems)
    }

    func apply(items targets: [WallpaperItem]) async {
        guard !isWorking else { return }
        guard !targets.isEmpty else {
            banner = .error("请先勾选要应用的壁纸。")
            return
        }

        refreshPairingState()

        let useDirect = directEnabled
        let pairing = pairingPath

        if !useDirect {
            guard hasPairing else {
                banner = .error("还没有可用的配对记录。请先到「配对」页导入配对文件，或在 iOS 27+ 使用本机配对；也可以在「诊断 › 直连通道」里改用直连模式。")
                return
            }
            guard FileManager.default.fileExists(atPath: pairing) else {
                banner = .error("配对文件不存在，请重新导入。")
                return
            }
        }

        persistLibrary()

        isWorking = true
        progress = 0
        lastReport = nil
        LogBus.shared.clear()
        LogBus.shared.append("==== PosterDrop 开始注入 ====")
        LogBus.shared.append(useDirect ? "通道：直连（沙箱扩展）" : "通道：配对隧道 \(pairing)")

        do {
            var container = containerPath.trimmingCharacters(in: .whitespacesAndNewlines)
            var detectedFresh = false
            let channel: FileChannel

            if useDirect {
                busyLabel = "正在申请沙箱扩展…"
                let direct = try await locateDirectChannel()
                channel = direct
                container = direct.containerPath
                containerPath = container
                UserDefaults.standard.set(container, forKey: Keys.container)
                LogBus.shared.append("通道：\(direct.label)")
                LogBus.shared.append("PosterBoard 容器：\(container)")
                detectedFresh = true
            } else {
                channel = TunnelChannel(pairingPath: pairing)
                if container.isEmpty {
                    busyLabel = "正在探测 PosterBoard 容器…"
                    container = try await installer.detectContainer(pairingPath: pairing)
                    containerPath = container
                    UserDefaults.standard.set(container, forKey: Keys.container)
                    LogBus.shared.append("PosterBoard 容器：\(container)")
                    detectedFresh = true
                }
            }

            let options = InstallOptions(
                structVersion: effectiveStructVersion,
                resetProtections: resetProtections,
                dualInject: dualInject
            )

            busyLabel = "正在注入 \(targets.count) 张壁纸…"

            do {
                let report = try await performInstall(
                    targets: targets,
                    container: container,
                    channel: channel,
                    options: options
                )
                finishInstall(report)
            } catch {
                // 缓存的容器路径可能已经失效（重装 App / 系统更新），重新探测后重试一次
                guard !detectedFresh, !useDirect else { throw error }

                LogBus.shared.append("⚠️ 首次注入失败，重新探测容器后重试：\(error.localizedDescription)")
                busyLabel = "容器路径可能已失效，正在重新探测…"

                let freshContainer = try await installer.detectContainer(pairingPath: pairing)
                containerPath = freshContainer
                UserDefaults.standard.set(freshContainer, forKey: Keys.container)
                LogBus.shared.append("新的容器路径：\(freshContainer)")

                busyLabel = "正在重试注入…"
                let report = try await performInstall(
                    targets: targets,
                    container: freshContainer,
                    channel: channel,
                    options: options
                )
                finishInstall(report)
            }
        } catch {
            isWorking = false
            busyLabel = ""
            banner = .error(error.localizedDescription)
            LogBus.shared.append("❌ \(error.localizedDescription)")
        }
    }

    private func performInstall(
        targets: [WallpaperItem],
        container: String,
        channel: FileChannel,
        options: InstallOptions
    ) async throws -> InstallReport {
        return try await installer.install(
            items: targets,
            containerPath: container,
            channel: channel,
            options: options,
            log: { line in
                LogBus.shared.append(line)
            },
            progress: { value in
                Task { @MainActor in
                    self.progress = value
                }
            }
        )
    }

    private func finishInstall(_ report: InstallReport) {
        lastReport = report
        isWorking = false
        busyLabel = ""

        if report.failedItems.isEmpty {
            banner = .success("已注入 \(report.injectedDescriptors) 个壁纸描述符，正在重启桌面以生效…")
        } else {
            banner = .error("部分壁纸失败：\n" + report.failedItems.joined(separator: "\n"))
        }

        triggerAutoRespring()
    }

    // MARK: - 容器 / 缓存

    func detectContainer() async {
        isWorking = true
        busyLabel = "正在探测 PosterBoard 容器…"
        defer {
            isWorking = false
            busyLabel = ""
        }

        if directEnabled {
            do {
                let channel = try await locateDirectChannel()
                containerPath = channel.containerPath
                UserDefaults.standard.set(channel.containerPath, forKey: Keys.container)
                banner = .success("已通过直连通道定位 PosterBoard 容器。")
            } catch {
                banner = .error("直连探测失败：\(error.localizedDescription)")
            }
            return
        }

        refreshPairingState()
        guard hasPairing else {
            banner = .error("请先导入配对记录，或改用直连通道。")
            return
        }

        do {
            let container = try await installer.detectContainer(pairingPath: pairingPath)
            containerPath = container
            UserDefaults.standard.set(container, forKey: Keys.container)
            banner = .success("已定位 PosterBoard 容器。")
        } catch {
            banner = .error("探测失败：\(error.localizedDescription)\n请确认 LocalDevVPN 已连接、设备已解锁。")
        }
    }

    func refreshCacheOnly() async {
        isWorking = true
        busyLabel = "正在刷新壁纸缓存…"
        defer {
            isWorking = false
            busyLabel = ""
        }

        let channel: FileChannel
        var container = containerPath

        if directEnabled {
            do {
                let direct = try await locateDirectChannel()
                channel = direct
                if container.isEmpty { container = direct.containerPath }
            } catch {
                banner = .error("直连通道不可用：\(error.localizedDescription)")
                return
            }
        } else {
            refreshPairingState()
            guard hasPairing else {
                banner = .error("请先导入配对记录，或改用直连通道。")
                return
            }
            channel = TunnelChannel(pairingPath: pairingPath)
        }

        if container.isEmpty {
            banner = .error("请先在“诊断”里探测一次容器路径。")
            return
        }

        let ok = await installer.refreshCache(
            containerPath: container,
            channel: channel,
            log: { line in LogBus.shared.append(line) }
        )
        if ok {
            banner = .success("缓存刷新标记已写入，正在重启桌面…")
            triggerAutoRespring()
        } else {
            banner = .error("缓存刷新失败，请查看日志。")
        }
    }

    // MARK: - 直连通道

    /// 解析要用的 App Group：优先用户填的，其次签名里的第一个可用项。
    /// 这条通道必须有 App Groups 权限，否则 containermanagerd 不会返回结果。
    var resolvedAppGroup: String? {
        SandboxEscape.usableGroup(preferred: appGroupID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 申请沙箱扩展并定位 PosterBoard 容器（阻塞操作，放到后台线程）
    private func locateDirectChannel() async throws -> DirectChannel {
        guard let group = resolvedAppGroup else {
            throw SandboxEscape.Failure(code: -1, message: "签名里没有可用的 App Group，请用带 App Groups 的方式重签")
        }
        let manual = containerPath
        return try await Task.detached(priority: .userInitiated) {
            try DirectChannel.locate(group: group, manualContainer: manual, log: { line in
                LogBus.shared.append(line)
            })
        }.value
    }

    /// 诊断页自检：只验证能不能拿到扩展、能不能看到 PosterBoard 容器
    func probeDirectChannel() async {
        directStatus = "正在申请沙箱扩展…"
        let preferred = appGroupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let manual = containerPath

        let report = await Task.detached(priority: .userInitiated) {
            DirectChannel.probe(group: preferred.isEmpty ? nil : preferred, manualContainer: manual)
        }.value

        directStatus = report
        LogBus.shared.append("— 直连通道自检 —")
        for line in report.split(separator: "\n") {
            LogBus.shared.append(String(line))
        }
    }

    // MARK: - Respring

    func triggerAutoRespring() {
        isRespringing = true
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            Respring.triggerNeoSpring()
            scheduleOverlayReset()
        }
    }

    func respringManually() {
        isRespringing = true
        Respring.triggerNeoSpring()
        scheduleOverlayReset()
    }

    /// respring 没生效时（App 仍然活着），十几秒后自动撤掉遮罩，避免卡在黑屏。
    private func scheduleOverlayReset() {
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self.isRespringing = false
        }
    }

    func respringViaDiagnostics() async {
        refreshPairingState()
        guard hasPairing else {
            banner = .error("请先导入配对记录。")
            return
        }
        let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
            Airlift.respringDevice(pairingPath: PairingStore.shared.activePath)
        }.value

        if ok {
            banner = .success("已通过诊断中继发送重启桌面指令。")
        } else {
            banner = .error("诊断中继重启失败，请改用 NeoSpring。")
        }
    }

    // MARK: - 配对

    func importPairing(from url: URL) {
        do {
            let size = try pairingStore.adopt(url: url)
            refreshPairingState()
            banner = .success("已导入配对记录（\(size) 字节）。")
        } catch {
            banner = .error(error.localizedDescription)
        }
    }

    func deletePairing() {
        pairingStore.deleteCredentials()
        refreshPairingState()
        banner = .info("已删除本机保存的配对凭据。")
    }
}
