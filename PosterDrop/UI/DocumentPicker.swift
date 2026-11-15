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
//  - 内容类型用 public.data 打底，再并上 property-list / xml 两个明确的类型；
//  - asCopy: true，选择后系统直接把副本放进临时目录，不需要再处理安全作用域；
//  - 保留多选；取消不报错。
//
//  关于 asCopy：**不能用 false**。open-in-place 模式下，App 没有在
//  CFBundleDocumentTypes 里声明过的类型会被整片置灰——`.plist` 正好命中这个坑，
//  表现就是「文件看得见、点不动」。导入副本没有这个限制，而且配对文件只有几百
//  字节，复制开销可以忽略。
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
    /// 保持 true。false（open-in-place）会让没有在 App 里声明过的类型变灰，
    /// `.plist` 就是其中之一——用户看到的就是「点不动文件」。
    var copiesFiles: Bool = true
    var onPick: ([URL]) -> Void
    var onCancel: () -> Void = {}

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // public.data 覆盖所有普通文件；不要用 .item——抽象根类型在文件选择器里
        // 会被当成空过滤器，连 .ipa 都点不了。
        // propertyList / xml 是给 `.plist` 兜底的：某些系统版本里它的 UTI 解析成
        // com.apple.property-list 后不再被当成 public.data 的直接子类型，
        // 只写 .data 会让文件变灰。多列两个显式类型不会放宽到不该选的东西。
        var types: [UTType] = [.data, .propertyList, .xml]
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
