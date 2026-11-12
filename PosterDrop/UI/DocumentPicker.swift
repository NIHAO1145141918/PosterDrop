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

    var onPick: ([URL]) -> Void
    var onCancel: () -> Void = {}

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // public.data 覆盖所有普通文件；public.folder 让“打开文件夹”可用。
        // 不要用 .item：抽象根类型在文件选择器里会被当成空过滤器。
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.data, .folder],
            asCopy: true
        )
        picker.allowsMultipleSelection = true
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
