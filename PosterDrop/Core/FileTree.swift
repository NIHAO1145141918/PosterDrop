//
//  FileTree.swift
//  PosterDrop
//
//  目录遍历的最小内核。全部基于「目录 fd 相对操作」，不拼全路径：
//
//    open(path)          → 一个目录 fd
//    openat(fd, "子目录")  → 以 fd 为起点，内核只解析这一段名字
//    fstatat(fd, "名字")   → 同上，拿属性
//    unlinkat(fd, "名字")  → 同上，删除
//
//  为什么不用 `dir + "/" + name` 再 lstat：那样每访问一个文件，内核都要从根
//  重新解析整条 ~80 字符的路径（/private/var/mobile/Containers/Data/Application/<UUID>/
//  Library/Caches/...）。一个 5 万文件的缓存目录就是 5 万次全路径解析。
//  改成从已经打开的父目录 fd 出发，前缀解析全部省掉。
//  这一条来自 YangJiiii/3105 的 LimitedCleanerService，是它唯一但很实在的性能长处。
//
//  统计另外叠了一层 getattrlistbulk：一次系统调用拿回一批条目（名字 + 类型 + 占用），
//  把一个文件一次 stat 压成几十个文件一次调用。这个 API 的返回缓冲区是手工解析的，
//  布局算错就会读出垃圾，所以启动时先用一个已知内容的小目录做自检（Bulk.probe），
//  校验不过就整体退回 fstatat —— 宁可慢，不能算错。
//
//  安全：
//    · 所有 openat 都带 O_NOFOLLOW，符号链接不会被跟进去；
//    · 统计时符号链接既不计数也不递归（App Group 的 Library/Caches 就是符号链接，
//      跟进去等于把链接目标的大小算进自己头上）；
//    · 删除时符号链接只 unlink 自己那一项。
//

import Foundation
import Darwin

enum FileTree {

    /// 最长递归深度，挡住异常深的目录树（也顺手限制 fd 占用）。
    static let maxDepth = 24

    /// 遍历时每层目录占一个 fd，并发起来容易撞上默认的 256 上限。
    /// 这里把软限制抬到 1024（不超过硬限制），只做一次。
    private static let raisedFileLimit: Void = {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        var next = limit
        next.rlim_cur = min(limit.rlim_max, 1024)
        setrlimit(RLIMIT_NOFILE, &next)
    }()

    // MARK: - 统计结果

    /// 统计结果用引用类型：遍历里既递归又嵌在指针闭包内，
    /// inout 传值会触发 Swift 的独占访问检查，引用则天然共享同一份计数。
    final class Tally {
        var bytes: Int64 = 0
        var files = 0
        var nodes = 0
        var truncated = false
        var denied = false
    }

    struct Removal {
        var bytes: Int64 = 0
        var files = 0
        var directories = 0
        var failures: [String] = []
    }

    // MARK: - 打开

    @inline(__always)
    static func openDirectory(_ path: String) -> Int32? {
        _ = raisedFileLimit
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        return fd >= 0 ? fd : nil
    }

    /// `relative` 可以带斜杠（"Library/Caches"），内核会逐段解析，起点是 parent。
    @inline(__always)
    static func openSubdirectory(_ parent: Int32, _ relative: String) -> Int32? {
        _ = raisedFileLimit
        let fd = relative.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        return fd >= 0 ? fd : nil
    }

