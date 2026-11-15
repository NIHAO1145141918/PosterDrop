//
//  DocumentPicker.swift
//  PosterDrop
//
//  用 UIKit 的文件选择器替代 SwiftUI 的 .fileImporter。
//
//  原因：.fileImporter 走的是 open-in-place，加上 allowedContentTypes 里放
//  `.item` 这种抽象根类型时，iOS 27 的文件选择器会把 Downloads / iCloud 里的
//  文件整片置灰——连 .ipa 都点不了，自然没有任何回调，日志里也就没有“开始导入”。
//
//  这里改成：
//  - 内容类型只用 public.data + public.folder（真正能覆盖所有普通文件/文件夹）；
//  - asCopy: true，选择后系统直接把副本放进临时目录，不需要再处理安全作用域；
//  - 保留多选；取消不报错。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DocumentPicker: UIViewControllerRepresentable {

    /// 配对文件一次只要一个，壁纸可以多选。
    var allowsMultipleSelection: Bool = true
    /// 是否允许选文件夹。配对文件用不到，而 `.folder` 会让选择器进入
    /// 文件夹浏览模式，iOS 27 上首屏要多等几秒才显示列表。
    var allowsFolders: Bool = false
    /// 是否把选中文件复制到临时目录。
    ///
    /// 配对文件走 false：iCloud /「文件」里的条目在 asCopy 模式下要先整份下载，
    /// 大文件和弱网时就是几秒白屏。`PairingStore.adopt` 自己会开安全作用域，
    /// 不需要系统代劳复制。
    var copiesFiles: Bool = true
    var onPick: ([URL]) -> Void
    var onCancel: () -> Void = {}

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // public.data 覆盖所有普通文件；不要用 .item——抽象根类型在文件选择器里
        // 会被当成空过滤器，连 .ipa 都点不了。
        var types: [UTType] = [.data]
        if allowsFolders { types.append(.folder) }

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: types,
            asCopy: copiesFiles
        )
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {

        private let parent: DocumentPicker

        init(_ parent: DocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
