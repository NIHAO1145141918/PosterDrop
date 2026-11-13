//
//  ZipArchive.swift
//  PosterDrop
//
//  纯 Swift 的 zip 读取器：解析条目表，按需取单个条目或整包解压。
//
//  为什么两条路一起走：
//  - 中央目录（EOCD + CD）给出最准确的文件名与大小，但遇到下面这些就废：
//    · 文件头被塞了前缀（自解压 / 下载器加壳）、末尾追加了签名
//    · EOCD 被注释或垃圾数据污染、条目数写成 0
//    · 中央目录被截断
//  - 于是再扫一遍本地文件头（PK\x03\x04），这条路径只依赖流式字节，
//    对上面几种情况全都有效；两者合并后取长补短。
//
//  支持：stored(0) / deflate(8)、ZIP64、data descriptor(bit 3)、UTF-8 与 GBK 文件名。
//

import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if canImport(Compression) && canImport(Darwin)
import Compression
#endif

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
    let flags: UInt16
    let crc32: UInt32
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
    /// 数据区起始偏移；-1 表示需要现读本地头
    let dataOffset: Int

    var isDirectory: Bool { path.hasSuffix("/") }
    var nameExtension: String { (path as NSString).pathExtension.lowercased() }
    var lastComponent: String { (path as NSString).lastPathComponent }
    var directoryPath: String { (path as NSString).deletingLastPathComponent }
}

/// 解压结果统计，用来在日志里说清楚“为什么一个文件都没写出来”。
struct ZipExtractStats {
    var written: Int = 0
    var skipped: Int = 0
    var skippedDirectories: Int = 0
    var reasons: [String] = []

    var summaryText: String {
        var parts = ["写入 \(written) 个"]
        if skippedDirectories > 0 { parts.append("目录 \(skippedDirectories) 个") }
        if skipped > 0 {
            let detail = reasons.isEmpty ? "" : "（\(reasons.prefix(3).joined(separator: "，")))"
            parts.append("跳过 \(skipped) 个\(detail)")
        }
        return parts.joined(separator: "，")
    }
}

final class ZipArchive {

    /// 单个条目解压上限，避免一条坏数据把内存吃光。
    static let singleEntryLimit = 512 * 1024 * 1024

    let url: URL
    private let handle: FileHandle
    private let fileSize: Int
    private(set) var entries: [ZipEntry] = []
    /// 中央目录声明的条目数（仅用于诊断）
    private(set) var declaredEntryCount: Int = 0
    /// 一行结构诊断，失败时打印出来
    private(set) var summary: String = ""

    private var centralStart = -1

    // MARK: - 解析中间结构

    private struct RawLocal {
        var offset: Int
        var flags: UInt16
        var method: UInt16
        var crc: UInt32
        var compressed: Int
        var uncompressed: Int
        var path: String
        var dataOffset: Int
    }

    private struct CentralRecord {
        var localOffset: Int
        var path: String
        var flags: UInt16
        var method: UInt16
        var crc: UInt32
        var compressed: Int
        var uncompressed: Int
        var unixMode: UInt32
    }

    private struct CentralDirectory {
        var records: [CentralRecord]
        var startOffset: Int
        var declared: Int
        var delta: Int
    }

    // MARK: - 打开

    init(url: URL) throws {
        self.url = url
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size >= 22 else { throw ZipError.notArchive }
        self.fileSize = size
        self.handle = try FileHandle(forReadingFrom: url)
        try parse()
    }

    deinit {
        try? handle.close()
    }

    // MARK: - 主解析

