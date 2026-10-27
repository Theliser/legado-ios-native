import Foundation

// MARK: - 状态

/// 巡检结论。取值与上游 `CheckSourceStatus` 同名，方便对照。
enum CheckStatus: String, CaseIterable, Identifiable {
    case passed = "PASSED"
    case failed = "FAILED"
    case uncheckable = "UNCHECKABLE"
    case notCompleted = "NOT_COMPLETED"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .passed: return "通过"
        case .failed: return "失败"
        case .uncheckable: return "无法校验"
        case .notCompleted: return "未完成"
        }
    }

    var symbol: String {
        switch self {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .uncheckable: return "questionmark.circle.fill"
        case .notCompleted: return "clock.badge.exclamationmark.fill"
        }
    }

    /// 落到书源分组上的名字（对齐上游 `addGroup("搜索失效")` 那一套）
    var isFailure: Bool { self == .failed || self == .notCompleted }
}

/// 失效分组的固定名字。巡检会把它们写回书源的 `bookSourceGroup`，
/// 这样用户可以直接按「校验超时」「网站失效」筛出坏源。
enum CheckGroup {
    static let domain = "域名失效"
    static let search = "搜索失效"
    static let searchInfo = "搜索详情失效"
    static let searchToc = "搜索目录失效"
    static let searchContent = "搜索正文失效"
    static let discover = "发现失效"
    static let timeout = "校验超时"
    static let site = "网站失效"
    static let js = "js失效"

    static let all = [domain, search, searchInfo, searchToc, searchContent,
                      discover, timeout, site, js]
}

enum SourceCheckError: LocalizedError {
    case timeout(seconds: Double)

    var errorDescription: String? {
        switch self {
        case .timeout(let seconds): return "校验超时（\(Int(seconds))s）"
        }
    }
}

// MARK: - 配置

/// 巡检配置（对齐上游 `CheckSource` 里那几个可配置开关）
struct SourceCheckConfig: Equatable {
    var keyword: String = "我的"
    /// 单个书源的总超时（上游默认 180s）
    var timeout: Double = 180
    var checkSearch = true
    var checkInfo = true
    var checkToc = true
    var checkContent = true
    /// 并发数（上游 threadCount）
    var concurrency = 3

    private enum Keys {
        static let keyword = "check.keyword"
        static let timeout = "check.timeout"
        static let search = "check.search"
        static let info = "check.info"
        static let toc = "check.toc"
        static let content = "check.content"
        static let concurrency = "check.concurrency"
    }

    static func load(from defaults: UserDefaults = .standard) -> SourceCheckConfig {
        var config = SourceCheckConfig()
        if let value = defaults.string(forKey: Keys.keyword), !value.isEmpty {
            config.keyword = value
        }
        if defaults.object(forKey: Keys.timeout) != nil {
            config.timeout = defaults.double(forKey: Keys.timeout)
        }
        if defaults.object(forKey: Keys.concurrency) != nil {
            config.concurrency = max(1, min(8, defaults.integer(forKey: Keys.concurrency)))
        }
        config.checkSearch = defaults.object(forKey: Keys.search) as? Bool ?? true
        config.checkInfo = defaults.object(forKey: Keys.info) as? Bool ?? true
        config.checkToc = defaults.object(forKey: Keys.toc) as? Bool ?? true
        config.checkContent = defaults.object(forKey: Keys.content) as? Bool ?? true
        return config
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(keyword, forKey: Keys.keyword)
        defaults.set(timeout, forKey: Keys.timeout)
        defaults.set(checkSearch, forKey: Keys.search)
        defaults.set(checkInfo, forKey: Keys.info)
        defaults.set(checkToc, forKey: Keys.toc)
        defaults.set(checkContent, forKey: Keys.content)
        defaults.set(concurrency, forKey: Keys.concurrency)
    }

    /// 「180s 搜索 详情 目录 正文」这样的一句话摘要
    var summary: String {
        var items: [String] = []
        if checkSearch { items.append("搜索") }
        if checkInfo { items.append("详情") }
        if checkToc { items.append("目录") }
        if checkContent { items.append("正文") }
        return "\(Int(timeout))s " + (items.isEmpty ? "（未选择校验项）" : items.joined(separator: " "))
    }
}

