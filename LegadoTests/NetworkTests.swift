import XCTest
@testable import Legado

/// P3 网络与 Cookie、P4 限速：都是「书源能不能真的用起来」的关键点。
final class NetworkTests: XCTestCase {

    private var db: AppDatabase!
    private var cookieStore: CookieStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(inMemory: true)
        cookieStore = CookieStore(dao: CookieDao(db: db))
        ConcurrentRateLimiter.shared.reset()
    }

    override func tearDownWithError() throws {
        ConcurrentRateLimiter.shared.reset()
        db = nil
        try super.tearDownWithError()
    }

    // MARK: - URL 规整

    func testMakeURLDoesNotDoubleEncodePercentEscapes() {
        // 已编码的中文参数不能被再编码成 %25E5...
        let raw = "https://a.com/s?q=%E5%89%91%E6%9D%A5&p=2"
        let url = HTTPClient.makeURL(raw)
        XCTAssertEqual(url?.absoluteString, raw)
    }

    func testMakeURLEncodesRawChineseAndSpaces() {
        let url = HTTPClient.makeURL("https://a.com/s?q=剑来 二")
        XCTAssertNotNil(url)
        XCTAssertFalse(url!.absoluteString.contains("剑"))
        XCTAssertTrue(url!.absoluteString.contains("%E5%89%91"))
        XCTAssertFalse(url!.absoluteString.contains(" "))
    }

    func testMakeURLRejectsGarbage() {
        XCTAssertNil(HTTPClient.makeURL("not a url"))
    }

    func testSameURLIgnoresSchemeAndFragment() {
        XCTAssertTrue(HTTPClient.sameURL("https://a.com/b?x=1", "https://a.com/b?x=1#frag"))
        XCTAssertFalse(HTTPClient.sameURL("https://a.com/b?x=1", "https://a.com/b?x=2"))
    }

    // MARK: - Set-Cookie 拆分

    func testSplitCombinedSetCookieKeepsExpiresComma() {
        // iOS 会把多条 Set-Cookie 合并，Expires 里的逗号不能当分隔符
        let header = "a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT, b=2; Path=/"
        let parts = HTTPClient.splitCombinedSetCookie(header)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].hasPrefix("a=1"))
        XCTAssertTrue(parts[0].contains("21 Oct"))
        XCTAssertTrue(parts[1].hasPrefix("b=2"))
    }

    // MARK: - Cookie 存储

    func testCookieKeyedBySubDomain() {
        cookieStore.setCookie("https://www.example.com/book/1", "a=1")
        // 同主域不同子域共用一份
        XCTAssertEqual(cookieStore.getCookie("https://m.example.com/x"), "a=1")
        // 不同主域互不影响
        XCTAssertEqual(cookieStore.getCookie("https://other.com/x"), "")
    }

    func testCookieReplaceMergesInsteadOfOverwrite() {
        cookieStore.setCookie("https://a.com", "a=1; b=2")
        cookieStore.replaceCookie("https://a.com", "b=3; c=4")
        let map = CookieStore.cookieToMap(cookieStore.getCookie("https://a.com"))
        XCTAssertEqual(map["a"], "1", "旧键要保留")
        XCTAssertEqual(map["b"], "3", "同名键用新值")
        XCTAssertEqual(map["c"], "4")
    }

    func testSessionCookieMergesOverPersistent() {
        cookieStore.setCookie("https://a.com", "p=1")
        let domain = NetworkUtils.getSubDomain("https://a.com")
        cookieStore.updateSessionCookie(domain: domain, cookies: "s=2")
        let map = CookieStore.cookieToMap(cookieStore.getCookie("https://a.com"))
        XCTAssertEqual(map["p"], "1")
        XCTAssertEqual(map["s"], "2")
        // 会话 cookie 不进持久层
        XCTAssertFalse(cookieStore.getCookieNoSession("https://a.com").contains("s=2"))
    }

    func testCookieTrimsWhenOverLimit() {
        // 造一个超过 4096 字节的 cookie，读取时应被裁剪
        let big = (0..<200).map { "k\($0)=\(String(repeating: "v", count: 40))" }.joined(separator: "; ")
        XCTAssertGreaterThan(big.utf8.count, 4096)
        cookieStore.setCookie("https://a.com", big)
        let result = cookieStore.getCookie("https://a.com")
        XCTAssertLessThanOrEqual(result.utf8.count, 4096)
        XCTAssertFalse(result.isEmpty, "裁剪后不能把 cookie 清空")
    }

    func testGetKeyAndRemoveKey() {
        cookieStore.setCookie("https://a.com", "cf_clearance=abc; uid=7")
        XCTAssertEqual(cookieStore.getKey("https://a.com", "cf_clearance"), "abc")
        cookieStore.removeCookie("https://a.com", key: "uid")
        XCTAssertEqual(cookieStore.getKey("https://a.com", "uid"), "")
        XCTAssertEqual(cookieStore.getKey("https://a.com", "cf_clearance"), "abc")
    }

    func testRemoveCookieClearsPersistentAndSession() {
        cookieStore.setCookie("https://a.com", "a=1")
        let domain = NetworkUtils.getSubDomain("https://a.com")
        cookieStore.updateSessionCookie(domain: domain, cookies: "s=2")
        cookieStore.removeCookie("https://a.com")
        XCTAssertEqual(cookieStore.getCookie("https://a.com"), "")
        XCTAssertNil(cookieStore.sessionCookie(domain: domain))
    }

    func testCookiePersistsAcrossStoreInstances() {
        cookieStore.setCookie("https://a.com", "cf_clearance=xyz")
        // 新建一个 store（模拟冷启动）仍能从库里读回
        let fresh = CookieStore(dao: CookieDao(db: db))
        XCTAssertEqual(fresh.getKey("https://a.com", "cf_clearance"), "xyz")
    }

    // MARK: - 并发限速

    func testRateLimiterParsesBothFormats() {
        let pair = ConcurrentRateLimiter.parse("3/1000")
        XCTAssertEqual(pair.accessLimit, 3)
        XCTAssertEqual(pair.interval, 1000)

        let single = ConcurrentRateLimiter.parse("500")
        XCTAssertEqual(single.accessLimit, 1, "单数字表示 1 次/间隔")
        XCTAssertEqual(single.interval, 500)
    }

    func testRateLimiterAllowsUpToLimitThenWaits() {
        let limiter = ConcurrentRateLimiter()
        let key = "src"
        let rate = "2/60000"   // 每 60s 最多 2 次

        XCTAssertEqual(limiter.tryAcquire(key: key, rate: rate), 0, "首次放行")
        XCTAssertEqual(limiter.tryAcquire(key: key, rate: rate), 0, "第二次在额度内")
        let wait = limiter.tryAcquire(key: key, rate: rate)
        XCTAssertGreaterThan(wait, 0, "超出额度要等待")
        XCTAssertLessThanOrEqual(wait, 60000)
    }

    func testRateLimiterSeparatedBySourceKey() {
        let limiter = ConcurrentRateLimiter()
        let rate = "1/60000"
        XCTAssertEqual(limiter.tryAcquire(key: "a", rate: rate), 0)
        XCTAssertEqual(limiter.tryAcquire(key: "b", rate: rate), 0, "不同书源互不影响")
        XCTAssertGreaterThan(limiter.tryAcquire(key: "a", rate: rate), 0)
    }

    func testRateLimiterIgnoresZeroAndEmpty() async {
        let limiter = ConcurrentRateLimiter()
        let zero = await limiter.acquire(key: "k", concurrentRate: "0")
        let empty = await limiter.acquire(key: "k", concurrentRate: "")
        let noKey = await limiter.acquire(key: nil, concurrentRate: "1/60000")
        XCTAssertEqual(zero, 0)
        XCTAssertEqual(empty, 0)
        XCTAssertEqual(noKey, 0)
    }

    // MARK: - AnalyzeUrl 编码

    private func makeAnalyzeUrl(_ raw: String, key: String? = nil,
                                source: BookSource? = nil) -> AnalyzeUrl {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "test.net.\(UUID().uuidString)")!)
        let client = HTTPClient(settings: settings, cookieStore: cookieStore)
        return AnalyzeUrl(url: raw, key: key, source: source, httpClient: client,
                          cookieStore: cookieStore, settings: settings)
    }

    func testAnalyzeUrlKeepsAlreadyEncodedQuery() {
        // 上游 encodeParams 会先判断是否已编码，已编码则原样保留
        let analyze = makeAnalyzeUrl("https://a.com/s?q=%E5%89%91%E6%9D%A5")
        XCTAssertEqual(analyze.url, "https://a.com/s?q=%E5%89%91%E6%9D%A5")
    }

    func testAnalyzeUrlEncodesChineseQuery() {
        // url 保留原始形态，真正发请求用的是 encodedQuery（与上游一致）
        let analyze = makeAnalyzeUrl("https://a.com/s?q=剑来")
        let encoded = analyze.encodedQuery ?? ""
        XCTAssertTrue(encoded.contains("%E5%89%91"), "中文要被转义，实际: \(encoded)")
        XCTAssertFalse(encoded.contains("剑"))
    }

    func testAnalyzeUrlPostFormEncoding() {
        let option = #"https://a.com/api,{"method":"POST","body":"k=剑来&p=1"}"#
        let analyze = makeAnalyzeUrl(option)
        XCTAssertEqual(analyze.method, "POST")
        XCTAssertEqual(analyze.url, "https://a.com/api")
    }

    func testAnalyzeUrlJsOptionCanRewriteUrl() {
        let option = #"https://a.com/old,{"js":"result.replace('old','new')"}"#
        let analyze = makeAnalyzeUrl(option)
        XCTAssertEqual(analyze.url, "https://a.com/new")
    }

    func testEnabledCookieJarFlowsIntoRequestHeader() {
        var source = BookSource()
        source.bookSourceUrl = "https://a.com"
        source.bookSourceName = "A"
        source.enabledCookieJar = true
        cookieStore.setCookie("https://a.com", "cf_clearance=zzz")

        let analyze = makeAnalyzeUrl("https://a.com/x", source: source)
        analyze.setCookie()
        XCTAssertEqual(analyze.headerMap["CookieJar"], "1")
        XCTAssertTrue(analyze.headerMap["Cookie"]?.contains("cf_clearance=zzz") ?? false)
    }
}
