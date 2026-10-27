import XCTest
@testable import Legado

final class RuleEngineTests: XCTestCase {

    // MARK: - 规则切分

    func testSplitSourceRuleKeepsJsAndCss() {
        let rule = AnalyzeRule(source: nil)
        let rules = rule.splitSourceRule("@js:result.split(',')")
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].rule, "result.split(',')")
    }

    func testPutAndTemplateRewrite() {
        let rule = AnalyzeRule(source: nil)
        rule.setContent("<div class=\"name\">剑来</div>")
        let value = rule.getString("@put:{k:\".name@text\"}@get:{k}")
        XCTAssertEqual(value, "剑来")
    }

    func testDollarIndexReplacement() {
        let rule = AnalyzeRule(source: nil)
        rule.setContent("<div><a>第一章</a></div>")
        // 先用选择器拿到元素，再用 ## 替换
        let value = rule.getString(".name@text##a|b")
        XCTAssertEqual(value, "第一章")
    }

    // MARK: - CSS

    func testCssTextAndAttr() {
        let html = """
        <html><body>
        <div id="list">
          <a href="/book/1">编号一</a>
          <a href="/book/2">编号二</a>
        </div>
        </body></html>
        """
        let rule = AnalyzeRule(source: nil)
        rule.setContent(html)
        rule.setBaseUrl("https://example.com/")
        let names = rule.getStringList("#list a@text")
        XCTAssertEqual(names, ["编号一", "编号二"])

        let urls = rule.getStringList("#list a@href", isUrl: true)
        XCTAssertEqual(urls, ["https://example.com/book/1", "https://example.com/book/2"])
    }

    func testCssIndexSyntax() {
        let html = "<div><span>0</span><span>1</span><span>2</span><span>3</span></div>"
        let rule = AnalyzeRule(source: nil)
        rule.setContent(html)
        XCTAssertEqual(rule.getStringList("div.span[1:2]@text"), ["1", "2"])
        XCTAssertEqual(rule.getStringList("div.span.-1@text"), ["3"])
        XCTAssertEqual(rule.getStringList("div.span!0@text"), ["1", "2", "3"])
    }

    // MARK: - JSONPath

    func testJSONPath() {
        let json = """
        {"code":0,"data":{"list":[{"name":"A","n":1},{"name":"B","n":2}]}}
        """
        let rule = AnalyzeRule(source: nil)
        rule.setContent(json)
        XCTAssertEqual(rule.getString("$.data.list[*].name"), "A\nB")
        XCTAssertEqual(rule.getStringList("$.data.list[*].name"), ["A", "B"])
        XCTAssertEqual(rule.getString("$.data.list[?(@.n > 1)].name"), "B")
    }

    // MARK: - XPath

    func testXPath() {
        let html = "<html><body><div class='c'><p>一</p><p>二</p></div></body></html>"
        let rule = AnalyzeRule(source: nil)
        rule.setContent(html)
        XCTAssertEqual(rule.getStringList("//div[@class='c']/p/text()"), ["一", "二"])
    }

    // MARK: - 正则

    func testRegexRule() {
        let rule = AnalyzeRule(source: nil)
        rule.setContent("<span>作者：张三</span>")
        XCTAssertEqual(rule.getString(":作者：(\\S+?)(?:<|$)"), "张三")
    }

    // MARK: - Cookie 域名

    func testCookieDomain() {
        XCTAssertEqual(NetworkUtils.getSubDomain("https://www.example.com/book/1"), "example.com")
        XCTAssertEqual(NetworkUtils.getSubDomain("https://www.biquge.com.cn/book"), "biquge.com.cn")
        XCTAssertEqual(NetworkUtils.getSubDomain("http://1.2.3.4/x"), "1.2.3.4")
    }

    func testCookieMergePriority() {
        let merged = CookieStore.mergeCookies("a=1; b=2", "b=3; c=4")
        let map = CookieStore.cookieToMap(merged ?? "")
        XCTAssertEqual(map["a"], "1")
        XCTAssertEqual(map["b"], "3")
        XCTAssertEqual(map["c"], "4")
    }

    // MARK: - URL 规则

    func testAnalyzeUrlOptionParsing() {
        let settings = AppSettings()
        let db = try! AppDatabase(inMemory: true)
        let cookieStore = CookieStore(dao: CookieDao(db: db))
        let client = HTTPClient(settings: settings, cookieStore: cookieStore)
        let analyzeUrl = AnalyzeUrl(url: "https://example.com/search?q={{key}}&page={{page}}",
                                    key: "测试", page: 2, baseUrl: "https://example.com",
                                    httpClient: client, cookieStore: cookieStore, settings: settings)
        XCTAssertTrue(analyzeUrl.url.contains("q="))
        XCTAssertTrue(analyzeUrl.url.contains("page=2"))
    }
}
