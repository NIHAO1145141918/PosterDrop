//
//  AppModel.swift
//  PosterDrop
//
//  全局状态与业务编排：导入 → 解析 → 注入 → 刷新 → respring。
//
//  这一版只有一条底层：worse_query 的 App Group 沙箱扩展。没有配对、没有隧道、没有 VPN。
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

    // MARK: 容器

    @Published var containerPath: String = UserDefaults.standard.string(forKey: Keys.container) ?? "" {
        didSet { UserDefaults.standard.set(containerPath, forKey: Keys.container) }
    }

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

    /// worse_query 的跳板 App Group；留空表示读签名里的第一个可用项
    @Published var appGroupID: String {
        didSet { UserDefaults.standard.set(appGroupID, forKey: Keys.appGroup) }
    }
    /// 诊断页自检结果
    @Published var directStatus: String = ""

    // MARK: 缓存清理

    @Published var cacheTargets: [CacheTarget] = []
    @Published var isScanningCache = false
    @Published var isCleaningCache = false
    @Published var cacheScanDate: Date?
    @Published var cacheScanNote: String = ""
    @Published var cacheProgress: Double = 0
    @Published var cacheLastReport: CacheCleaner.Report?
    /// 是否做过「其他 App」的深度扫描：决定清理页显示汇总项还是入口按钮
    @Published var hasScannedOthers = false
    /// 清理了 PosterBoard 缓存之后，建议重启桌面重建缩略图
    @Published var cacheNeedsRespring = false


    private let store = WallpaperStore.shared
    private let installer = PosterBoardInstaller.shared

    init() {
        resetProtections = UserDefaults.standard.object(forKey: Keys.resetProtections) as? Bool ?? true
        dualInject = UserDefaults.standard.object(forKey: Keys.dualInject) as? Bool ?? true
        SandboxEscape.recoverPendingSwaps()

        autoStructVersion = UserDefaults.standard.object(forKey: Keys.autoVersion) as? Bool ?? true
        appGroupID = UserDefaults.standard.string(forKey: Keys.appGroup) ?? ""
        let storedVersion = UserDefaults.standard.object(forKey: Keys.manualVersion) as? Int ?? 61
        manualStructVersion = storedVersion

        items = store.loadLibrary()
    }

    // MARK: - 派生状态

    var selectedItems: [WallpaperItem] {
        return items.filter { $0.isSelected }
    }

    var selectedCount: Int {
        return selectedItems.count
    }

    var effectiveStructVersion: Int {
        if autoStructVersion {
            let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            return major >= 17 ? 61 : 59
        }
        return manualStructVersion
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
        guard !isWorking else {
            banner = .info("正在处理上一个任务，稍等一下。")
            return
        }

        // 同一个文件被重复投递（拖放 + 选择器）时只处理一次
        var unique: [URL] = []
        var seen = Set<String>()
        for url in urls where seen.insert(url.standardizedFileURL.path).inserted {
            unique.append(url)
        }

        isWorking = true
        progress = 0
        busyLabel = "正在导入壁纸…"
        banner = nil

        var imported: [WallpaperItem] = []
        var failures: [String] = []

        LogBus.shared.append("— 开始导入 \(unique.count) 个文件 —")

        for (index, url) in unique.enumerated() {
            busyLabel = "正在解析 \(url.lastPathComponent)…"
            do {
                let item = try await store.importWallpaper(from: url) { line in
                    LogBus.shared.append(line)
                }
                imported.append(item)
            } catch {
                let reason = error.localizedDescription
                failures.append("\(url.lastPathComponent)：\(reason)")
                LogBus.shared.append("❌ \(url.lastPathComponent)：\(reason)")
            }
            progress = Double(index + 1) / Double(unique.count)
        }

        for item in imported {
            items.removeAll { $0.fileName == item.fileName }
            items.insert(item, at: 0)
        }
        persistLibrary()

        isWorking = false
        progress = 0
        busyLabel = ""

        if imported.isEmpty {
            banner = .error(failures.isEmpty ? "没有导入任何壁纸。" : failures.joined(separator: "\n"))
        } else if failures.isEmpty {
            banner = .success("已导入 \(imported.count) 个壁纸包。")
        } else {
            banner = .error("已导入 \(imported.count) 个，\(failures.count) 个失败：\n" + failures.joined(separator: "\n"))
        }
    }

    /// 扫描“文件”App 里放进 PosterDrop 文档目录的壁纸
    func importFromDocuments() async {
        guard !isWorking else {
            banner = .info("正在处理上一个任务，稍等一下。")
            return
        }

        let scan = store.scanDocuments()
        LogBus.shared.append("— 扫描文档目录：文件 \(scan.scannedFiles) 个，文件夹 \(scan.scannedFolders) 个，命中 \(scan.candidates.count) 个 —")

        let existingNames = Set(items.map { $0.fileName })
        let fresh = scan.candidates.filter { !existingNames.contains($0.lastPathComponent) }

        guard !fresh.isEmpty else {
            banner = .info("文档目录里没有新的壁纸包。\n已检查 \(scan.scannedFiles) 个文件、\(scan.scannedFolders) 个文件夹（「文件 › 我的 iPhone / iPad › PosterDrop」下都可以）。")
            return
        }
        await importURLs(fresh)
    }

    func handleIncoming(url: URL) {
        let fileExtension = url.pathExtension.lowercased()
        if ["mobiledevicepairing", "mobilepair"].contains(fileExtension) {
            banner = .info("这一版不再需要配对文件：壁纸直接通过 worse_query 沙箱扩展写入。")
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
        guard !isWorking, !isCleaningCache else { return }
        guard !targets.isEmpty else {
            banner = .error("请先勾选要应用的壁纸。")
            return
        }

        persistLibrary()

        isWorking = true
        progress = 0
        lastReport = nil
        LogBus.shared.clear()
        LogBus.shared.append("==== PosterDrop 开始注入 ====")
        LogBus.shared.append("底层：worse_query 沙箱扩展（无需配对 / 无需 VPN）")
        let startedAt = Date()
        // 状态检测放到后台，不挡注入；当前通道不走 VPN，只把真实情况写进日志
        Task.detached(priority: .utility) {
            let report = VPNStatus.cached()
            LogBus.shared.append("· VPN 检测：\(report.logLine)")
        }

        do {
            busyLabel = "正在定位 PosterBoard 容器…"
            let channel = try await locateDirectChannel()
            containerPath = channel.containerPath
            UserDefaults.standard.set(channel.containerPath, forKey: Keys.container)

            LogBus.shared.append("通道：\(channel.label)")
            LogBus.shared.append("PosterBoard 容器：\(channel.containerPath)")

            let options = InstallOptions(
                structVersion: effectiveStructVersion,
                resetProtections: resetProtections,
                dualInject: dualInject
            )

            busyLabel = "正在注入 \(targets.count) 张壁纸…"
            let report = try await performInstall(
                targets: targets,
                container: channel.containerPath,
                channel: channel,
                options: options
            )
            let cost = Date().timeIntervalSince(startedAt)
            LogBus.shared.append(String(format: "⏱ 注入总耗时 %.1f 秒", cost))
            finishInstall(report)
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
        busyLabel = "正在定位 PosterBoard 容器…"
        defer {
            isWorking = false
            busyLabel = ""
        }

        do {
            let channel = try await locateDirectChannel()
            containerPath = channel.containerPath
            UserDefaults.standard.set(channel.containerPath, forKey: Keys.container)
            banner = .success("已定位 PosterBoard 容器。")
        } catch {
            banner = .error("定位失败：\(error.localizedDescription)")
        }
    }

    func refreshCacheOnly() async {
        isWorking = true
        busyLabel = "正在刷新壁纸缓存…"
        defer {
            isWorking = false
            busyLabel = ""
        }

        do {
            let channel = try await locateDirectChannel()
            if containerPath.isEmpty { containerPath = channel.containerPath }

            let ok = await installer.refreshCache(
                containerPath: channel.containerPath,
                channel: channel,
                log: { line in LogBus.shared.append(line) }
            )
            if ok {
                banner = .success("缓存刷新标记已写入，正在重启桌面…")
                triggerAutoRespring()
            } else {
                banner = .error("缓存刷新失败，请查看日志。")
            }
        } catch {
            banner = .error(error.localizedDescription)
        }
    }

    // MARK: - 缓存清理

    var cacheTotalBytes: Int64 {
        cacheTargets.reduce(0) { $0 + $1.bytes }
    }

    var selectedCacheTargets: [CacheTarget] {
        cacheTargets.filter { $0.isSelected && $0.isCleanable }
    }

    var selectedCacheBytes: Int64 {
        selectedCacheTargets.reduce(0) { $0 + $1.bytes }
    }

    var canCleanCache: Bool {
        !selectedCacheTargets.isEmpty && !isCleaningCache && !isScanningCache && !isWorking
    }

    /// 统计缓存。`includeOthers` 为 true 时才会去扫其他 App（慢，几秒）。
    func scanCache(includeOthers: Bool = false) async {
        guard !isWorking, !isCleaningCache, !isScanningCache else { return }

        isScanningCache = true
        defer { isScanningCache = false }
        cacheProgress = 0
        cacheScanNote = includeOthers ? "正在统计所有 App 的缓存…" : "正在统计缓存大小…"

        // 这里不主动定位容器：清理页应该秒开。没有路径时只统计本 App 的部分，
        // 页面上会提示先去「诊断」探测一次。
        let container = containerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = resolvedAppGroup
        let target = container
        let previousSelection = Set(cacheTargets.filter { $0.isSelected }.map { $0.id })
        let previousOther = cacheTargets.first { $0.scope == .other }

        LogBus.shared.append("— 统计缓存 —")
        let started = Date()

        var scanned = await Task.detached(priority: .userInitiated) { () -> [CacheTarget] in
            CacheCleaner.shared.scan(
                container: target.isEmpty ? nil : target,
                group: group,
                includeOthers: includeOthers,
                log: { line in LogBus.shared.append(line) }
            )
        }.value

        // 这次没做深度扫描时，把上次那一项保留下来，别让它凭空消失
        if !includeOthers, let previousOther {
            scanned.append(previousOther)
        }

        // 重扫后保住用户之前的勾选
        for index in scanned.indices where previousSelection.contains(scanned[index].id) {
            if scanned[index].isCleanable {
                scanned[index].isSelected = true
            }
        }

        cacheTargets = scanned
        cacheScanDate = Date()
        cacheProgress = 0
        cacheScanNote = ""
        isScanningCache = false
        if includeOthers { hasScannedOthers = true }

        LogBus.shared.append(String(
            format: "   共 %@，用时 %.1f 秒",
            CacheFormat.size(cacheTotalBytes),
            Date().timeIntervalSince(started)
        ))
    }

    func toggleCacheTarget(_ id: String) {
        guard let index = cacheTargets.firstIndex(where: { $0.id == id }) else { return }
        guard cacheTargets[index].isCleanable else { return }
        cacheTargets[index].isSelected.toggle()
    }

    func toggleAllCache(in scope: CacheTarget.Scope) {
        let indexes = cacheTargets.indices.filter {
            cacheTargets[$0].scope == scope && cacheTargets[$0].isCleanable
        }
        guard !indexes.isEmpty else { return }
        let allOn = indexes.allSatisfy { cacheTargets[$0].isSelected }
        for index in indexes {
            cacheTargets[index].isSelected = !allOn
        }
    }

    func cleanCache() async {
        guard !isWorking, !isCleaningCache, !isScanningCache else { return }

        let picked = selectedCacheTargets
        guard !picked.isEmpty else {
            banner = .info("没有勾选可清理的项目。")
            return
        }

        isCleaningCache = true
        defer { isCleaningCache = false }
        cacheProgress = 0
        let group = resolvedAppGroup
        let planned = selectedCacheBytes

        LogBus.shared.append("— 清理缓存：\(picked.count) 项，共 \(CacheFormat.size(planned)) —")

        let report = await Task.detached(priority: .userInitiated) { () -> CacheCleaner.Report in
            CacheCleaner.shared.clean(picked, group: group) { value in
                Task { @MainActor in
                    self.cacheProgress = value
                }
            }
        }.value

        // 清干净的项直接归零，不必再扫一遍
        for index in cacheTargets.indices where report.cleanedIDs.contains(cacheTargets[index].id) {
            cacheTargets[index].bytes = 0
            cacheTargets[index].files = 0
            cacheTargets[index].state = .empty
            cacheTargets[index].isSelected = false
        }

        cacheProgress = 0
        isCleaningCache = false
        cacheLastReport = report
        cacheNeedsRespring = picked.contains { $0.scope == .posterBoard && report.cleanedIDs.contains($0.id) }

        LogBus.shared.append("✅ \(report.text)，用时 \(String(format: "%.1f", report.elapsed)) 秒")
        for failure in report.failures.prefix(6) {
            LogBus.shared.append("   · \(failure)")
        }

        if report.failures.isEmpty {
            banner = .success("\(report.text)。壁纸本体没有被删；如果桌面显示异常，去「诊断」页点一次「刷新缓存」。")
        } else {
            banner = .error(report.text + "\n" + report.failures.prefix(2).joined(separator: "\n"))
        }
    }

    // MARK: - 直连通道

    /// 解析要用的 App Group：优先用户填的，其次签名里的第一个可用项。
    var resolvedAppGroup: String? {
        SandboxEscape.usableGroup(preferred: appGroupID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 申请沙箱扩展并定位 PosterBoard 容器（阻塞操作，放到后台线程）
    private func locateDirectChannel() async throws -> DirectChannel {
        guard let group = resolvedAppGroup else {
            throw SandboxEscape.Failure(
                code: -1,
                message: "签名里没有可用的 App Group。worse_query 必须依赖 App Groups 权限，请用带 App Groups 的方式重签（轻松签 / ESign / SideStore 勾选 App Groups）。"
            )
        }
        let manual = containerPath
        return try await Task.detached(priority: .userInitiated) {
            try DirectChannel.locate(group: group, manualContainer: manual, log: { line in
                LogBus.shared.append(line)
            })
        }.value
    }

    /// 支持区间：iOS 26.0 – 27.2。
    /// Apple 在 iOS 18 之后直接跳到 iOS 26（年份命名），不存在 19–25 这几个版本号。
    nonisolated static var osSupport: (ok: Bool, text: String) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let text = "\(v.majorVersion).\(v.minorVersion)"
        if v.majorVersion < 26 { return (false, text) }
        if v.majorVersion > 27 { return (false, text) }
        if v.majorVersion == 27, v.minorVersion > 2 { return (false, text) }
        return (true, text)
    }

    /// 诊断页自检：只验证能不能拿到扩展、能不能看到 PosterBoard 容器
    func probeDirectChannel() async {
        let support = Self.osSupport
        guard support.ok else {
            let message = """
            ❌ 当前系统 iOS \(support.text) 不在支持范围。
            本项目只支持 iOS 26.0 – 27.2：Apple 从 iOS 18 直接跳到 iOS 26，不存在 iOS 19–25；低于 26.0 的系统没有这条签发缺陷。
            """
            directStatus = message
            LogBus.shared.append("— 直连通道自检 —")
            LogBus.shared.append(message)
            return
        }

        directStatus = "正在申请沙箱扩展…"
        let preferred = appGroupID.trimmingCharacters(in: .whitespacesAndNewlines)
        let manual = containerPath

        let result = await Task.detached(priority: .userInitiated) {
            DirectChannel.probe(group: preferred.isEmpty ? nil : preferred, manualContainer: manual)
        }.value

        directStatus = result.report
        if let path = result.containerPath, !path.isEmpty {
            containerPath = path
        }

        LogBus.shared.append("— 直连通道自检 —")
        for line in result.report.split(separator: "\n") {
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
}
