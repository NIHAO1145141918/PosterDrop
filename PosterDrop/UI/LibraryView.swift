//
//  LibraryView.swift
//  PosterDrop
//
//  壁纸库：导入、预览、勾选、一键应用。
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LibraryView: View {

    @EnvironmentObject private var model: AppModel

    @State private var showImporter = false
    @State private var detailItem: WallpaperItem?
    @State private var isDropTargeted = false

    private var importTypes: [UTType] {
        var types: [UTType] = []
        if let custom = UTType("com.posterdrop.tendies") {
            types.append(custom)
        }
        if let custom = UTType("com.posterdrop.posterboard") {
            types.append(custom)
        }
        if let byExtension = UTType(filenameExtension: "tendies") {
            types.append(byExtension)
        }
        types.append(contentsOf: [.zip, .archive, .data])
        return types
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()

                ScrollView {
                    VStack(spacing: 14) {
                        headerCard

                        if let banner = model.banner {
                            BannerView(banner: banner) {
                                model.banner = nil
                            }
                        }

                        if model.isWorking {
                            WorkProgressCard(title: model.busyLabel, progress: model.progress)
                        }

                        if model.items.isEmpty {
                            emptyStateCard
                        } else {
                            gallerySection
                        }

                        stepsCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                    .readableColumn()
                }
            }
            .navigationTitle("壁纸库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        model.toggleSelectAll()
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .disabled(model.items.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                applyBar
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: importTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await model.importURLs(urls) }
                case .failure(let error):
                    model.banner = .error("选择文件失败：\(error.localizedDescription)")
                }
            }
            .sheet(item: $detailItem) { item in
                WallpaperDetailView(item: item)
                    .environmentObject(model)
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(
                            Theme.accent,
                            style: StrokeStyle(lineWidth: 2, dash: [9, 7])
                        )
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onDisappear {
                model.persistSelection()
            }
        }
    }

    // MARK: - 顶部

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("动态壁纸注入器")
                        .font(.title2.weight(.bold))
                    Text("导入 .tendies 壁纸包，直接写进 PosterBoard，锁屏里即可选用。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.accentGradient)
            }

            HStack(spacing: 8) {
                Button {
                    showImporter = true
                } label: {
                    Label("导入壁纸", systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

                Button {
                    Task { await model.importFromDocuments() }
                } label: {
                    Label("扫描文档", systemImage: "folder.badge.magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .frame(height: 42)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 6) {
                Image(systemName: model.directEnabled
                      ? "bolt.horizontal.circle.fill"
                      : (model.hasPairing ? "checkmark.seal.fill" : "exclamationmark.seal"))
                    .font(.caption)
                    .foregroundColor(model.directEnabled ? Theme.accent : (model.hasPairing ? .green : .orange))
                Text(model.directEnabled
                     ? "直连通道已启用，无需配对"
                     : (model.hasPairing ? "配对记录已就绪" : "还没有配对记录，应用前请先完成配对"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .card()
    }

    // MARK: - 列表

    private var gallerySection: some View {
        VStack(spacing: 10) {
            HStack {
                Text("已导入 \(model.items.count) 个壁纸包")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("已选 \(model.selectedCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.accent)
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: GalleryLayout.columns, spacing: 12) {
                ForEach($model.items) { $item in
                    WallpaperRow(
                        item: $item,
                        onOpen: { detailItem = item },
                        onApply: { Task { await model.apply(items: [item]) } },
                        onDelete: { model.delete(item) }
                    )
                }
            }
        }
    }

    // MARK: - 空状态

    private var emptyStateCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 74, height: 74)
                Image(systemName: "photo.stack")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
            }

            Text("还没有壁纸")
                .font(.headline)

            Text(DeviceLabel.isPad
                 ? "点「导入壁纸」从“文件”里选择 .tendies 包，\n或直接把文件从“文件”App 拖进本页。"
                 : "点「导入壁纸」从“文件”里选择 .tendies 包，\n或把文件拖进「文件 › 我的 iPhone › PosterDrop」。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .card()
    }

    // MARK: - 使用步骤

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("使用步骤")
                .font(.subheadline.weight(.semibold))

            stepRow(index: 1, title: "连接回环隧道", detail: "打开 LocalDevVPN / WireGuard，连接后地址为 10.7.0.1。")
            stepRow(index: 2, title: "准备配对记录", detail: "“配对”页导入配对文件，或在 iOS 27+ 直接本机配对。")
            stepRow(index: 3, title: "导入并应用", detail: "选中壁纸 → 应用所选 → 自动 respring，随后在锁屏墙纸里选用。")
        }
        .card()
    }

    private func stepRow(index: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.accent))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 底部应用栏

    private var applyBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            Button {
                Task { await model.applySelected() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text(model.selectedCount > 0 ? "应用所选（\(model.selectedCount)）" : "应用所选")
                    if model.isWorking {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(model.selectedCount == 0 || model.isWorking)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .readableColumn()
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - 拖放导入（iPad 多任务）

    /// iPad 分屏 / 台前调度下，直接把“文件”里的壁纸包拖进来。
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let collector = URLCollector()
        let group = DispatchGroup()
        var accepted = false

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    collector.append(url)
                } else if let url = item as? URL {
                    collector.append(url)
                }
            }
        }

        guard accepted else { return false }

        group.notify(queue: .main) {
            let urls = collector.urls
            guard !urls.isEmpty else {
                model.banner = .error("没有识别到可导入的文件，请拖入 .tendies 或 .zip 壁纸包。")
                return
            }
            Task { await model.importURLs(urls) }
        }
        return true
    }
}

