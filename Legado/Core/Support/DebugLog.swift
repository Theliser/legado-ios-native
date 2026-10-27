import Foundation

/// 书源调试日志级别（对齐上游 Debug.log 的 state 语义）
enum DebugLogState: Int {
    case message = 0
    case searchResult = 10
    case bookInfo = 20
    case toc = 30
    case content = 40
}

struct DebugLogEntry: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let tag: String
    let message: String
    let state: Int

    var timeText: String {
        DebugLog.timeFormatter.string(from: date)
    }
}

/// 全局的解析日志环形缓冲。书源调试页与解析链路共用。
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private let lock = NSLock()
    private var buffer: [DebugLogEntry] = []
    private let capacity = 2000

    /// 是否捕获日志。关闭时不占用内存。
    var enabled: Bool = true

    private init() {}

    func log(_ tag: String?, _ message: String, state: Int = 0) {
        guard enabled else { return }
        let entry = DebugLogEntry(
            date: Date(),
            tag: tag ?? "",
            message: message,
            state: state
        )
        lock.lock()
        buffer.append(entry)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        lock.unlock()

        #if DEBUG
        print("[\(tag ?? "-")] \(message)")
        #endif
    }

    func snapshot() -> [DebugLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }
}
