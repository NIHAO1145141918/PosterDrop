//
//  LogBus.swift
//  PosterDrop
//
//  全局日志总线。Rust 回调可能来自任意线程，统一切回主线程再发布。
//

import Foundation

final class LogBus: ObservableObject {

    static let shared = LogBus()

    @Published private(set) var lines: [String] = []

    private let maxLines = 1200

    func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        DispatchQueue.main.async {
            self.lines.append(trimmed)
            if self.lines.count > self.maxLines {
                self.lines.removeFirst(self.lines.count - self.maxLines)
            }
        }
    }

    func append(contentsOf newLines: [String]) {
        DispatchQueue.main.async {
            self.lines.append(contentsOf: newLines)
            if self.lines.count > self.maxLines {
                self.lines.removeFirst(self.lines.count - self.maxLines)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.lines.removeAll()
        }
    }

    func exportText() -> String {
        return lines.joined(separator: "\n")
    }
}
