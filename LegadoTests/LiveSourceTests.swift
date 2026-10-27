import XCTest
@testable import Legado

/// 真实书源端到端验证（会联网）。
///
/// 默认跳过，避免日常跑测试时被网络拖慢/弄挂：
/// ```
/// RUN_LIVE_TESTS=1 xcodebuild test -only-testing:LegadoTests/LiveSourceTests ...
/// ```
final class LiveSourceTests: XCTestCase {

    private var db: AppDatabase!
    private var settings: AppSettings!
    private var cookieStore: CookieStore!
    private var webBook: WebBook!

    /// 一批常见书名，任一命中就算这次搜索成功
    private let keywords = ["剑来", "斗破苍穹", "诡秘之主", "凡人修仙传"]

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(inMemory: true)
        let suite = "test.live.\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        cookieStore = CookieStore(dao: CookieDao(db: db))
        let client = HTTPClient(settings: settings, cookieStore: cookieStore)
        webBook = WebBook(settings: settings, httpClient: client,
                          cookieStore: cookieStore,
                          bookRepository: BookRepository(db: db, settings: settings))
    }

    func testLiveSourcesEndToEnd() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_TESTS"] == "1" else {
            throw XCTSkip("联网测试：设置 RUN_LIVE_TESTS=1 才执行")
        }

        var report: [String] = []
        var fullyWorking = 0
        var tunedPassed = false

        for fixture in LiveSourceFixtures.all {
            let name = fixture.name
            var line = "▶︎ \(name)  "
            guard let source = decode(fixture.json) else {
                report.append(line + "解析书源失败")
                continue
            }

            // 1. 搜索
            var results: [SearchBook] = []
            for keyword in keywords {
                if let found = try? await webBook.searchBook(source, key: keyword), !found.isEmpty {
                    results = found
                    break
                }
            }
            guard !results.isEmpty else {
                report.append(line + "✗ 搜索无结果")
                continue
            }
            line += "搜索 \(results.count) 条 ✓  "

            // 2. 详情
            let first = results[0]
            var book = first.toBook()
            book.origin = source.bookSourceUrl
            do {
                book = try await webBook.getBookInfo(source, book: book, canReName: true)
                line += "详情「\(book.name)」✓  "
            } catch {
                report.append(line + "✗ 详情失败: \(error.localizedDescription)")
                continue
            }

            // 3. 目录
            var chapters: [BookChapter] = []
            do {
                chapters = try await webBook.getChapterList(source, book: book)
                line += "目录 \(chapters.count) 章 ✓  "
            } catch {
                report.append(line + "✗ 目录失败: \(error.localizedDescription)")
                continue
            }

            // 4. 正文（取第一章非卷标题的）
            let chapter = chapters.first(where: { !$0.isVolume }) ?? chapters[0]
            do {
                let text = try await webBook.getContent(source, book: book, chapter: chapter,
                                                        nextChapterUrl: nil, needSave: false)
                let snippet = text.replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                line += "正文 \(text.count) 字 ✓\n   摘要: \(String(snippet.prefix(70)))"
                fullyWorking += 1
                if name.contains("手工校准") { tunedPassed = true }
            } catch {
                report.append(line + "✗ 正文失败: \(error.localizedDescription)")
                continue
            }
            report.append(line)
        }

        print("\n========== 真实书源验证 ==========")
        for line in report { print(line) }
        print("=================================")
        print("完整跑通（搜索→详情→目录→正文）: \(fullyWorking)/\(LiveSourceFixtures.all.count)")

        // 公开合集里的书源会随站点改版失效（本轮就遇到 3 个全部过期），
        // 所以只有「按站点当前结构校准过」的那条作为硬断言，用来守住引擎本身。
        XCTAssertTrue(tunedPassed, "校准过的书源必须能端到端跑通")
    }

    private func decode(_ json: String) -> BookSource? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BookSource.self, from: data)
    }
}