// MARK: - 结果

struct SourceCheckResult: Identifiable, Equatable {
    let sourceUrl: String
    var sourceName: String
    var status: CheckStatus
    var detail: String
    var elapsedMs: Int
    /// 各阶段的请求回显，展开可看原始响应
    var traces: [SourceTrace] = []

    var id: String { sourceUrl }

    var elapsedText: String {
        elapsedMs < 1000 ? "\(elapsedMs)ms" : String(format: "%.1fs", Double(elapsedMs) / 1000)
    }
}

// MARK: - 巡检器

/// 书源巡检：按配置跑「搜索 → 详情 → 目录 → 正文」，产出三态结论。
/// 与上游 `CheckSourceService` 对齐的点：
/// - 源地址不是 http(s) → UNCHECKABLE，而不是 FAILED
/// - 阶段失败不立刻中断，而是记「失效分组」后继续（搜索失败除外，没有书可继续）
/// - 超时、站点失效、JS 异常分别落到不同分组
@MainActor
final class SourceChecker {
    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
    }

    /// 批量巡检。`onResult` 每完成一个回调一次，便于边跑边显示。
    func check(_ sources: [BookSource], config: SourceCheckConfig,
               onResult: @escaping @MainActor (SourceCheckResult) -> Void) async {
        let limit = max(1, min(8, config.concurrency))
        var iterator = sources.makeIterator()
        var running = 0

        await withTaskGroup(of: SourceCheckResult.self) { group in
            while running < limit, let source = iterator.next() {
                group.addTask { await self.checkOne(source, config: config) }
                running += 1
            }

            while let result = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                running -= 1
                onResult(result)
                if let source = iterator.next() {
                    group.addTask { await self.checkOne(source, config: config) }
                    running += 1
                }
            }
        }
    }

    func checkOne(_ source: BookSource, config: SourceCheckConfig) async -> SourceCheckResult {
        let started = Date()
        var source = source

        // 源地址不是 http(s) 时无从校验，上游为此单独设了 UNCHECKABLE
        guard let scheme = URL(string: source.bookSourceUrl)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return result(source, .uncheckable, "源地址不是 http 链接", started, [])
        }

        let collector = TraceCollector()
        // 每个书源独立 WebBook 实例，避免并发巡检时 trace 串台
        let webBook = WebBook(settings: container.settings,
                              httpClient: container.httpClient,
                              cookieStore: container.cookieStore,
                              bookRepository: container.bookRepository)
        webBook.trace = { collector.append($0) }

        let outcome: StageOutcome
        do {
            outcome = try await withTimeout(config.timeout) {
                try await self.runStages(source, config: config, webBook: webBook)
            }
        } catch let error as SourceCheckError {
            outcome = StageOutcome(status: .failed, detail: error.localizedDescription,
                                   groups: [CheckGroup.timeout])
        } catch is CancellationError {
            outcome = StageOutcome(status: .notCompleted, detail: "已取消", groups: [])
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            outcome = StageOutcome(status: .failed, detail: text, groups: classify(error))
        }

        let traces = collector.snapshot()
        writeBack(&source, outcome: outcome, elapsedMs: ms(since: started))
        return result(source, outcome.status, outcome.detail, started, traces)
    }

    // MARK: - 阶段

    private struct StageOutcome {
        var status: CheckStatus
        var detail: String
        var groups: [String]
    }

    private func runStages(_ source: BookSource, config: SourceCheckConfig,
                           webBook: WebBook) async throws -> StageOutcome {
        var groups: [String] = []
        var book: Book?
        var ranAny = false

        if config.checkSearch {
            ranAny = true
            let keyword = source.getCheckKeyWord(default: config.keyword)
            let searchUrl = source.searchUrl ?? ""
            guard source.isJsSource || !searchUrl.isBlank else {
                return StageOutcome(status: .failed, detail: CheckGroup.search + "：搜索链接规则为空",
                                    groups: [CheckGroup.search])
            }
            let books = try await webBook.searchBook(source, key: keyword)
            guard let first = books.first else {
                return StageOutcome(status: .failed, detail: "\(CheckGroup.search)：无结果", groups: [CheckGroup.search])
            }
            book = first.toBook()
        }

        if let current = book {
            // 详情
            if config.checkInfo {
                ranAny = true
                if current.tocUrl.isBlank {
                    let detailed = try await webBook.getBookInfo(source, book: current)
                    book = detailed
                    if detailed.name.isBlank { groups.append(CheckGroup.searchInfo) }
                }
            }

            let target = book ?? current
            // 目录
            if config.checkToc, !BookType.has(source.bookType, BookType.webFile) {
                ranAny = true
                do {
                    let chapters = try await webBook.getChapterList(source, book: target)
                    let readable = chapters
                        .filter { !($0.isVolume && $0.url.hasPrefix($0.title)) }
                        .prefix(2)
                    guard let chapter = readable.first else {
                        groups.append(CheckGroup.searchToc)
                        return StageOutcome(status: .failed,
                                            detail: CheckGroup.searchToc + "：目录为空", groups: groups)
                    }
                    // 正文
                    if config.checkContent {
                        let next = readable.count > 1 ? readable[1].url : chapter.url
                        let content = try await webBook.getContent(source, book: target,
                                                                   chapter: chapter,
                                                                   nextChapterUrl: next,
                                                                   needSave: false)
                        if content.isBlank { groups.append(CheckGroup.searchContent) }
                    }
                } catch let error as WebBookError {
                    switch error {
                    case .emptyToc:
                        groups.append(CheckGroup.searchToc)
                    case .emptyContent:
                        groups.append(CheckGroup.searchContent)
                    case .message(let text):
                        throw WebBookError.message(text)
                    }
                }
            }
        }

        if groups.isEmpty {
            return StageOutcome(status: .passed,
                                detail: ranAny ? "校验成功" : "未选择校验项",
                                groups: [])
        }
        return StageOutcome(status: .failed, detail: groups.joined(separator: " | "), groups: groups)
    }

    // MARK: - 写回

    /// 把结论写回书源：响应时间 + 失效分组。
    /// 通过时清掉旧的失效分组，否则用户修好书源后分组还挂着。
    private func writeBack(_ source: inout BookSource, outcome: StageOutcome, elapsedMs: Int) {
        source.respondTime = Int64(elapsedMs)
        switch outcome.status {
        case .passed:
            source.removeGroup(CheckGroup.all.joined(separator: ","))
        case .failed, .notCompleted:
            for group in outcome.groups { source.addGroup(group) }
        case .uncheckable:
            break
        }
        container.bookSourceRepository.save(source)
    }

    private func classify(_ error: Error) -> [String] {
        if error is SourceCheckError { return [CheckGroup.timeout] }
        // JS 侧异常通常以文本形式抛出，按上游粗分到 js 失效
        let text = "\(error)"
        if text.contains("JS") || text.contains("Script") || text.contains("javascript") {
            return [CheckGroup.js]
        }
        return [CheckGroup.site]
    }

    private func result(_ source: BookSource, _ status: CheckStatus, _ detail: String,
                        _ started: Date, _ traces: [SourceTrace]) -> SourceCheckResult {
        SourceCheckResult(sourceUrl: source.bookSourceUrl,
                          sourceName: source.bookSourceName,
                          status: status, detail: detail,
                          elapsedMs: ms(since: started), traces: traces)
    }

    private func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}

// MARK: - 超时

/// 给单个书源套总超时。Swift 没有内置的 withTimeout，
/// 这里用 TaskGroup 让「干活」和「计时」赛跑。
private func withTimeout<T>(_ seconds: Double,
                            _ work: @escaping () async throws -> T) async throws -> T {
    guard seconds > 0 else { return try await work() }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw SourceCheckError.timeout(seconds: seconds)
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else {
            throw SourceCheckError.timeout(seconds: seconds)
        }
        return value
    }
}

// MARK: - trace 收集

/// 并发巡检时各书源各用一份，互不干扰。
final class TraceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SourceTrace] = []

    func append(_ event: SourceTrace) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [SourceTrace] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
