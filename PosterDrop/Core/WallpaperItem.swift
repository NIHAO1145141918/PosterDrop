//
//  WallpaperItem.swift
//  PosterDrop
//
//  壁纸包的数据模型。.tendies 本质是一个 zip：
//    container/Library/Application Support/PRBPosterExtensionDataStore/<ver>/Extensions/<bundleID>/descriptors/<desc>/
//  或者只包含若干 descriptor 目录。
//

import Foundation

enum PosterKind: String, Codable, CaseIterable {
    case collections
    case mercury
    case photos
    case kaleidoscope
    case unity
    case generic

    /// 注入目标扩展（PosterBoard 的 Extensions 目录名）
    var bundleID: String {
        switch self {
        case .collections:
            return "com.apple.WallpaperKit.CollectionsPoster"
        case .mercury:
            return "com.apple.MercuryPoster"
        case .photos:
            return "com.apple.PhotosUIPrivate.PhotosPosterProvider"
        case .kaleidoscope:
            return "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster"
        case .unity:
            return "com.apple.Posters.UnityPosterApp.UnityPosterExtension"
        case .generic:
            return "com.apple.WallpaperKit.CollectionsPoster"
        }
    }

    /// iOS 18+ 还有一套「.Posters.<Name>App」新容器，需要双写才能稳定出现。
    var modernBundleID: String? {
        switch self {
        case .collections:
            return "com.apple.Posters.CollectionsPosterApp"
        case .mercury:
            return "com.apple.Posters.MercuryPosterApp"
        default:
            return nil
        }
    }

    var title: String {
        switch self {
        case .collections:
            return "集合壁纸"
        case .mercury:
            return "动态壁纸"
        case .photos:
            return "照片壁纸"
        case .kaleidoscope:
            return "万花筒"
        case .unity:
            return "Unity 壁纸"
        case .generic:
            return "通用壁纸"
        }
    }

    var symbolName: String {
        switch self {
        case .collections:
            return "square.stack.3d.up.fill"
        case .mercury:
            return "waveform.path.ecg"
        case .photos:
            return "photo.fill"
        case .kaleidoscope:
            return "circle.hexagongrid.fill"
        case .unity:
            return "cube.transparent.fill"
        case .generic:
            return "photo.on.rectangle.angled"
        }
    }

    /// 供 UI 取色用的序号（0…5）
    var tintIndex: Int {
        switch self {
        case .collections:
            return 0
        case .mercury:
            return 1
        case .photos:
            return 2
        case .kaleidoscope:
            return 3
        case .unity:
            return 4
        case .generic:
            return 5
        }
    }
}

struct WallpaperItem: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var fileName: String
    var kind: PosterKind
    var descriptorCount: Int
    var isContainerArchive: Bool
    var containsSQLiteStore: Bool
    var fileSize: Int64
    var importedAt: Date
    var isSelected: Bool
    var previewJPEG: Data?
    /// 解析阶段发现的扩展 bundle id 列表，便于诊断
    var detectedExtensions: [String]

    init(
        id: UUID = UUID(),
        name: String,
        fileName: String,
        kind: PosterKind,
        descriptorCount: Int,
        isContainerArchive: Bool,
        containsSQLiteStore: Bool,
        fileSize: Int64,
        importedAt: Date = Date(),
        isSelected: Bool = true,
        previewJPEG: Data? = nil,
        detectedExtensions: [String] = []
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.kind = kind
        self.descriptorCount = descriptorCount
        self.isContainerArchive = isContainerArchive
        self.containsSQLiteStore = containsSQLiteStore
        self.fileSize = fileSize
        self.importedAt = importedAt
        self.isSelected = isSelected
        self.previewJPEG = previewJPEG
        self.detectedExtensions = detectedExtensions
    }

    var fileURL: URL {
        return WallpaperStore.directory.appendingPathComponent(fileName)
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    var summaryLine: String {
        return "\(kind.title) · \(descriptorCount) 个描述符 · \(formattedSize)"
    }
}
