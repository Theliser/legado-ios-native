import Foundation

/// 书源并发限速，对齐上游 `ConcurrentRateLimiter`。
///
/// `concurrentRate` 的写法：
/// - `"3/1000"`：每 1000ms 内最多访问 3 次
/// - `"1000"`：每 1000ms 内最多访问 1 次（等价 `1/1000`）
/// - 空 / `"0"`：不限速
///
/// 记录按书源 key 全局共享（不是每个请求各一份），否则限速形同虚设。
final class ConcurrentRateLimiter: @unchecked Sendable {

    struct Record {
        var time: Int64
        var accessLimit: Int
        var interval: Int
        var frequency: Int
    }

    static let shared = ConcurrentRateLimiter()

    private var records: [String: Record] = [:]
    private let lock = NSLock()

    init() {}

    /// 等待直到允许访问。返回实际等待的毫秒数，便于测试与日志。
    @discardableResult
    func acquire(key: String?, concurrentRate: String?) async -> Int64 {
        guard let key, !key.isEmpty,
              let rate = concurrentRate?.trimmingCharacters(in: .whitespaces),
              !rate.isEmpty, rate != "0" else { return 0 }

        var waited: Int64 = 0
        while true {
            let wait = tryAcquire(key: key, rate: rate)
            if wait <= 0 { return waited }
            waited += wait
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
        }
    }

    /// 同步版，供 JS 里的 `java.ajax` 这类阻塞调用使用
    func acquireBlocking(key: String?, concurrentRate: String?) {
        guard let key, !key.isEmpty,
              let rate = concurrentRate?.trimmingCharacters(in: .whitespaces),
              !rate.isEmpty, rate != "0" else { return }
        while true {
            let wait = tryAcquire(key: key, rate: rate)
            if wait <= 0 { return }
            Thread.sleep(forTimeInterval: Double(wait) / 1000)
        }
    }

    /// 立即尝试。返回 0 表示放行，>0 表示还需等待的毫秒数。
    func tryAcquire(key: String, rate: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }

        guard var record = records[key] else {
            // 首次访问一定放行（与上游 computeIfAbsent 分支一致）
            var fresh = Self.parse(rate)
            fresh.frequency = 1
            records[key] = fresh
            return 0
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let nextTime = record.time + Int64(record.interval)

        if now >= nextTime {
            // 已过限制窗口，重置计数
            record.time = now
            record.frequency = 1
            records[key] = record
            return 0
        }
        if record.frequency < record.accessLimit {
            record.frequency += 1
            records[key] = record
            return 0
        }
        return nextTime - now
    }

    /// 书源 concurrentRate 变化时刷新限制参数（保留已有计数，与上游一致）
    func updateRate(key: String, concurrentRate: String) {
        lock.lock()
        defer { lock.unlock() }
        let parsed = Self.parse(concurrentRate)
        var record = records[key] ?? parsed
        record.accessLimit = parsed.accessLimit
        record.interval = parsed.interval
        if records[key] == nil { record.frequency = 0 }
        records[key] = record
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll()
    }

    func record(for key: String) -> Record? {
        lock.lock()
        defer { lock.unlock() }
        return records[key]
    }

    /// 解析 `"3/1000"` / `"1000"`；非法值退化成「不限速」以外的安全默认（1 次/窗口）
    static func parse(_ rate: String) -> Record {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let text = rate.trimmingCharacters(in: .whitespaces)
        if let index = text.firstIndex(of: "/") {
            let left = Int(text[text.startIndex..<index]) ?? 1
            let right = Int(text[text.index(after: index)...]) ?? 0
            if left > 0, right > 0 {
                return Record(time: now, accessLimit: left, interval: right, frequency: 0)
            }
        } else if let value = Int(text), value > 0 {
            return Record(time: now, accessLimit: 1, interval: value, frequency: 0)
        }
        // 非法写法：不限速
        return Record(time: now, accessLimit: Int.max, interval: 0, frequency: 0)
    }
}
