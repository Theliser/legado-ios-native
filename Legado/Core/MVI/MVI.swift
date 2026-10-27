import Foundation
import SwiftUI

/// MVI 基座：State（唯一事实来源）→ Intent（用户/系统事件）→ Reducer（异步处理）→ 回写 State。
/// 视图只读 `state`、只发 `send(_:)`，不直接持有业务逻辑。
@MainActor
protocol MVIViewModel: AnyObject {
    associatedtype State
    associatedtype Intent
    var state: State { get }
    func send(_ intent: Intent)
}

/// 统一的消息提示（Toast / 错误）
struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError: Bool = false
}

extension View {
    func toast(_ message: Binding<ToastMessage?>) -> some View {
        overlay(alignment: .top) {
            if let value = message.wrappedValue {
                Text(value.text)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(value.isError ? Color.red.opacity(0.25) : Theme.accent.opacity(0.25)),
                                 in: .capsule)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: value.id) {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        withAnimation { message.wrappedValue = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.32), value: message.wrappedValue)
    }
}
