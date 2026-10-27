import SwiftUI

enum Theme {
    static let accent = Color(red: 0.36, green: 0.42, blue: 0.95)
    static let accentSoft = Color(red: 0.55, green: 0.48, blue: 0.98)

    static var coverPalette: [Color] {
        [
            Color(red: 0.45, green: 0.52, blue: 0.95),
            Color(red: 0.85, green: 0.52, blue: 0.45),
            Color(red: 0.35, green: 0.66, blue: 0.58),
            Color(red: 0.72, green: 0.48, blue: 0.75),
            Color(red: 0.42, green: 0.60, blue: 0.78)
        ]
    }

    static func coverColor(_ seed: String) -> Color {
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return coverPalette[Int(hash % UInt64(coverPalette.count))]
    }

    static func coverGradient(_ seed: String) -> LinearGradient {
        let base = coverColor(seed)
        return LinearGradient(colors: [base.opacity(0.95), base.opacity(0.55)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// 液态玻璃卡片
struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 24
    var tint: Color? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if let tint {
            content
                .glassEffect(.regular.tint(tint.opacity(0.18)).interactive(), in: shape)
        } else {
            content
                .glassEffect(.regular, in: shape)
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 24, tint: Color? = nil) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, tint: tint))
    }
}

/// 全屏动态背景，为玻璃提供折射纹理
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if scheme == .dark {
                MeshGradient(width: 3, height: 3, points: [
                    .init(0, 0), .init(0.5, 0), .init(1, 0),
                    .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
                    .init(0, 1), .init(0.5, 1), .init(1, 1)
                ], colors: [
                    Color(red: 0.07, green: 0.08, blue: 0.14),
                    Color(red: 0.10, green: 0.10, blue: 0.19),
                    Color(red: 0.06, green: 0.09, blue: 0.16),
                    Color(red: 0.12, green: 0.10, blue: 0.22),
                    Color(red: 0.09, green: 0.11, blue: 0.20),
                    Color(red: 0.07, green: 0.10, blue: 0.17),
                    Color(red: 0.05, green: 0.07, blue: 0.12),
                    Color(red: 0.09, green: 0.08, blue: 0.16),
                    Color(red: 0.06, green: 0.08, blue: 0.13)
                ])
            } else {
                MeshGradient(width: 3, height: 3, points: [
                    .init(0, 0), .init(0.5, 0), .init(1, 0),
                    .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
                    .init(0, 1), .init(0.5, 1), .init(1, 1)
                ], colors: [
                    Color(red: 0.95, green: 0.94, blue: 0.99),
                    Color(red: 0.93, green: 0.95, blue: 1.00),
                    Color(red: 0.97, green: 0.94, blue: 0.96),
                    Color(red: 0.94, green: 0.96, blue: 1.00),
                    Color(red: 0.98, green: 0.97, blue: 0.99),
                    Color(red: 0.95, green: 0.94, blue: 1.00),
                    Color(red: 0.97, green: 0.95, blue: 0.94),
                    Color(red: 0.94, green: 0.95, blue: 0.99),
                    Color(red: 0.96, green: 0.96, blue: 1.00)
                ])
            }
        }
        .ignoresSafeArea()
    }
}

/// 统一的空状态
struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
    }
}