/// 拖放回调在任意线程返回，这里串行收集 URL。
private final class URLCollector: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - 行

struct WallpaperRow: View {
    @Binding var item: WallpaperItem

    let onOpen: () -> Void
    let onApply: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                item.isSelected.toggle()
            } label: {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(item.isSelected ? Theme.accent : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)

            thumbnail

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                HStack(spacing: 6) {
                    KindBadge(kind: item.kind)
                    Text("\(item.descriptorCount) 个描述符")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Text(item.formattedSize)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 4)

            Button(action: onOpen) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(item.isSelected ? Theme.accent.opacity(0.35) : Color.primary.opacity(0.05), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button {
                onApply()
            } label: {
                Label("应用这张", systemImage: "sparkles")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.kindColor(item.kind).opacity(0.15))

            if let data = item.previewJPEG, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 46, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: 18, weight: .light))
                    .foregroundColor(Theme.kindColor(item.kind))
            }
        }
        .frame(width: 46, height: 62)
    }
}

// MARK: - 详情

struct WallpaperDetailView: View {

    let item: WallpaperItem

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()

                ScrollView {
                    VStack(spacing: 14) {
                        previewCard

                        VStack(alignment: .leading, spacing: 10) {
                            Text("包信息")
                                .font(.subheadline.weight(.semibold))
                            InfoRow(title: "类型", value: item.kind.title)
                            InfoRow(title: "目标扩展", value: item.kind.bundleID, monospaced: true)
                            InfoRow(title: "描述符数量", value: "\(item.descriptorCount)")
                            InfoRow(title: "文件大小", value: item.formattedSize)
                            InfoRow(title: "格式", value: item.isContainerArchive ? "整容器归档" : "描述符归档")
                            if item.detectedExtensions.count > 1 {
                                InfoRow(title: "涉及扩展", value: item.detectedExtensions.joined(separator: "\n"), monospaced: true)
                            }
                            if item.containsSQLiteStore {
                                InfoRow(title: "提示", value: "包含 SQLite 数据库，建议只取其中的 descriptor 目录")
                            }
                        }
                        .card()

                        VStack(spacing: 10) {
                            Button {
                                Task { await model.apply(items: [item]) }
                                dismiss()
                            } label: {
                                Label("应用这张壁纸", systemImage: "sparkles")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)

                            Button(role: .destructive) {
                                showDeleteConfirm = true
                            } label: {
                                Label("删除壁纸包", systemImage: "trash")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(16)
                    .readableColumn(640)
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("删除这个壁纸包？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    model.delete(item)
                    dismiss()
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("只删除 App 本地的包文件，已经注入到系统的壁纸不会被移除。")
            }
        }
    }

    private var previewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.kindColor(item.kind).opacity(0.12))

            if let data = item.previewJPEG, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: item.kind.symbolName)
                        .font(.system(size: 44, weight: .ultraLight))
                        .foregroundStyle(Theme.accentGradient)
                    Text("包里没有可预览的图片")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(height: 220)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 380)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
