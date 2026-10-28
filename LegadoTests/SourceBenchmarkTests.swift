import XCTest
@testable import Legado

/// 书源基准测试。
///
/// 分两层：
/// 1. **回放（默认跑）**：用录好的真实响应离线跑完整链路，秒级、不联网、结果确定。
///    改规则引擎/解析链路时，它就是「书源有没有被改坏」的守门人。
/// 2. **联网（默认跳过）**：真连站点，用来发现「源腐烂」。由定时任务或手动触发。
///
/// ```
/// # 日常（离线）
/// xcodebuild test ... -only-testing:LegadoTests/SourceBenchmarkTests
///
/// # 联网体检
/// TEST_RUNNER_RUN_LIVE_TESTS=1 xcodebuild test ... -only-testing:LegadoTests/SourceBenchmarkTests/testLiveDrift
///
/// # 重新录制语料（先跑 scripts/harvest-benchmark-sources.py 抓候选源）
/// TEST_RUNNER_BENCH_RECORD=1 xcodebuild test ... -only-testing:LegadoTests/SourceBenchmarkTests/testRecordFromPool
/// ```
final class SourceBenchmarkTests: XCTestCase {

    /// 录/回放都试这几个书名，命中率最高
    private let keywords = ["剑来", "诡秘之主", "斗破苍穹", "凡人修仙传", "夜的命名术"]

    // MARK: - 环境

    private final class Sandbox {
        let db: AppDatabase
        let settings: AppSettings
        let cookieStore: CookieStore
        let client: HTTPClient
        let webBook: WebBook
        private let suiteName: String
        private let defaults: UserDefaults

