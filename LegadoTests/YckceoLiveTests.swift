import XCTest
@testable import Legado

/// 真实书源联网体检：从阅读源仓库（yckceo）抓下来的最近批次书源。
/// 默认跳过；`TEST_RUNNER_RUN_YCKCEO_LIVE=1` 才跑。
final class YckceoLiveTests: XCTestCase {

    private struct StageResult {
        var stage: String
        var ok: Bool
        var detail: String
        var ms: Int
    }

    private struct SourceResult {
        var name: String
        var url: String
        var stages: [StageResult] = []
        var passed: Bool { stages.allSatisfy(\.ok) && !stages.isEmpty }
        var failedStage: String? { stages.first(where: { !$0.ok })?.stage }
        var summary: String {
            stages.map { "\($0.stage)\($0.ok ? "✓" : "✗")" }.joined(separator: " ")
        }
    }

    private final class Sandbox {
        let db: AppDatabase
        let settings: AppSettings
        let cookieStore: CookieStore
        let client: HTTPClient
        let webBook: WebBook
        private let suiteName: String
        private let defaults: UserDefaults

        init() throws {
            db = try AppDatabase(inMemory: true)
            suiteName = "yckceo.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            settings = AppSettings(defaults: defaults)
            cookieStore = CookieStore(dao: CookieDao(db: db))
            client = HTTPClient(settings: settings, cookieStore: cookieStore)
            webBook = WebBook(settings: settings, httpClient: client,
                              cookieStore: cookieStore,
                              bookRepository: BookRepository(db: db, settings: settings),
                              chapterCache: ChapterCache(root: FileManager.default.temporaryDirectory
                                .appendingPathComponent("yckceo-cache-\(UUID().uuidString)")))
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["RUN_YCKCEO_LIVE"] == "1"
    }

    private var poolDirectory: URL {
        BenchmarkStorage.repoRoot
            .appendingPathComponent(".context/live-sources", isDirectory: true)
    }

    func testRecentYckceoSources() async throws {
        guard enabled else {
            throw XCTSkip("联网体检：TEST_RUNNER_RUN_YCKCEO_LIVE=1")
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: poolDirectory, includingPropertiesForKeys: nil)) ?? []
        let entries = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (Int, BookSource)? in
                guard let data = try? Data(contentsOf: url),
                      let source = try? JSONDecoder().decode(BookSource.self, from: data)
                else { return nil }
                let id = Int(url.lastPathComponent.split(separator: "_").first ?? "") ?? 0
                return (id, source)
            }
            .filter { $0.1.bookSourceType == 0 }
            // yckceo 的 ID 越大越新
            .sorted { $0.0 > $1.0 }
        let sources = entries.map(\.1)
        guard !sources.isEmpty else {
            throw XCTSkip("没有候选书源，先跑 scripts/harvest-yckceo-sources.py")
        }

        var results: [SourceResult] = []
        let limit = Int(ProcessInfo.processInfo.environment["YCKCEO_LIMIT"] ?? "") ?? sources.count
        for source in sources.prefix(limit) {
            let result = await check(source)
            results.append(result)
        }

        print("\n========== 阅读源仓库最近书源体检 ==========")
        for result in results {
            let mark = result.passed ? "✓" : "✗"
            print("\(mark) \(result.name)  \(result.summary)")
            for stage in result.stages where !stage.ok {
                print("    \(stage.stage) \(stage.ms)ms → \(stage.detail)")
            }
        }
        let passed = results.filter(\.passed).count
        print("完整跑通 \(passed)/\(results.count)")
        print("==========================================")
        XCTAssertGreaterThan(passed, 0, "至少应有一个最近书源完整跑通")
    }

    private func check(_ source: BookSource) async -> SourceResult {
        var result = SourceResult(name: source.bookSourceName, url: source.bookSourceUrl)
        do {
            let sandbox = try Sandbox()
            let preferred = source.getCheckKeyWord(default: "剑来")
            var keywords = [preferred, "剑来", "诡秘之主"]
            var seenKeywords = Set<String>()
            keywords = keywords.filter { seenKeywords.insert($0).inserted }
            var books: [SearchBook] = []
            var searchMs = 0
            var searchText = "无结果"
            for keyword in keywords {
                let started = Date()
                do {
                    books = try await withTimeout(seconds: 40) {
                        try await sandbox.webBook.searchBook(source, key: keyword)
                    }
                    searchMs = ms(since: started)
                    if !books.isEmpty { break }
                    searchText = "关键字「\(keyword)」无结果"
                } catch {
                    // 超时 / 域名不通 / 403 之类，换关键字也不会好，直接结束
                    searchMs = ms(since: started)
                    searchText = "\(error.localizedDescription)"
                    break
                }
            }
            let searchOK = !books.isEmpty
            result.stages.append(StageResult(stage: "搜索", ok: searchOK,
                                             detail: searchOK ? "\(books.count) 条" : searchText,
                                             ms: searchMs))
            guard searchOK, let first = books.first else { return result }
            var book = first.toBook()
            book.type = source.bookType

            let infoStarted = Date()
            do {
                book = try await withTimeout(seconds: 45) {
                    try await sandbox.webBook.getBookInfo(source, book: book)
                }
                result.stages.append(StageResult(stage: "详情", ok: true,
                                                 detail: "《\(book.name)》", ms: ms(since: infoStarted)))
            } catch {
                result.stages.append(StageResult(stage: "详情", ok: false,
                                                 detail: error.localizedDescription,
                                                 ms: ms(since: infoStarted)))
                return result
            }

            let tocStarted = Date()
            var chapters: [BookChapter] = []
            do {
                chapters = try await withTimeout(seconds: 45) {
                    try await sandbox.webBook.getChapterList(source, book: book)
                }
                result.stages.append(StageResult(stage: "目录", ok: !chapters.isEmpty,
                                                 detail: "\(chapters.count) 章",
                                                 ms: ms(since: tocStarted)))
            } catch {
                result.stages.append(StageResult(stage: "目录", ok: false,
                                                 detail: error.localizedDescription,
                                                 ms: ms(since: tocStarted)))
                return result
            }
            guard let chapter = chapters.first(where: { !$0.isVolume }) else { return result }

            let contentStarted = Date()
            do {
                let content = try await withTimeout(seconds: 60) {
                    try await sandbox.webBook.getContent(source, book: book, chapter: chapter,
                                                         needSave: false)
                }
                result.stages.append(StageResult(stage: "正文", ok: !content.isBlank,
                                                 detail: "\(content.count) 字",
                                                 ms: ms(since: contentStarted)))
            } catch {
                result.stages.append(StageResult(stage: "正文", ok: false,
                                                 detail: error.localizedDescription,
                                                 ms: ms(since: contentStarted)))
            }
        } catch {
            result.stages.append(StageResult(stage: "初始化", ok: false,
                                             detail: error.localizedDescription, ms: 0))
        }
        return result
    }

    private func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private struct TimeoutError: LocalizedError {
        var errorDescription: String? { "超时" }
    }

    private func withTimeout<T>(seconds: Int,
                                _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw TimeoutError()
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}
