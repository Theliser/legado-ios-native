import Foundation
@testable import Legado

// MARK: - 数据模型

/// 每个书源的最低期望。基准只断言「至少能拿到这些」，不比对具体文案 ——
/// 站点改版会换标题，但不会让目录从 1000 章变成 0 章；后者才是引擎出问题。
struct BenchmarkExpectation: Codable, Equatable {
    var minSearchResults: Int = 1
    var minChapters: Int = 1
    var minContentChars: Int = 100
}

/// 一次真实的请求/响应。回放时按 (method, url, body 摘要) 匹配。
struct BenchmarkExchange: Codable {
    var method: String
    var url: String
    /// 请求体原文（表单都很短；超过 4KB 只存摘要）
    var body: String?
    var bodyDigest: String?
    var status: Int
    var headers: [String: String]
    var bodyText: String

    init(spec: HTTPRequestSpec, response: StrResponse) {
        self.method = spec.method.uppercased()
        self.url = spec.url
        let rawBody = spec.body.flatMap { String(data: $0, encoding: .utf8) }
        if let rawBody, rawBody.count <= 4096 {
            self.body = rawBody
            self.bodyDigest = nil
        } else {
            self.body = nil
            self.bodyDigest = rawBody.map { CryptoUtils.md5($0) }
        }
        self.status = response.code
        self.headers = response.headers
        self.bodyText = response.body ?? ""
    }

    func toResponse() -> StrResponse {
        var response = StrResponse(url: url, body: bodyText, code: status)
        response.headers = headers
        return response
    }

    func matches(_ spec: HTTPRequestSpec) -> Bool {
        guard method == spec.method.uppercased(), url == spec.url else { return false }
        let raw = spec.body.flatMap { String(data: $0, encoding: .utf8) }
        if let bodyDigest {
            return CryptoUtils.md5(raw ?? "") == bodyDigest
        }
        if let body {
            return raw == body
        }
        return raw == nil
    }
}

// MARK: - 夹具

struct BenchmarkFixture: Codable {
    var source: BookSource
    var keyword: String
    /// ISO8601 录制时间；用来判断基准多久没刷新
    var recordedAt: String
    var expectation: BenchmarkExpectation
    var exchanges: [BenchmarkExchange]

    var recordedDate: Date? {
        ISO8601DateFormatter().date(from: recordedAt)
    }

    var ageInDays: Int {
        guard let recordedDate else { return .max }
        return Calendar.current.dateComponents([.day], from: recordedDate, to: Date()).day ?? 0
    }

    /// 文件名用域名，便于在仓库里一眼看出是哪个源
    var fileName: String {
        let host = URL(string: source.bookSourceUrl)?.host ?? "unknown"
        let safe = host.replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "_", options: .regularExpression)
        return "bench_\(safe).json"
    }
}

// MARK: - 回放

/// 把录好的响应按顺序喂回去。没命中时返回 599 并记下来 ——
/// 绝不能悄悄放行去连真网，否则「离线基准」就名不副实了。
final class BenchmarkReplayer: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [BenchmarkExchange]]
    private var unmatched: [String] = []

    init(exchanges: [BenchmarkExchange]) {
        var queues: [String: [BenchmarkExchange]] = [:]
        for exchange in exchanges {
            queues[Self.key(method: exchange.method, url: exchange.url), default: []].append(exchange)
        }
        self.queues = queues
    }

    var replay: @Sendable (HTTPRequestSpec) -> StrResponse? {
        { [weak self] spec in self?.take(spec) }
    }

    var missedRequests: [String] {
        lock.lock(); defer { lock.unlock() }
        return unmatched
    }

    private func take(_ spec: HTTPRequestSpec) -> StrResponse? {
        let key = Self.key(method: spec.method, url: spec.url)
        lock.lock()
        defer { lock.unlock() }

        guard var bucket = queues[key], !bucket.isEmpty else {
            unmatched.append("\(spec.method) \(spec.url)")
            return Self.miss(spec)
        }
        // 优先找请求体匹配的那条
        if let index = bucket.firstIndex(where: { $0.matches(spec) }) {
            let exchange = bucket.remove(at: index)
            queues[key] = bucket
            return exchange.toResponse()
        }
        unmatched.append("\(spec.method) \(spec.url)（请求体不匹配）")
        return Self.miss(spec)
    }

    private static func miss(_ spec: HTTPRequestSpec) -> StrResponse {
        var response = StrResponse(url: spec.url,
                                   body: "__BENCHMARK_MISS__ 夹具里没有这个请求：\(spec.method) \(spec.url)",
                                   code: 599)
        response.message = "fixture miss"
        return response
    }

    private static func key(method: String, url: String) -> String {
        "\(method.uppercased()) \(url)"
    }
}

// MARK: - 录制

final class BenchmarkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [BenchmarkExchange] = []

    var record: @Sendable (HTTPRequestSpec, StrResponse) -> Void {
        { [weak self] spec, response in
            guard let self else { return }
            self.lock.lock()
            self.items.append(BenchmarkExchange(spec: spec, response: response))
            self.lock.unlock()
        }
    }

    var exchanges: [BenchmarkExchange] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}
