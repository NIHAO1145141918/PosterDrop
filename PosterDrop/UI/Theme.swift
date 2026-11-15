//
//  Theme.swift
//  PosterDrop
//
//  统一的视觉元素：配色、卡片、横幅、进度条。
//

import SwiftUI
import UIKit

enum Theme {

    static let accent = Color(red: 0.47, green: 0.32, blue: 0.96)

    static let accentGradient = LinearGradient(
        colors: [
            Color(red: 0.42, green: 0.28, blue: 0.95),
            Color(red: 0.83, green: 0.36, blue: 0.78)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let kindColors: [Color] = [
        Color(red: 0.45, green: 0.36, blue: 0.95),
        Color(red: 0.85, green: 0.36, blue: 0.62),
        Color(red: 0.20, green: 0.60, blue: 0.90),
        Color(red: 0.95, green: 0.55, blue: 0.25),
        Color(red: 0.25, green: 0.72, blue: 0.55),
        Color(red: 0.45, green: 0.48, blue: 0.56)
    ]

    static func kindColor(_ kind: PosterKind) -> Color {
        return kindColors[min(kind.tintIndex, kindColors.count - 1)]
    }
}

// MARK: - 设备文案

enum DeviceLabel {
    /// 用于「文件 › 我的 iPhone / iPad › PosterDrop」这类系统路径提示。
    static var deviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    static var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

}

// MARK: - 卡片

struct CardBackground: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

// MARK: - 页面背景

struct ScreenBackground: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            LinearGradient(
                colors: [Theme.accent.opacity(0.18), Theme.accent.opacity(0.0)],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - 大屏版心

/// 把整页内容收进一条可读宽度内并居中。
///
/// iPhone 上不生效（屏幕本来就窄）；iPad 竖屏、横屏、分屏、Stage Manager
/// 任意窗口宽度下都不会把卡片拉成一条超长的横条。
struct ReadableColumn: ViewModifier {
    var maxWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension View {
    /// - Parameter maxWidth: 版心最大宽度，默认 760pt（iPad 竖屏正好双列卡片）。
    func readableColumn(_ maxWidth: CGFloat = 760) -> some View {
        modifier(ReadableColumn(maxWidth: maxWidth))
    }
}

/// 壁纸列表列数：宽屏自动双列，窄屏（iPhone / iPad 窄分屏）自动单列。
enum GalleryLayout {
    static let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 340, maximum: .infinity), spacing: 12, alignment: .top)
    ]
}

// MARK: - 横幅

struct BannerView: View {
    let banner: Banner
    let onClose: () -> Void

    private var color: Color {
        switch banner.kind {
        case .success:
            return Color(red: 0.18, green: 0.66, blue: 0.42)
        case .error:
            return Color(red: 0.86, green: 0.24, blue: 0.28)
        case .info:
            return Theme.accent
        }
    }

    private var iconName: String {
        switch banner.kind {
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .info:
            return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(color)

            Text(banner.message)
                .font(.footnote)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(color.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - 进度卡

struct WorkProgressCard: View {
    let title: String
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
            }
            ProgressView(value: max(0, min(1, progress)))
                .tint(Theme.accent)
        }
        .card()
    }
}

// MARK: - 小标签

struct KindBadge: View {
    let kind: PosterKind

    var body: some View {
        Text(kind.title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.kindColor(kind).opacity(0.16)))
            .foregroundColor(Theme.kindColor(kind))
    }
}

// MARK: - 键值行

struct InfoRow: View {
    let title: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .footnote)
                .foregroundColor(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }
}