        init(hook: HTTPHook?) throws {
            db = try AppDatabase(inMemory: true)
            suiteName = "bench.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            settings = AppSettings(defaults: defaults)
            cookieStore = CookieStore(dao: CookieDao(db: db))
            // 需要代理时：TEST_RUNNER_BENCH_PROXY=http://127.0.0.1:10808
            let proxy = ProcessInfo.processInfo.environment["BENCH_PROXY"]
            client = HTTPClient(settings: settings, cookieStore: cookieStore, proxy: proxy)
            client.hook = hook
            webBook = WebBook(settings: settings, httpClient: client,
                              cookieStore: cookieStore,
                              bookRepository: BookRepository(db: db, settings: settings))
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func isEnabled(_ name: String) -> Bool {
        ProcessInfo.processInfo.environment[name] == "1"
    }

    // MARK: - 回放（默认执行）

    func testCorpusReplay() async throws {
        let fixtures = BenchmarkStorage.loadFixtures()
        guard !fixtures.isEmpty else {
            return XCTFail("""
            基准语料为空：\(BenchmarkStorage.fixtureDirectory.path)
            先跑 scripts/harvest-benchmark-sources.py 抓候选源，
            再用 TEST_RUNNER_BENCH_RECORD=1 录制。
            """)
        }

        var lines: [String] = []
        var failures: [String] = []

        for fixture in fixtures {
            let name = fixture.source.bookSourceName
            let replayer = BenchmarkReplayer(exchanges: fixture.exchanges)
            let sandbox = try Sandbox(hook: HTTPHook(replay: replayer.replay, record: nil))

            do {
                let outcome = try await BenchmarkRunner.run(webBook: sandbox.webBook,
                                                            source: fixture.source,
                                                            keywords: [fixture.keyword])
                let expectation = fixture.expectation
                var problems: [String] = []
                if outcome.searchCount < expectation.minSearchResults {
                    problems.append("搜索结果 \(outcome.searchCount) < \(expectation.minSearchResults)")
                }
                if outcome.chapters < expectation.minChapters {
                    problems.append("目录 \(outcome.chapters) 章 < \(expectation.minChapters)")
                }
                if outcome.contentChars < expectation.minContentChars {
                    problems.append("正文 \(outcome.contentChars) 字 < \(expectation.minContentChars)")
                }
                let missed = replayer.missedRequests
                if !missed.isEmpty {
                    problems.append("有 \(missed.count) 个请求没录到夹具：\(missed.prefix(3).joined(separator: " / "))")
                }

                if problems.isEmpty {
                    lines.append("✓ \(name)  \(outcome.summary)  录制于 \(fixture.recordedAt.prefix(10))")
                } else {
                    lines.append("✗ \(name)  " + problems.joined(separator: "；"))
                    failures.append("\(name): " + problems.joined(separator: "；"))
                }
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                lines.append("✗ \(name)  链路失败：\(text)")
                failures.append("\(name): \(text)")
            }
        }

        print("\n========== 书源基准（离线回放，\(fixtures.count) 个源）==========")
        for line in lines { print(line) }
        let stale = fixtures.filter { $0.ageInDays > 45 }
        if !stale.isEmpty {
            print("⚠️ 有 \(stale.count) 个夹具超过 45 天未更新：" +
                  stale.map { "\($0.source.bookSourceName)(\($0.ageInDays)天)" }.joined(separator: "、"))
        }
        print("==========================================================")

        XCTAssertTrue(failures.isEmpty, "回放基准失败：\n" + failures.joined(separator: "\n"))
    }

    // MARK: - 联网体检（发现源腐烂）

    func testLiveDrift() async throws {
        guard isEnabled("RUN_LIVE_TESTS") else {
            throw XCTSkip("联网体检：TEST_RUNNER_RUN_LIVE_TESTS=1")
        }
        let fixtures = BenchmarkStorage.loadFixtures()
        guard !fixtures.isEmpty else { return XCTFail("基准语料为空") }

        var alive = 0
        var broken: [String] = []
        print("\n========== 书源基准（联网体检）==========")
        for fixture in fixtures {
            let sandbox = try Sandbox(hook: nil)
            do {
                let outcome = try await BenchmarkRunner.run(webBook: sandbox.webBook,
                                                            source: fixture.source,
                                                            keywords: keywords)
                alive += 1
                print("✓ \(fixture.source.bookSourceName)  \(outcome.summary)")
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                broken.append("\(fixture.source.bookSourceName): \(text)")
                print("✗ \(fixture.source.bookSourceName)  \(text)")
            }
        }
        print("存活 \(alive)/\(fixtures.count)")
        for line in broken { print("  失效 → " + line) }
        print("=========================================")

        // 站点会腐烂，真实网络也会抖。硬断言只要求「不是全军覆没」；
        // 具体的失效清单交给定时任务的报告去跟进。
        XCTAssertGreaterThan(alive, 0, "联网体检：所有书源都不通，先确认网络/代理")
    }

    // MARK: - 录制（刷新语料）

    func testRecordFromPool() async throws {
        guard isEnabled("BENCH_RECORD") else {
            throw XCTSkip("录制：TEST_RUNNER_BENCH_RECORD=1")
        }
        let pool = BenchmarkStorage.loadPool()
        guard !pool.isEmpty else {
            return XCTFail("候选池为空：\(BenchmarkStorage.poolDirectory.path)\n先跑 scripts/harvest-benchmark-sources.py")
        }
        let limit = Int(ProcessInfo.processInfo.environment["BENCH_LIMIT"] ?? "") ?? 8
        let only = ProcessInfo.processInfo.environment["BENCH_ONLY"]

        var saved: [String] = []
        var skipped: [String] = []

        for source in pool {
            if saved.count >= limit { break }
            if let only, !only.isEmpty, !source.bookSourceUrl.contains(only) { continue }

            let recorder = BenchmarkRecorder()
            let sandbox = try Sandbox(hook: HTTPHook(replay: nil, record: recorder.record))
            do {
                let outcome = try await BenchmarkRunner.run(webBook: sandbox.webBook,
                                                            source: source,
                                                            keywords: keywords)
                // 太薄的结果不配进基准：3 章以内、正文 200 字以内无法判断引擎是否回归
                guard outcome.chapters >= 3, outcome.contentChars >= 200 else {
                    skipped.append("\(source.bookSourceName) 结果过薄：\(outcome.summary)")
                    continue
                }
                let fixture = BenchmarkFixture(
                    source: source,
                    keyword: outcome.keyword,
                    recordedAt: ISO8601DateFormatter().string(from: Date()),
                    expectation: BenchmarkExpectation(
                        minSearchResults: 1,
                        minChapters: max(3, outcome.chapters / 2),
                        minContentChars: max(200, outcome.contentChars / 2)),
                    exchanges: recorder.exchanges)
                if BenchmarkStorage.save(fixture) != nil {
                    saved.append("\(source.bookSourceName) → \(fixture.fileName)  \(outcome.summary)")
                } else {
                    skipped.append("\(source.bookSourceName) 写盘失败")
                }
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                skipped.append("\(source.bookSourceName) \(text)")
            }
        }

        print("\n========== 录制结果 ==========")
        for line in saved { print("✓ " + line) }
        for line in skipped { print("· 跳过 \(line)") }
        print("入库 \(saved.count) 个")
        print("=============================")
        XCTAssertGreaterThan(saved.count, 0, "一个源都没录上，先检查网络/代理")
    }
}
