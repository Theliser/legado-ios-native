import XCTest
@testable import Legado

/// 巡检器：状态判定、配置读写、分组写回。
/// 走网络的部分只在 LiveSourceTests 里跑，这里是纯离线逻辑。
@MainActor
final class SourceCheckTests: XCTestCase {

    private var db: AppDatabase!
    private var settings: AppSettings!
    private var container: AppContainer!
    private var checker: SourceChecker!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(inMemory: true)
        suiteName = "test.check.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = AppSettings(defaults: defaults)
        container = AppContainer(database: db, settings: settings)
        checker = SourceChecker(container: container)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    private func makeSource(url: String) -> BookSource {
        var source = BookSource()
        source.bookSourceUrl = url
        source.bookSourceName = "测试源"
        source.searchUrl = "/search?q={{key}}"
        var search = SearchRule()
        search.bookList = ".item"
        search.name = "h3@text"
        search.bookUrl = "a@href"
        source.ruleSearch = search
        return source
    }

    // MARK: - 状态

    func testNonHttpUrlIsUncheckable() async {
        // 上游把「源地址不是 http 链接」判为无法校验，而不是失败
        for url in ["", "光遇聚合", "ftp://a.com", "not a url"] {
            let result = await checker.checkOne(makeSource(url: url),
                                                config: SourceCheckConfig())
            XCTAssertEqual(result.status, .uncheckable, "url=\(url)")
            XCTAssertTrue(result.traces.isEmpty)
        }
    }

    func testStatusLabels() {
        XCTAssertEqual(CheckStatus.passed.label, "通过")
        XCTAssertEqual(CheckStatus.failed.label, "失败")
        XCTAssertEqual(CheckStatus.uncheckable.label, "无法校验")
        XCTAssertEqual(CheckStatus.notCompleted.label, "未完成")
        XCTAssertTrue(CheckStatus.failed.isFailure)
        XCTAssertTrue(CheckStatus.notCompleted.isFailure)
        XCTAssertFalse(CheckStatus.passed.isFailure)
        XCTAssertFalse(CheckStatus.uncheckable.isFailure)
    }

    func testCheckGroupNamesCoverAllFailures() {
        // 分组名会直接写进书源，改名字要同步改这里
        XCTAssertEqual(CheckGroup.search, "搜索失效")
        XCTAssertEqual(CheckGroup.timeout, "校验超时")
        XCTAssertEqual(CheckGroup.site, "网站失效")
        XCTAssertEqual(CheckGroup.js, "js失效")
        XCTAssertEqual(Set(CheckGroup.all).count, CheckGroup.all.count)
    }

    // MARK: - 配置

    func testConfigRoundTrip() {
        var config = SourceCheckConfig()
        config.keyword = "剑来"
        config.timeout = 90
        config.checkSearch = false
        config.checkContent = false
        config.concurrency = 5
        config.save(to: defaults)

        let loaded = SourceCheckConfig.load(from: defaults)
        XCTAssertEqual(loaded.keyword, "剑来")
        XCTAssertEqual(loaded.timeout, 90)
        XCTAssertFalse(loaded.checkSearch)
        XCTAssertTrue(loaded.checkInfo)
        XCTAssertFalse(loaded.checkContent)
        XCTAssertEqual(loaded.concurrency, 5)
    }

    func testConfigDefaultsWhenEmpty() {
        let loaded = SourceCheckConfig.load(from: UserDefaults(suiteName: "test.check.empty.\(UUID().uuidString)")!)
        XCTAssertEqual(loaded.keyword, "我的")
        XCTAssertEqual(loaded.timeout, 180)
        XCTAssertTrue(loaded.checkSearch)
        XCTAssertTrue(loaded.checkContent)
    }

    func testConfigClampsConcurrency() {
        let suite = "test.check.clamp.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.set(99, forKey: "check.concurrency")
        XCTAssertEqual(SourceCheckConfig.load(from: store).concurrency, 8)
        store.set(0, forKey: "check.concurrency")
        XCTAssertEqual(SourceCheckConfig.load(from: store).concurrency, 1)
        store.removePersistentDomain(forName: suite)
    }

    func testConfigSummary() {
        var config = SourceCheckConfig()
        config.timeout = 60
        config.checkToc = false
        XCTAssertEqual(config.summary, "60s 搜索 详情 正文")

        config.checkSearch = false
        config.checkInfo = false
        config.checkContent = false
        XCTAssertEqual(config.summary, "60s （未选择校验项）")
    }

    // MARK: - 关键字

    func testCheckKeywordFallsBackToSourceRule() {
        var source = makeSource(url: "https://a.com")
        // 书源自带校验关键字时优先用它（字段在 ruleSearch 上）
        var rule = source.searchRule
        rule.checkKeyWord = "自定义"
        source.ruleSearch = rule
        XCTAssertEqual(source.getCheckKeyWord(default: "默认"), "自定义")

        rule.checkKeyWord = nil
        source.ruleSearch = rule
        XCTAssertEqual(source.getCheckKeyWord(default: "默认"), "默认")
    }
}
