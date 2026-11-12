//
//  ZipArchive.swift
//  PosterDrop
//
//  纯 Swift 的 zip 读取器：只解析中央目录，按需取单个条目。
//
//  为什么要自己写：
//  - 导入时只需要「列出条目 + 取一张预览图」，不必先把整包解到临时目录，
//    大包也不会把磁盘撑爆。
//  - 注入时才真正解压；全过程留在 Swift 内，失败能拿到具体原因而不是一个错误码。
//
//  支持：stored(0) / deflate(8)、ZIP64 中央目录、UTF-8 与 CP437 文件名。
//

import Foundation
import Compression

enum ZipError: LocalizedError {
    case notArchive
    case corrupt(String)
    case unsupported(String)
    case tooLarge(String)

    var errorDescription: String? {
        switch self {
        case .notArchive:
            return "不是 zip / .tendies 压缩包"
        case .corrupt(let detail):
            return "压缩包损坏（\(detail)）"
        case .unsupported(let detail):
            return "不支持的压缩方式（\(detail)）"
        case .tooLarge(let detail):
            return "单个文件过大（\(detail)）"
        }
    }
}

struct ZipEntry {
    let path: String
    let method: UInt16
    let crc32: UInt32
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int

    var isDirectory: Bool { path.hasSuffix("/") }
    var nameExtension: String { (path as NSString).pathExtension.lowercased() }
    var lastComponent: String { (path as NSString).lastPathComponent }
    var directoryPath: String { (path as NSString).deletingLastPathComponent }
}

final class ZipArchive {

    /// 单个条目解压上限，避免一条坏数据把内存吃光（超出时走 Rust 整体解压兜底）。
    static let singleEntryLimit = 384 * 1024 * 1024

    let url: URL
    private let handle: FileHandle
    private let fileSize: Int
    private(set) var entries: [ZipEntry] = []
    /// 中央目录里声明的条目数（可能包含被跳过的目录）
    private(set) var declaredEntryCount: Int = 0

    // MARK: - 打开

    init(url: URL) throws {
        self.url = url
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size >= 22 else { throw ZipError.notArchive }
        self.fileSize = size
        self.handle = try FileHandle(forReadingFrom: url)
        try parseCentralDirectory()
    }

    deinit {
        try? handle.close()
    }

    // MARK: - 中央目录