    /// 相对 fd 读扩展属性，省掉一次全路径解析。
    static func xattr(_ fd: Int32, _ name: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = fgetxattr(fd, name, &buffer, buffer.count - 1, 0, 0)
        guard length > 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    @inline(__always)
    static func exists(_ parent: Int32, _ relative: String) -> Bool {
        var info = stat()
        let status = relative.withCString {
            fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        return status == 0
    }

    // MARK: - 统计入口

    /// 从路径打开并统计。返回 false 表示根目录打不开（不存在或没权限）。
    @discardableResult
    static func measure(
        root: String,
        parent: Int32? = nil,
        relative: String? = nil,
        prefix: String?,
        budget: Int,
        deadline: Date,
        tally: Tally
    ) -> Bool {
        var fd: Int32
        if let parent, let relative {
            guard let opened = openSubdirectory(parent, relative) else { return false }
            fd = opened
        } else {
            guard let opened = openDirectory(root) else { return false }
            fd = opened
        }
        defer { close(fd) }

        var remaining = budget
        scan(
            fd: fd,
            path: root,
            prefix: prefix,
            depth: 0,
            budget: &remaining,
            deadline: deadline,
            tally: tally
        )
        return true
    }

    /// 已经持有 fd 时直接统计（不接管 fd，内部不 close）。
    static func measure(
        fd: Int32,
        path: String,
        prefix: String?,
        budget: inout Int,
        deadline: Date,
        tally: Tally
    ) {
        scan(
            fd: fd,
            path: path,
            prefix: prefix,
            depth: 0,
            budget: &budget,
            deadline: deadline,
            tally: tally
        )
    }

    // MARK: - 统计内核

    private static func scan(
        fd: Int32,
        path: String,
        prefix: String?,
        depth: Int,
        budget: inout Int,
        deadline: Date,
        tally: Tally
    ) {
        guard depth <= maxDepth else {
            tally.truncated = true
            return
        }
        guard budget > 0, Date() < deadline else {
            tally.truncated = true
            return
        }

        if Bulk.usable {
            let finished = scanBulk(
                fd: fd, path: path, prefix: prefix, depth: depth,
                budget: &budget, deadline: deadline, tally: tally
            )
            if finished { return }
            // 自检通过，但个别目录仍可能被内核拒绝（合成文件系统、老文件系统）。
            // 只在「一条都没读到」时才回退，不会重复计数。
            tally.denied = false
        }
        scanStat(
            fd: fd, path: path, prefix: prefix, depth: depth,
            budget: &budget, deadline: deadline, tally: tally
        )
    }

    /// 返回 false 表示这个目录一次都没读出来，调用方应该退回 fstatat 版本。
    private static func scanBulk(
        fd: Int32,
        path: String,
        prefix: String?,
        depth: Int,
        budget: inout Int,
        deadline: Date,
        tally: Tally
    ) -> Bool {
        var list = attrlist()
        list.bitmapcount = 5
        list.commonattr = Attr.returned | Attr.name | Attr.objectType
        list.fileattr = Attr.allocSize

        // 32KB 能装下几百条记录，又不会因为递归层层持有多份大缓冲而吃掉内存
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        var handled = 0

        while true {
            guard budget > 0, Date() < deadline else {
                tally.truncated = true
                return true
            }

            let count = buffer.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return 0 }
                return getattrlistbulk(fd, &list, base, raw.count, 0)
            }

            if count == 0 { return true }
            if count < 0 {
                if errno == EPERM || errno == EACCES { tally.denied = true }
                if errno == ENOTSUP || errno == EINVAL { Bulk.markUnusable() }
                return handled > 0
            }

            var stop = false
            buffer.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var cursor = 0

                for _ in 0..<Int(count) {
                    // 每条记录：u32 长度 + attribute_set_t（5 × u32）+ 属性值
                    guard cursor + Attr.headerSize <= raw.count else { stop = true; return }
                    let length = Int(base.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
                    guard length > Attr.headerSize, cursor + length <= raw.count else {
                        stop = true
                        return
                    }

                    let entry = base.advanced(by: cursor)
                    guard let parsed = parseEntry(entry, length: length) else {
                        cursor += length
                        continue
                    }
                    let name = parsed.name

                    budget -= 1
                    tally.nodes += 1
                    handled += 1
                    cursor += length

                    if budget <= 0 {
                        tally.truncated = true
                        stop = true
                        return
                    }
                    if depth == 0, let prefix, !name.hasPrefix(prefix) { continue }

                    if parsed.kind == Attr.vdir {
                        if let child = openSubdirectory(fd, name) {
                            scan(
                                fd: child, path: path + "/" + name, prefix: nil, depth: depth + 1,
                                budget: &budget, deadline: deadline, tally: tally
                            )
                            close(child)
                        } else if errno == EMFILE || errno == ENFILE {
                            // fd 用尽：停止继续深入，已统计的部分仍然有效
                            tally.truncated = true
                        } else {
                            tally.denied = true
                        }
                    } else if parsed.kind == Attr.vreg {
                        if parsed.bytes > 0 { tally.bytes += parsed.bytes }
                        tally.files += 1
                    }
                    // 其余（符号链接、socket、设备节点）不计数、不跟随

                    if budget <= 0 {
                        tally.truncated = true
                        stop = true
                        return
                    }
                }
            }
            if stop { return true }
        }
    }