    private func parse() throws {
        let central = findCentralDirectory()
        let locals = scanLocalHeaders()

        var byOffset: [Int: CentralRecord] = [:]
        if let central {
            centralStart = central.startOffset
            for record in central.records {
                let offset = record.localOffset + central.delta
                if offset >= 0 { byOffset[offset] = record }
            }
        }

        if !locals.isEmpty {
            entries = buildEntries(from: locals, central: byOffset)
        } else if let central, !central.records.isEmpty {
            entries = central.records.map { record in
                ZipEntry(
                    path: record.path,
                    method: record.method,
                    flags: record.flags,
                    crc32: record.crc,
                    compressedSize: record.compressed,
                    uncompressedSize: record.uncompressed,
                    localHeaderOffset: record.localOffset + central.delta,
                    dataOffset: -1
                )
            }
        }

        // 过滤明显不是文件名的条目（误命中二进制里的随机字节）
        entries = entries.filter { entry in
            guard !entry.path.isEmpty else { return false }
            guard !entry.path.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return false }
            return entry.compressedSize >= 0
        }

        let fileEntries = entries.filter { !$0.isDirectory }.count
        var pieces: [String] = []
        if let central {
            pieces.append("中央目录 \(central.records.count)/\(central.declared) 条")
            if central.delta != 0 { pieces.append("偏移修正 \(central.delta)") }
        } else {
            pieces.append("中央目录不可用")
        }
        pieces.append("本地头 \(locals.count) 条")
        pieces.append("文件 \(fileEntries) 个")
        if let first = entries.first(where: { !$0.isDirectory }) {
            pieces.append("首项 \(first.path)")
        }
        summary = pieces.joined(separator: "，")

