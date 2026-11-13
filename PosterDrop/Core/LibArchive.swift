//
//  LibArchive.swift
//  PosterDrop
//
//  系统自带 libarchive 的极薄封装，只做「把 zip 解到目录」这一件事。
//
//  为什么还要它：
//  自己写的 ZipArchive 只能解 stored / deflate，遇到 zstd、deflate64、
//  分卷、奇怪前缀的包就没辙。系统里一直带着 libarchive（/usr/lib/libarchive.2.dylib），
//  它支持全部 zip 变种，用它兜底最省事——而且它本来就在系统里，不会让 IPA 变大。
//

import Foundation
import Darwin

final class LibArchive {

    static let shared = LibArchive()

    private var library: UnsafeMutableRawPointer?
    private var attempted = false
    private(set) var isAvailable = false
    private(set) var loadError: String?

    private typealias ReadNewFn = @convention(c) () -> OpaquePointer?
    private typealias SupportFn = @convention(c) (OpaquePointer?) -> Int32
    private typealias OpenFilenameFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
    private typealias NextHeaderFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    private typealias EntryPathnameFn = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    private typealias EntryFiletypeFn = @convention(c) (OpaquePointer?) -> UInt32
    private typealias ReadDataFn = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int
    private typealias ReadFreeFn = @convention(c) (OpaquePointer?) -> Int32
    private typealias ErrorStringFn = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

    private var readNew: ReadNewFn?
    private var supportFilterAll: SupportFn?
    private var supportFormatZip: SupportFn?
    private var openFilename: OpenFilenameFn?
    private var nextHeader: NextHeaderFn?
    private var entryPathname: EntryPathnameFn?
    private var entryFiletype: EntryFiletypeFn?
    private var readData: ReadDataFn?
    private var readFree: ReadFreeFn?
    private var errorString: ErrorStringFn?

    /// ARCHIVE_EOF
    private let archiveEOF: Int32 = 1
    /// AE_IFDIR
    private let ifDirectory: UInt32 = 0o040000

    private func loadIfNeeded() -> Bool {
        if attempted { return isAvailable }
        attempted = true

        let candidates = [
            "/usr/lib/libarchive.2.dylib",
            "/usr/lib/libarchive.dylib",
            "/usr/lib/system/libarchive.2.dylib"
        ]

        for path in candidates {
            guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { continue }
            guard let newFn = symbol(handle, "archive_read_new", as: ReadNewFn.self),
                  let filterFn = symbol(handle, "archive_read_support_filter_all", as: SupportFn.self),
                  let formatFn = symbol(handle, "archive_read_support_format_zip", as: SupportFn.self),
                  let openFn = symbol(handle, "archive_read_open_filename", as: OpenFilenameFn.self),
                  let nextFn = symbol(handle, "archive_read_next_header", as: NextHeaderFn.self),
                  let pathFn = symbol(handle, "archive_entry_pathname", as: EntryPathnameFn.self),
                  let typeFn = symbol(handle, "archive_entry_filetype", as: EntryFiletypeFn.self),
                  let dataFn = symbol(handle, "archive_read_data", as: ReadDataFn.self),
                  let freeFn = symbol(handle, "archive_read_free", as: ReadFreeFn.self) else {
                dlclose(handle)
                continue
            }

            library = handle
            readNew = newFn
            supportFilterAll = filterFn
            supportFormatZip = formatFn
            openFilename = openFn
            nextHeader = nextFn
            entryPathname = pathFn
            entryFiletype = typeFn
            readData = dataFn
            readFree = freeFn
            errorString = symbol(handle, "archive_error_string", as: ErrorStringFn.self)
            isAvailable = true
            return true
        }

        loadError = "系统里没有可用的 libarchive"
        return false
    }

    private func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// 解压整包到目录，返回写入的文件数；库不可用时返回 nil。
    func extract(archive path: String, to directory: String) -> Int? {
        guard loadIfNeeded(),
              let readNew, let supportFilterAll, let supportFormatZip,
              let openFilename, let nextHeader, let entryPathname,
              let entryFiletype, let readData, let readFree else { return nil }

        guard let archive = readNew() else { return nil }
        defer { _ = readFree(archive) }

        _ = supportFilterAll(archive)
        _ = supportFormatZip(archive)

        guard openFilename(archive, path, 64 * 1024) == 0 else { return nil }

        let manager = FileManager.default
        try? manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let root = (directory as NSString).standardizingPath

        var written = 0
        while true {
            var entry: OpaquePointer?
            let status = nextHeader(archive, &entry)
            if status == archiveEOF { break }
            guard status == 0, let entry, let cname = entryPathname(entry) else { break }

            let rawName = String(cString: cname)
            guard let relative = ZipArchive.sanitizedPath(rawName) else { continue }
            let target = (root as NSString).appendingPathComponent(relative)
            guard (target as NSString).standardizingPath.hasPrefix(root) else { continue }

            // mode_t 在 arm64 上是 16 位，返回值高位不可信，只比较文件类型位
            if (entryFiletype(entry) & 0o170000) == ifDirectory || rawName.hasSuffix("/") {
                try? manager.createDirectory(atPath: target, withIntermediateDirectories: true)
                continue
            }

            let parent = (target as NSString).deletingLastPathComponent
            try? manager.createDirectory(atPath: parent, withIntermediateDirectories: true)
            unlink(target)

            let fd = open(target, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard fd >= 0 else { continue }
            defer { close(fd) }

            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            var failed = false
            while true {
                let count = buffer.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return readData(archive, base, raw.count)
                }
                if count < 0 { failed = true; break }
                if count == 0 { break }
                var offset = 0
                while offset < count {
                    let n = buffer.withUnsafeBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return -1 }
                        return write(fd, base.advanced(by: offset), count - offset)
                    }
                    if n <= 0 { failed = true; break }
                    offset += n
                }
                if failed { break }
            }
            if !failed {
                written += 1
            } else {
                try? manager.removeItem(atPath: target)
            }
        }
        return written
    }
}