    private static func scanStat(
        fd: Int32,
        path: String,
        prefix: String?,
        depth: Int,
        budget: inout Int,
        deadline: Date,
        tally: Tally
    ) {
        let iterator = dup(fd)
        guard iterator >= 0, let directory = fdopendir(iterator) else {
            if iterator >= 0 { close(iterator) }
            tally.denied = true
            return
        }
        defer { closedir(directory) }

        while let entry = readdir(directory) {
            let name = entryName(entry)
            if name == "." || name == ".." { continue }

            budget -= 1
            tally.nodes += 1
            if budget <= 0 {
                tally.truncated = true
                return
            }
            if Date() >= deadline {
                tally.truncated = true
                return
            }
            if depth == 0, let prefix, !name.hasPrefix(prefix) { continue }

            var info = stat()
            let status = name.withCString {
                fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else { continue }

            let kind = info.st_mode & S_IFMT
            if kind == S_IFDIR {
                if let child = openSubdirectory(fd, name) {
                    scan(
                        fd: child, path: path + "/" + name, prefix: nil, depth: depth + 1,
                        budget: &budget, deadline: deadline, tally: tally
                    )
                    close(child)
                } else if errno == EMFILE || errno == ENFILE {
                    tally.truncated = true
                } else {
                    tally.denied = true
                }
            } else if kind == S_IFREG {
                if info.st_blocks > 0 { tally.bytes += Int64(info.st_blocks) * 512 }
                tally.files += 1
            }
        }
    }

    // MARK: - 删除

    /// 清空目录内容，保留目录本身。`prefix` 只作用于顶层名字。
    static func clear(
        root: String,
        prefix: String?,
        parent: Int32? = nil,
        relative: String? = nil,
        removal: inout Removal
    ) -> Bool {
        var fd: Int32
        if let parent, let relative {
            guard let opened = openSubdirectory(parent, relative) else { return false }
            fd = opened
        } else {
            guard let opened = openDirectory(root) else { return false }
            fd = opened
        }
        defer { close(fd) }
        clear(fd: fd, path: root, prefix: prefix, depth: 0, removal: &removal)
        return true
    }

    static func clear(fd: Int32, path: String, prefix: String?, depth: Int, removal: inout Removal) {
        guard depth <= maxDepth else { return }

        // 先收名字再删：边读边删会让 readdir 跳过条目
        var names: [String] = []
        let iterator = dup(fd)
        guard iterator >= 0, let directory = fdopendir(iterator) else {
            if iterator >= 0 { close(iterator) }
            removal.failures.append("无法列出：\(path)")
            return
        }
        while let entry = readdir(directory) {
            let name = entryName(entry)
            if name == "." || name == ".." { continue }
            if depth == 0, let prefix, !name.hasPrefix(prefix) { continue }
            names.append(name)
        }
        closedir(directory)

        for name in names {
            var info = stat()
            let status = name.withCString {
                fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else { continue }

            let kind = info.st_mode & S_IFMT
            if kind == S_IFDIR {
                if let child = openSubdirectory(fd, name) {
                    clear(fd: child, path: path + "/" + name, prefix: nil, depth: depth + 1, removal: &removal)
                    close(child)
                }
                let result = name.withCString { unlinkat(fd, $0, AT_REMOVEDIR) }
                if result == 0 {
                    removal.directories += 1
                } else if errno != ENOENT {
                    removal.failures.append("目录删不掉：\(path)/\(name)")
                }
            } else {
                let result = name.withCString { unlinkat(fd, $0, 0) }
                if result == 0 {
                    removal.files += 1
                    if info.st_blocks > 0 { removal.bytes += Int64(info.st_blocks) * 512 }
                } else if errno != ENOENT {
                    removal.failures.append("文件删不掉：\(path)/\(name)")
                }
            }
        }
    }

    // MARK: - 工具

    static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        var raw = entry.pointee.d_name
        return withUnsafePointer(to: &raw) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
    }

    // MARK: - getattrlistbulk 的常量与缓冲区布局

    /// 常量直接写数值，避免依赖 Darwin 里那些只在 C 头文件里存在的宏。
    enum Attr {
        /// ATTR_CMN_RETURNED_ATTRS —— 内核实际返回了哪些属性，必须请求，
        /// 否则无法判断某个字段到底在不在缓冲区里。
        static let returned: attrgroup_t = 0x8000_0000
        /// ATTR_CMN_NAME
        static let name: attrgroup_t = 0x0000_0001
        /// ATTR_CMN_OBJTYPE
        static let objectType: attrgroup_t = 0x0000_0008
        /// ATTR_FILE_ALLOCSIZE（按块计的实际占用，等于 st_blocks * 512）
        static let allocSize: attrgroup_t = 0x0000_0004

        /// 每条记录的固定头部：u32 长度（4）+ attribute_set_t（5 × u32，20）
        static let headerSize = 24
        /// 头部之后依次是：名字（attrreference_t，8）、类型（u32，4）、
        /// 占用（i64，8），相邻属性按 4 字节对齐。字段是否存在由
        /// attribute_set_t 的位图决定，所以解析时是动态推进而不是固定偏移。

        static let vreg: UInt32 = 1
        static let vdir: UInt32 = 2
    }

    /// 一条目录项。
    private struct ParsedEntry {
        let name: String
        let kind: UInt32
        let bytes: Int64
    }

    /// 解析 getattrlistbulk 的一条记录。
    ///
    /// 布局：u32 长度 + attribute_set_t（5 × u32）+ 按位序排列的属性值，
    /// 属性值之间 4 字节对齐。名字是 attrreference_t（i32 偏移 + u32 长度，
    /// 偏移相对它自己），占用是 i64，类型是 u32。
    ///
    /// 关键是**按 returned 位图判断字段是否存在**：某个文件系统不返回
    /// ALLOCSIZE 时，硬按固定偏移读会把后面的字节当成大小，数字就全错了。
    private static func parseEntry(_ entry: UnsafeRawPointer, length: Int) -> ParsedEntry? {
        guard length >= Attr.headerSize else { return nil }

        let common = entry.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let file = entry.loadUnaligned(fromByteOffset: 4 + 12, as: UInt32.self)

        var cursor = Attr.headerSize
        var name: String?
        var kind: UInt32 = 0
        var bytes: Int64 = 0

        if common & Attr.name != 0 {
            guard cursor + 8 <= length else { return nil }
            let delta = Int(entry.loadUnaligned(fromByteOffset: cursor, as: Int32.self))
            let byteCount = Int(entry.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self))
            let start = cursor + delta
            if byteCount > 1, start >= 0, start + byteCount <= length {
                let pointer = entry.advanced(by: start).assumingMemoryBound(to: UInt8.self)
                name = String(
                    decoding: UnsafeBufferPointer(start: pointer, count: byteCount - 1),
                    as: UTF8.self
                )
            }
            cursor += 8
        }

        if common & Attr.objectType != 0 {
            guard cursor + 4 <= length else { return nil }
            kind = entry.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
            cursor += 4
        }

        if file & Attr.allocSize != 0 {
            guard cursor + 8 <= length else { return nil }
            bytes = entry.loadUnaligned(fromByteOffset: cursor, as: Int64.self)
            // 读错了偏移才会出现这种值，宁可当作 0 也不要写进统计
            if bytes < 0 || bytes > (1 << 40) { bytes = 0 }
        }

        guard let name, !name.isEmpty else { return nil }
        return ParsedEntry(name: name, kind: kind, bytes: bytes)
    }

