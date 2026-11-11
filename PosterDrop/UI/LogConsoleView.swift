//
//  LogConsoleView.swift
//  PosterDrop
//
//  等宽字体日志窗口，自动滚到底部。
//

import SwiftUI

struct LogConsoleView: View {

    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if lines.isEmpty {
                        Text("暂无日志。执行导入 / 应用 / 探测后会在这里输出。")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.45))
                            .padding(.vertical, 6)
                    }

                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index])
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(color(for: lines[index]))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.06, green: 0.06, blue: 0.09))
            )
            .onChange(of: lines.count) { _, newValue in
                guard newValue > 0 else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newValue - 1, anchor: .bottom)
                }
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.contains("❌") || line.contains("失败") || line.contains("error") {
            return Color(red: 1.0, green: 0.45, blue: 0.45)
        }
        if line.contains("⚠️") || line.contains("跳过") || line.contains("警告") {
            return Color(red: 1.0, green: 0.78, blue: 0.40)
        }
        if line.contains("🎉") || line.contains("✅") || line.contains("✓") || line.contains("成功") {
            return Color(red: 0.45, green: 0.92, blue: 0.62)
        }
        return Color.white.opacity(0.82)
    }
}