        guard !entries.isEmpty else {
            throw ZipError.corrupt("没解析出任何条目（\(summary)）")
        }
    }

    // MARK: - 中央目录

    private func findCentralDirectory() -> CentralDirectory? {
        let tailLength = min(fileSize, 1_048_576)
        let tailOffset = fileSize - tailLength
        guard let tail = preadData(offset: tailOffset, length: tailLength), tail.count >= 22 else {
            return nil
        }

        var best: (score: Int, index: Int, total: Int, size: Int, offset: Int, delta: Int)?
        var index = tail.count - 22
        var scanned = 0
        while index >= 0, scanned < 4_000 {
            scanned += 1
            if Self.u32(tail, index) == 0x0605_4B50 {
                let total = Int(Self.u16(tail, index + 10) ?? 0)
                let size = Int(Self.u32(tail, index + 12) ?? 0)
                let offset = Int(Self.u32(tail, index + 16) ?? 0)
                let commentLength = Int(Self.u16(tail, index + 20) ?? 0)
                let absolute = tailOffset + index

                if size > 0, offset >= 0, offset + size <= fileSize {
                    var score = 10
                    if absolute + 22 + commentLength == fileSize { score += 20 }
                    var delta = 0
                    // 标准位置能对上签名就是最可信的
                    if firstSignature(at: offset) == 0x0201_4B50 {
                        score += 40
                    } else {
                        // 文件头有前缀 / 末尾有追加时，中央目录真实起点是 EOCD 之前 cdSize 字节
                        let actual = absolute - size
                        if actual >= 0, firstSignature(at: actual) == 0x0201_4B50 {
                            delta = actual - offset
                            score += 30
                        } else {
                            score = -1
                        }
                    }
                    if score > (best?.score ?? -1) {
                        best = (score, index, total, size, offset, delta)
                    }
                }
            }
            index -= 1
        }

        guard let best, best.score > 0 else { return nil }
        declaredEntryCount = best.total

        var records = parseCentralRecords(
            start: best.offset + best.delta,
            size: best.size,
            zip64Offset: tailOffset + best.index - 20
        )

        // ZIP64：EOCD 里 0xFFFF / 0xFFFFFFFF 表示要读 ZIP64 记录
        if best.total == 0xFFFF || best.size == 0xFFFF_FFFF || best.offset == 0xFFFF_FFFF {
            if let zip64 = readZip64(locatorOffset: tailOffset + best.index - 20) {
                declaredEntryCount = Int(zip64.total)
                records = parseCentralRecords(
                    start: Int(zip64.offset),
                    size: Int(zip64.size),
                    zip64Offset: nil
                )
            }
        }

        return CentralDirectory(
            records: records,
            startOffset: best.offset + best.delta,
            declared: declaredEntryCount,
            delta: best.delta
        )
    }

    private func readZip64(locatorOffset: Int) -> (total: UInt64, size: UInt64, offset: UInt64)? {
        guard locatorOffset >= 0,
              let locator = preadData(offset: locatorOffset, length: 20), locator.count == 20,
              Self.u32(locator, 0) == 0x0706_4B50,
              let recordOffset = Self.u64(locator, 8), recordOffset < UInt64(fileSize) else {
            return nil
        }
        guard let record = preadData(offset: Int(recordOffset), length: 56), record.count >= 56,
              Self.u32(record, 0) == 0x0606_4B50,
              let total = Self.u64(record, 32),
              let size = Self.u64(record, 40),
              let offset = Self.u64(record, 48) else {
            return nil
        }
        return (total, size, offset)
    }

    private func parseCentralRecords(start: Int, size: Int, zip64Offset: Int?) -> [CentralRecord] {
        guard start >= 0, size > 0, start + size <= fileSize,
              let cd = preadData(offset: start, length: size) else { return [] }

        var records: [CentralRecord] = []
        var pointer = 0
        while pointer + 46 <= cd.count, Self.u32(cd, pointer) == 0x0201_4B50 {
            let flags = Self.u16(cd, pointer + 8) ?? 0
            let method = Self.u16(cd, pointer + 10) ?? 0
            let crc = Self.u32(cd, pointer + 16) ?? 0
            var compressed = Int(Self.u32(cd, pointer + 20) ?? 0)
            var uncompressed = Int(Self.u32(cd, pointer + 24) ?? 0)
            let nameLength = Int(Self.u16(cd, pointer + 28) ?? 0)
            let extraLength = Int(Self.u16(cd, pointer + 30) ?? 0)
            let commentLength = Int(Self.u16(cd, pointer + 32) ?? 0)
            var localOffset = Int(Self.u32(cd, pointer + 42) ?? 0)
            let unixMode = Self.u32(cd, pointer + 38) ?? 0

            let nameStart = pointer + 46
            guard nameStart + nameLength <= cd.count else { break }
            let nameData = cd.subdata(in: nameStart..<(nameStart + nameLength))
            let path = Self.decodeName(nameData, flags: flags) ?? ""

            let extraStart = nameStart + nameLength
            if extraLength > 0, extraStart + extraLength <= cd.count {
                let extra = cd.subdata(in: extraStart..<(extraStart + extraLength))
                var cursor = 0
                while cursor + 4 <= extra.count {
                    let tag = Self.u16(extra, cursor) ?? 0
                    let length = Int(Self.u16(extra, cursor + 2) ?? 0)
                    guard cursor + 4 + length <= extra.count else { break }
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

            if !path.isEmpty {
                records.append(
                    CentralRecord(
                        localOffset: localOffset,
                        path: path,
                        flags: flags,
                        method: method,
                        crc: crc,
                        compressed: compressed,
                        uncompressed: uncompressed,
                        unixMode: unixMode
                    )
                )
            }

            pointer = extraStart + extraLength + commentLength
        }
        return records
    }

    private func firstSignature(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= fileSize,
              let head = preadData(offset: offset, length: 4), head.count == 4 else { return nil }
        return Self.u32(head, 0)
    }

    // MARK: - 本地文件头扫描

    /// 流式扫描 PK\x03\x04：不依赖中央目录，前缀 / 追加数据 / 坏 EOCD 都不影响。
    private func scanLocalHeaders() -> [RawLocal] {
        let chunkSize = 4 << 20
        var results: [RawLocal] = []
        var offset = 0
        var carry: [UInt8] = []

        while offset < fileSize {
            let want = min(chunkSize, fileSize - offset)
            guard let data = preadData(offset: offset, length: want), !data.isEmpty else { break }

            var buffer = carry
            buffer.append(contentsOf: data)
            let base = offset - carry.count
            let total = buffer.count
            var cursor = 0

            buffer.withUnsafeBytes { raw in
                guard let start = raw.baseAddress else { return }
                while cursor + 4 <= total {
                    guard let hit = memchr(start.advanced(by: cursor), 0x50, total - cursor) else { return }
                    let index = start.distance(to: UnsafeRawPointer(hit))
                    if index + 4 <= total,
                       raw[index + 1] == 0x4B,
                       raw[index + 2] == 0x03,
                       raw[index + 3] == 0x04,
                       let parsed = parseLocalHeader(at: base + index) {
                        results.append(parsed)
                        cursor = index + 4
                        continue
                    }
                    cursor = index + 1
                }
            }

            carry = Array(buffer.suffix(3))
            offset += want
        }
        return results
    }

    private func parseLocalHeader(at offset: Int) -> RawLocal? {
        guard offset >= 0, offset + 30 <= fileSize,
              let header = preadData(offset: offset, length: 30), header.count == 30,
              Self.u32(header, 0) == 0x0403_4B50 else { return nil }

        let flags = Self.u16(header, 6) ?? 0
        let method = Self.u16(header, 8) ?? 0
        // zip 允许的压缩方法都在这些区间；挡掉二进制垃圾
        guard method <= 20 || method >= 90 else { return nil }

        let crc = Self.u32(header, 14) ?? 0
        let compressed = Int(Self.u32(header, 18) ?? 0)
        let uncompressed = Int(Self.u32(header, 22) ?? 0)
        let nameLength = Int(Self.u16(header, 26) ?? 0)
        let extraLength = Int(Self.u16(header, 28) ?? 0)

        guard nameLength > 0, nameLength <= 4_096, extraLength <= 65_535 else { return nil }
        let dataOffset = offset + 30 + nameLength + extraLength
        guard dataOffset <= fileSize else { return nil }

        guard let nameData = preadData(offset: offset + 30, length: nameLength),
              nameData.count == nameLength,
              !nameData.contains(0),
              let path = Self.decodeName(nameData, flags: flags),
              !path.isEmpty else { return nil }

        return RawLocal(
            offset: offset,
            flags: flags,
            method: method,
            crc: crc,
            compressed: compressed,
            uncompressed: uncompressed,
            path: path,
            dataOffset: dataOffset
        )
    }

    /// 用本地头 ＋ 中央目录合成条目表：本地头给顺序和位置，中央目录给准确大小。
    private func buildEntries(from locals: [RawLocal], central: [Int: CentralRecord]) -> [ZipEntry] {
        let sorted = locals.sorted { $0.offset < $1.offset }
        var result: [ZipEntry] = []
        var seen = Set<Int>()

        for (index, local) in sorted.enumerated() {
            guard !seen.contains(local.offset) else { continue }
            seen.insert(local.offset)

            let record = central[local.offset]
            var compressed = record?.compressed ?? local.compressed
            let uncompressed = record?.uncompressed ?? local.uncompressed
            let flags = record?.flags ?? local.flags
            var path = local.path
            if let record, !record.path.isEmpty { path = record.path }

            if compressed <= 0 {
                // data descriptor（bit 3）：大小写在数据后面，只能靠下一个头的边界反推
                var end = index + 1 < sorted.count ? sorted[index + 1].offset : -1
                if end < 0 {
                    end = centralStart > local.dataOffset ? centralStart : fileSize
                }
                if flags & 0x0008 != 0, end > local.dataOffset {
                    if end - 16 > local.dataOffset,
                       firstSignature(at: end - 16) == 0x0807_4B50 {
                        end -= 16
                    } else if end - 12 > local.dataOffset {
                        end -= 12
                    }
                }
                compressed = max(0, end - local.dataOffset)
            }
            guard compressed >= 0, compressed <= fileSize else { continue }

            result.append(
                ZipEntry(
                    path: path,
                    method: local.method,
                    flags: flags,
                    crc32: record?.crc ?? local.crc,
                    compressedSize: compressed,
                    uncompressedSize: uncompressed,
                    localHeaderOffset: local.offset,
                    dataOffset: local.dataOffset
                )
            )
        }
        return result
    }

    // MARK: - 读取条目

    /// 读出单个条目的原始数据。
    func data(for entry: ZipEntry, limit: Int = ZipArchive.singleEntryLimit) throws -> Data {
        if entry.uncompressedSize > limit {
            throw ZipError.tooLarge("\(entry.lastComponent) 解压后 \(entry.uncompressedSize / 1_048_576) MB")
        }
        guard entry.compressedSize >= 0, entry.compressedSize <= limit else {
            throw ZipError.tooLarge("\(entry.lastComponent) 压缩体积 \(entry.compressedSize / 1_048_576) MB")
        }

        var dataStart = entry.dataOffset
        if dataStart < 0 {
            guard let header = preadData(offset: entry.localHeaderOffset, length: 30), header.count == 30 else {
                throw ZipError.corrupt("条目头读不到：\(entry.path)")
            }
            let nameLength = Int(Self.u16(header, 26) ?? 0)
            let extraLength = Int(Self.u16(header, 28) ?? 0)
            dataStart = entry.localHeaderOffset + 30 + nameLength + extraLength
        }

        if entry.compressedSize == 0 {
            return Data()
        }
        guard dataStart + entry.compressedSize <= fileSize else {
            throw ZipError.corrupt("条目数据越界：\(entry.path)")
        }
        guard let raw = preadData(offset: dataStart, length: entry.compressedSize),
              raw.count >= entry.compressedSize else {
            throw ZipError.corrupt("条目被截断：\(entry.path)")
        }

        switch entry.method {
        case 0:
            return raw
        case 8:
            return try inflate(raw, expected: entry.uncompressedSize)
        default:
            throw ZipError.unsupported("method \(entry.method)")
        }
    }

    /// Compression 框架的 COMPRESSION_ZLIB 走 raw DEFLATE（zip 用的就是这种）。
    /// 少数包会带 zlib 头，解不开时再试一次跳过 2 字节。
    private func inflate(_ data: Data, expected: Int) throws -> Data {
        #if canImport(Compression) && canImport(Darwin)
        if expected > 0, let output = decodeDeflate(data, expected: expected, limit: ZipArchive.singleEntryLimit) {
            return output
        }
        if let output = decodeDeflate(data, expected: expected, limit: ZipArchive.singleEntryLimit) {
            return output
        }
        if data.count > 6, let output = decodeDeflate(data.dropFirst(2), expected: expected, limit: ZipArchive.singleEntryLimit) {
            return output
        }
        throw ZipError.corrupt("deflate 解压失败")
        #else
        throw ZipError.unsupported("当前平台不支持 deflate")
        #endif
    }

    #if canImport(Compression) && canImport(Darwin)
    private func decodeDeflate(_ data: Data, expected: Int, limit: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        var capacity = max(expected, 64 * 1024)
        if capacity > limit { capacity = limit }

        for _ in 0..<6 {
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
            if capacity >= limit { break }
            capacity = min(capacity * 4, limit)
        }
        return nil
    }
    #endif

    // MARK: - 整体解压

    /// 解压全部条目到目录，并返回统计（写得少的时候能说清原因）。
    @discardableResult
    func extractAll(to directory: URL) throws -> ZipExtractStats {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let rootPath = directory.standardizedFileURL.path
        var stats = ZipExtractStats()

        for entry in entries {
            let lower = entry.path.lowercased()
            if lower.contains("__macosx") || lower.hasSuffix(".ds_store") || lower.contains("/.ds_store") {
                stats.skipped += 1
                continue
            }
            guard let relative = Self.sanitizedPath(entry.path) else {
                stats.skipped += 1
                if stats.reasons.count < 5 { stats.reasons.append("非法路径 \(entry.path)") }
                continue
            }
            let target = directory.appendingPathComponent(relative)
            guard target.standardizedFileURL.path.hasPrefix(rootPath) else {
                stats.skipped += 1
                if stats.reasons.count < 5 { stats.reasons.append("越界 \(entry.path)") }
                continue
            }

            if entry.isDirectory {
                try? manager.createDirectory(at: target, withIntermediateDirectories: true)
                stats.skippedDirectories += 1
                continue
            }

            try? manager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if entry.method == 0 {
                try streamCopy(entry: entry, to: target, dataStart: entry.dataOffset)
            } else {
                let data = try data(for: entry)
                try data.write(to: target, options: .atomic)
            }
            stats.written += 1
        }
        return stats
    }

    /// stored 条目直接分块拷贝，避免把几百 MB 的视频读进内存。
    private func streamCopy(entry: ZipEntry, to target: URL, dataStart: Int) throws {
        let manager = FileManager.default
        _ = manager.createFile(atPath: target.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: target) else {
            throw ZipError.corrupt("无法写入 \(target.lastPathComponent)")
        }
        defer { try? output.close() }

        var start = dataStart
        if start < 0 {
            guard let header = preadData(offset: entry.localHeaderOffset, length: 30), header.count == 30 else {
                throw ZipError.corrupt("条目头读不到：\(entry.path)")
            }
            start = entry.localHeaderOffset + 30 + Int(Self.u16(header, 26) ?? 0) + Int(Self.u16(header, 28) ?? 0)
        }

        var remaining = entry.compressedSize
        var cursor = start
        while remaining > 0 {
            let chunkSize = min(remaining, 1 << 20)
            guard let chunk = preadData(offset: cursor, length: chunkSize), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            remaining -= chunk.count
            cursor += chunk.count
        }
    }

    // MARK: - 工具

    /// 规范化条目路径：反斜杠转正斜杠、去掉 . 与绝对路径前缀、拦 .. 越界。
    static func sanitizedPath(_ path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        var components: [String] = []
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
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

    /// 文件名解码：优先 UTF-8（bit 11 或自然合法），其次 GBK，最后 Latin-1。
    static func decodeName(_ data: Data, flags: UInt16) -> String? {
        if let text = String(data: data, encoding: .utf8), !text.isEmpty { return text }
        #if canImport(Darwin)
        let gbk = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let text = String(data: data, encoding: String.Encoding(rawValue: gbk)), !text.isEmpty {
            return text
        }
        #endif
        return String(data: data, encoding: .isoLatin1)
    }

    /// pread 不改文件偏移，可以和 FileHandle 的顺序读混用。
    private func preadData(offset: Int, length: Int) -> Data? {
        guard offset >= 0, length > 0, offset < fileSize else { return nil }
        let count = min(length, fileSize - offset)
        guard count > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        let fd = handle.fileDescriptor
        while got < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return pread(fd, base.advanced(by: got), count - got, off_t(offset + got))
            }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            got += n
        }
        guard got > 0 else { return nil }
        return Data(buffer[0..<got])
    }

    private static func u16(_ data: Data, _ index: Int) -> UInt16? {
        guard index >= 0, index + 2 <= data.count else { return nil }
        return data.withUnsafeBytes { buffer in
            UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: index, as: UInt16.self))
        }
    }

    private static func u32(_ data: Data, _ index: Int) -> UInt32? {
        guard index >= 0, index + 4 <= data.count else { return nil }
        return data.withUnsafeBytes { buffer in
            UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: index, as: UInt32.self))
        }
    }

    private static func u64(_ data: Data, _ index: Int) -> UInt64? {
        guard index >= 0, index + 8 <= data.count else { return nil }
        return data.withUnsafeBytes { buffer in
            UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: index, as: UInt64.self))
        }
    }
}