    /// getattrlistbulk 的自检结果。算错布局比慢更糟，所以每次启动先拿一个
    /// 内容已知的小目录试跑一遍：条目数、名字、类型、占用四项都对得上才启用。
    enum Bulk {

        private static let lock = NSLock()
        private static var cached: Bool?

        static var usable: Bool {
            lock.lock()
            defer { lock.unlock() }
            if let cached { return cached }
            let result = probe()
            cached = result
            return result
        }

        static func markUnusable() {
            lock.lock()
            cached = false
            lock.unlock()
        }

        private static func probe() -> Bool {
            let manager = FileManager.default
            let root = NSTemporaryDirectory() + "/.pd-bulk-\(UUID().uuidString)"
            defer { try? manager.removeItem(atPath: root) }

            guard (try? manager.createDirectory(atPath: root, withIntermediateDirectories: false)) != nil,
                  manager.createFile(atPath: root + "/a", contents: Data(count: 8192)),
                  manager.createFile(atPath: root + "/b", contents: Data(count: 1)),
                  (try? manager.createDirectory(atPath: root + "/c", withIntermediateDirectories: false)) != nil,
                  manager.createFile(atPath: root + "/c/d", contents: Data(count: 4096))
            else { return false }

            guard let fd = openDirectory(root) else { return false }
            defer { close(fd) }

            var list = attrlist()
            list.bitmapcount = 5
            list.commonattr = Attr.returned | Attr.name | Attr.objectType
            list.fileattr = Attr.allocSize

            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            let count = buffer.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return 0 }
                return getattrlistbulk(fd, &list, base, raw.count, 0)
            }
            guard count == 3 else { return false }

