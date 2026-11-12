//
//  PosterDropError.swift
//  PosterDrop
//
//  统一的业务错误类型。以前叫 PosterDropError（底层是 Rust 隧道），
//  现在底层只剩 worse_query 沙箱扩展，名字也跟着改掉。
//

import Foundation

struct PosterDropError: LocalizedError, Equatable {

    let message: String

    init(_ message: String) {
        self.message = message
    }

    static func failed(_ message: String) -> PosterDropError {
        PosterDropError(message)
    }

    var errorDescription: String? { message }
}