    private func parseCentralDirectory() throws {
        let tailLength = min(fileSize, 66_000)
        let tailOffset = fileSize - tailLength
        try handle.seek(toOffset: UInt64(tailOffset))
        let tail = try handle.read(upToCount: tailLength) ?? Data()
        guard tail.count >= 22 else { throw ZipError.notArchive }

        var eocd = -1
        var index = tail.count - 22
        while index >= 0 {
            if tail[index] == 0x50, tail[index + 1] == 0x4B,
               tail[index + 2] == 0x05, tail[index + 3] == 0x06 {
                eocd = index
                break
            }
            index -= 1
        }
        guard eocd >= 0 else { throw ZipError.notArchive }

        var total = Int(Self.u16(tail, eocd + 10) ?? 0)
        var cdSize = Int(Self.u32(tail, eocd + 12) ?? 0)
        var cdOffset = Int(Self.u32(tail, eocd + 16) ?? 0)

        // ZIP64：EOCD 前 20 字节是 locator
        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF, eocd >= 20 {
            let locator = eocd - 20
            if Self.u32(tail, locator) == 0x0706_4B50,
               let zip64Offset = Self.u64(tail, locator + 8) {
                let record = try read(at: Int(zip64Offset), length: 56)
                if record.count >= 56, Self.u32(record, 0) == 0x0606_4B50 {
                    total = Int(Self.u64(record, 32) ?? UInt64(total))
                    cdSize = Int(Self.u64(record, 40) ?? UInt64(cdSize))
                    cdOffset = Int(Self.u64(record, 48) ?? UInt64(cdOffset))
                }
            }
        }

        guard cdSize > 0, cdOffset >= 0, cdOffset + cdSize <= fileSize else {
            throw ZipError.corrupt("中央目录超出文件范围")
        }
        declaredEntryCount = total

        let cd = try read(at: cdOffset, length: cdSize)
        var pointer = 0
        var parsed = 0

        while pointer + 46 <= cd.count, Self.u32(cd, pointer) == 0x0201_4B50, parsed < max(total, 1) {
            let method = Self.u16(cd, pointer + 10) ?? 0
            let crc = Self.u32(cd, pointer + 16) ?? 0
            var compressed = Int(Self.u32(cd, pointer + 20) ?? 0)
            var uncompressed = Int(Self.u32(cd, pointer + 24) ?? 0)
            let nameLength = Int(Self.u16(cd, pointer + 28) ?? 0)
            let extraLength = Int(Self.u16(cd, pointer + 30) ?? 0)
            let commentLength = Int(Self.u16(cd, pointer + 32) ?? 0)
            var localOffset = Int(Self.u32(cd, pointer + 42) ?? 0)

            let nameStart = pointer + 46
            guard nameStart + nameLength <= cd.count else { break }
            let nameData = cd.subdata(in: nameStart..<(nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""

            let extraStart = nameStart + nameLength
            if extraLength > 0, extraStart + extraLength <= cd.count {
                let extra = cd.subdata(in: extraStart..<(extraStart + extraLength))
                var cursor = 0
                while cursor + 4 <= extra.count {
                    let tag = Self.u16(extra, cursor) ?? 0
                    let length = Int(Self.u16(extra, cursor + 2) ?? 0)
                    if cursor + 4 + length > extra.count { break }
                    if tag == 0x0001 {
                        var inner = cursor + 4
                        let end = cursor + 4 + length
                        if uncompressed == 0xFFFF_FFFF, inner + 8 <= end {
                            uncompressed = Int(Self.u64(extra, inner) ?? 0)
                            inner += 8
                        }
                        if compressed == 0xFFFF_FFFF, inner + 8 <= end {
                            compressed = Int(Self.u64(extra, inner) ?? 0)
                            inner += 8
                        }
                        if localOffset == 0xFFFF_FFFF, inner + 8 <= end {
                            localOffset = Int(Self.u64(extra, inner) ?? 0)
                            inner += 8
                        }
                    }
                    cursor += 4 + length
                }
            }

            if !name.isEmpty {
                entries.append(
                    ZipEntry(
                        path: name,
                        method: method,
                        crc32: crc,
                        compressedSize: compressed,
                        uncompressedSize: uncompressed,
                        localHeaderOffset: localOffset
                    )
                )
            }

            parsed += 1
            pointer = extraStart + extraLength + commentLength
        }

        guard !entries.isEmpty else { throw ZipError.corrupt("压缩包里没有任何条目") }
    }

    // MARK: - 读取条目

    /// 读出单个条目的原始数据。
    func data(for entry: ZipEntry, limit: Int = ZipArchive.singleEntryLimit) throws -> Data {
        guard entry.uncompressedSize <= limit else {
            throw ZipError.tooLarge("\(entry.lastComponent) 解压后 \(entry.uncompressedSize / 1_048_576) MB")
        }

        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        let header = try handle.read(upToCount: 30) ?? Data()
        guard header.count == 30, Self.u32(header, 0) == 0x0403_4B50 else {
            throw ZipError.corrupt("条目头无效：\(entry.path)")
        }
        let nameLength = Int(Self.u16(header, 26) ?? 0)
        let extraLength = Int(Self.u16(header, 28) ?? 0)
        let dataOffset = entry.localHeaderOffset + 30 + nameLength + extraLength
        guard dataOffset + entry.compressedSize <= fileSize else {
            throw ZipError.corrupt("条目数据越界：\(entry.path)")
        }

        try handle.seek(toOffset: UInt64(dataOffset))
        let raw = try handle.read(upToCount: max(entry.compressedSize, 1)) ?? Data()
        guard raw.count >= entry.compressedSize else {
            throw ZipError.corrupt("条目被截断：\(entry.path)")
        }

        switch entry.method {
        case 0:
            return raw.prefix(entry.compressedSize)
        case 8:
            return try inflate(raw.prefix(entry.compressedSize), expected: entry.uncompressedSize)
        default:
            throw ZipError.unsupported("method \(entry.method)")
        }
    }

    /// Compression 框架的 COMPRESSION_ZLIB 走的是 raw DEFLATE（zip 用的就是这种）。
    /// 为防系统实现差异，原始数据解不开时再试一次「跳过 2 字节 zlib 头」。
    private func inflate(_ data: Data, expected: Int) throws -> Data {
        if expected == 0 { return Data() }
        if let output = decodeDeflate(data, expected: expected) { return output }
        if data.count > 6, let output = decodeDeflate(data.dropFirst(2), expected: expected) {
            return output
        }
        throw ZipError.corrupt("deflate 解压失败")
    }

    private func decodeDeflate(_ data: Data, expected: Int) -> Data? {
        var capacity = max(expected, 64)
        for _ in 0..<3 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination -> Int in
                guard let dst = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return data.withUnsafeBytes { source -> Int in
                    guard let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(
                        dst, capacity,
                        src, data.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0 {
                output.removeSubrange(written..<output.count)
                return output
            }
            capacity *= 4
            if capacity > ZipArchive.singleEntryLimit { break }
        }
        return nil
    }

    // MARK: - 整体解压

    /// 解压全部条目到目录，返回写入的文件数。
    @discardableResult
    func extractAll(to directory: URL) throws -> Int {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let rootPath = directory.standardizedFileURL.path
        var written = 0

        for entry in entries {
            let lower = entry.path.lowercased()
            if lower.contains("__macosx") || lower.hasSuffix(".ds_store") { continue }
            guard let relative = Self.sanitizedPath(entry.path) else { continue }
            let target = directory.appendingPathComponent(relative)
            guard target.standardizedFileURL.path.hasPrefix(rootPath) else { continue }

            if entry.isDirectory {
                try? manager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }

            try? manager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if entry.method == 0 {
                try streamCopy(entry: entry, to: target)
            } else {
                let data = try data(for: entry)
                try data.write(to: target, options: .atomic)
            }
            written += 1
        }
        return written
    }

    /// stored 条目直接分块拷贝，避免把几百 MB 的视频读进内存。
    private func streamCopy(entry: ZipEntry, to target: URL) throws {
        let manager = FileManager.default
        _ = manager.createFile(atPath: target.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: target) else {
            throw ZipError.corrupt("无法写入 \(target.lastPathComponent)")
        }
        defer { try? output.close() }

        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        let header = try handle.read(upToCount: 30) ?? Data()
        guard header.count == 30 else { throw ZipError.corrupt("条目头无效：\(entry.path)") }
        let nameLength = Int(Self.u16(header, 26) ?? 0)
        let extraLength = Int(Self.u16(header, 28) ?? 0)
        let dataOffset = entry.localHeaderOffset + 30 + nameLength + extraLength
        try handle.seek(toOffset: UInt64(dataOffset))

        var remaining = entry.compressedSize
        while remaining > 0 {
            let chunkSize = min(remaining, 1 << 20)
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            remaining -= chunk.count
        }
    }

    // MARK: - 工具

    static func sanitizedPath(_ path: String) -> String? {
        var components: [String] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { return nil }
            components.append(String(component))
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    /// 只看前 4 字节判断是不是 zip。
    static func looksLikeZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        return head[head.startIndex] == 0x50
            && head[head.startIndex + 1] == 0x4B
            && (head[head.startIndex + 2] == 0x03 || head[head.startIndex + 2] == 0x05
                || head[head.startIndex + 2] == 0x07)
            && (head[head.startIndex + 3] == 0x04 || head[head.startIndex + 3] == 0x06
                || head[head.startIndex + 3] == 0x08)
    }

    private func read(at offset: Int, length: Int) throws -> Data {
        guard offset >= 0, length > 0, offset + length <= fileSize else { return Data() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    }

    private static func u16(_ data: Data, _ index: Int) -> UInt16? {
        guard index >= 0, index + 2 <= data.count else { return nil }
        let base = data.startIndex + index
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func u32(_ data: Data, _ index: Int) -> UInt32? {
        guard index >= 0, index + 4 <= data.count else { return nil }
        let base = data.startIndex + index
        var value: UInt32 = 0
        for offset in stride(from: 3, through: 0, by: -1) {
            value = (value << 8) | UInt32(data[base + offset])
        }
        return value
    }

    private static func u64(_ data: Data, _ index: Int) -> UInt64? {
        guard index >= 0, index + 8 <= data.count else { return nil }
        let base = data.startIndex + index
        var value: UInt64 = 0
        for offset in stride(from: 7, through: 0, by: -1) {
            value = (value << 8) | UInt64(data[base + offset])
        }
        return value
    }
}