            var names = Set<String>()
            var directories = 0
            var regularFiles = 0
            var bigBytes: Int64 = 0
            var layoutOK = true

            buffer.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { layoutOK = false; return }
                var cursor = 0
                for _ in 0..<Int(count) {
                    guard cursor + Attr.headerSize <= raw.count else { layoutOK = false; return }
                    let length = Int(base.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
                    guard length > Attr.headerSize, cursor + length <= raw.count else {
                        layoutOK = false
                        return
                    }
                    let entry = base.advanced(by: cursor)
                    guard let parsed = parseEntry(entry, length: length) else {
                        layoutOK = false
                        return
                    }
                    names.insert(parsed.name)

                    if parsed.kind == Attr.vdir {
                        directories += 1
                    } else if parsed.kind == Attr.vreg {
                        regularFiles += 1
                        if parsed.name == "a" { bigBytes = parsed.bytes }
                    } else {
                        layoutOK = false
                        return
                    }
                    cursor += length
                }
            }

            guard layoutOK else { return false }
            guard names == Set(["a", "b", "c"]) else { return false }
            guard directories == 1, regularFiles == 2 else { return false }
            // 8192 字节在 APFS 上是两个 4K 块；读错偏移基本不可能同时满足这两个条件
            guard bigBytes >= 8192, bigBytes % 4096 == 0 else { return false }
            return true
        }
    }
}
