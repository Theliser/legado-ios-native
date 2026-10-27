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

    func testReplaceRegexRule() {
        // ##正则##替换：上游 replaceRegex 的常用形态
        let rule = AnalyzeRule(source: nil)
        rule.setContent("<div class=\"title\">第一章 剑来</div>")
        XCTAssertEqual(rule.getString(".title@text##第.章##"), " 剑来")
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
        let html = """
        <div class="list"><span>0</span><span>1</span><span>2</span><span>3</span></div>
        """
        let rule = AnalyzeRule(source: nil)
        rule.setContent(html)
        // 层级用 @ 串联；`.` 只用于 tag./class./id./text. 前缀和旧式索引
        XCTAssertEqual(rule.getStringList("class.list@tag.span@text"), ["0", "1", "2", "3"])
        XCTAssertEqual(rule.getStringList("class.list@tag.span[1:2]@text"), ["1", "2"])
        XCTAssertEqual(rule.getStringList("class.list@tag.span.-1@text"), ["3"])
        XCTAssertEqual(rule.getStringList("class.list@tag.span!0@text"), ["1", "2", "3"])
    }

    func testCssSelectorPassThrough() {
        // 没有 tag./class. 前缀时整段交给 SwiftSoup：`div.span` 是「class 为 span 的 div」
        let html = """
        <div class="span">甲</div><div>乙</div><div><span>丙</span></div>
        """
        let rule = AnalyzeRule(source: nil)
        rule.setContent(html)
        XCTAssertEqual(rule.getStringList("div.span@text"), ["甲"])
        XCTAssertEqual(rule.getStringList("div span@text"), ["丙"])
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

    // MARK: - 模式识别

    func testModePrefixes() {
        let rule = AnalyzeRule(source: nil)

        let css = rule.splitSourceRule("@CSS:div span")
        XCTAssertEqual(css.count, 1)
        XCTAssertEqual(css[0].mode, .default)
        XCTAssertEqual(css[0].rule, "@CSS:div span", "前缀由 AnalyzeByJSoup 再剥离")

        let plain = rule.splitSourceRule("@@div.span")
        XCTAssertEqual(plain[0].mode, .default)
        XCTAssertEqual(plain[0].rule, "div.span")

        let xpath = rule.splitSourceRule("@XPath://div/p")
        XCTAssertEqual(xpath[0].mode, .xpath)
        XCTAssertEqual(xpath[0].rule, "//div/p")

        let json = rule.splitSourceRule("@Json:$.a.b")
        XCTAssertEqual(json[0].mode, .json)
        XCTAssertEqual(json[0].rule, "$.a.b")

        // 以 / 开头直接判定为 XPath
        XCTAssertEqual(rule.splitSourceRule("//div/p")[0].mode, .xpath)
        // 以 $. / $[ 开头判定为 Json
        XCTAssertEqual(rule.splitSourceRule("$.a.b")[0].mode, .json)
        XCTAssertEqual(rule.splitSourceRule("$['a']")[0].mode, .json)
    }

    func testJsBlockAndAtJs() {
        let rule = AnalyzeRule(source: nil)
        let block = rule.splitSourceRule("<js>result.split(',')</js>")
        XCTAssertEqual(block.count, 1)
        XCTAssertEqual(block[0].mode, .js)
        XCTAssertEqual(block[0].rule, "result.split(',')")

        // 前置 CSS + JS 两段
        let mixed = rule.splitSourceRule("div@text<js>result.trim()</js>")
        XCTAssertEqual(mixed.count, 2)
        XCTAssertEqual(mixed[0].mode, .default)
        XCTAssertEqual(mixed[0].rule, "div@text")
        XCTAssertEqual(mixed[1].mode, .js)
        XCTAssertEqual(mixed[1].rule, "result.trim()")
    }

    func testCssPrefixExtracts() {
        let rule = AnalyzeRule(source: nil)
        rule.setContent("<div><p>甲</p><p>乙</p></div>")
        XCTAssertEqual(rule.getStringList("@CSS:div p@text"), ["甲", "乙"])
    }

    // MARK: - 组合符

    func testUnionAndShortCircuit() {
        let html = """
        <div id="a"><span>甲</span></div><div id="b"><span>乙</span></div>
        """
        let rule = AnalyzeRule(source: nil)
        rule.setContent(html)
        // && 并集
        XCTAssertEqual(rule.getStringList("#a@text&&#b@text"), ["甲", "乙"])
        // || 短路：第一个非空即返回
        XCTAssertEqual(rule.getStringList("#none@text||#b@text"), ["乙"])
    }

    // MARK: - 正则

    func testRegexAllInOneRule() {
        // 以 `:` 开头的规则走 allInOne 正则模式，这一点只在 getElement/getElements 里生效；
        // getString 不做 allInOne 处理（上游 splitSourceRule 的 allInOne 默认 false）。
        let rule = AnalyzeRule(source: nil)
        rule.setContent("<span>作者：张三</span>")
        let values = rule.getElements(":作者：(\\S+?)(?:<|$)")
        XCTAssertEqual(values.count, 1)
        // 第 0 组是整体匹配，第 1 组是捕获内容
        let groups = values.first as? [String]
        XCTAssertEqual(groups?.count, 2)
        // 第 0 组是整体匹配（非贪婪 + 右边界，会吃掉边界符），第 1 组是捕获内容
        XCTAssertEqual(groups?.last, "张三")
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

    func testAnalyzeUrlPagePlaceholder() {
        let settings = AppSettings()
        let db = try! AppDatabase(inMemory: true)
        let cookieStore = CookieStore(dao: CookieDao(db: db))
        let client = HTTPClient(settings: settings, cookieStore: cookieStore)

        func make(_ url: String, page: Int) -> AnalyzeUrl {
            AnalyzeUrl(url: url, page: page, baseUrl: "https://example.com",
                       httpClient: client, cookieStore: cookieStore, settings: settings)
        }

        // <1,2,3> 取第 page 项，越界取最后一项
        XCTAssertEqual(make("https://example.com/s?p=<1,2,3>", page: 2).url,
                       "https://example.com/s?p=2")
        XCTAssertEqual(make("https://example.com/s?p=<1,2,3>", page: 9).url,
                       "https://example.com/s?p=3")
    }

    func testAnalyzeUrlOptionAndMethod() {
        let settings = AppSettings()
        let db = try! AppDatabase(inMemory: true)
        let cookieStore = CookieStore(dao: CookieDao(db: db))
        let client = HTTPClient(settings: settings, cookieStore: cookieStore)

        // url,{json} 以首个逗号+{ 分割；这里只验证 URL 与选项被正确切开
        let rule = #"https://example.com/api/search,{"method":"POST","charset":"GBK","retry":2}"#
        let analyzeUrl = AnalyzeUrl(url: rule, key: "剑来", baseUrl: "https://example.com",
                                    httpClient: client, cookieStore: cookieStore, settings: settings)
        XCTAssertEqual(analyzeUrl.url, "https://example.com/api/search")
        XCTAssertEqual(analyzeUrl.method, "POST")
        XCTAssertEqual(analyzeUrl.retry, 2)
        XCTAssertEqual(analyzeUrl.charset, "GBK")
    }

    // MARK: - 变量回填与组合符

    func testDollarIndexBackfill() {
        // `$n` 从当前结果列表里取第 n 项（getElement 的正则分组就靠它）
        let rule = AnalyzeRule(source: nil)
        let value = rule.getString("$1", mContent: ["完整匹配", "分组一", "分组二"])
        XCTAssertEqual(value, "分组一")

        let second = rule.getString("$2", mContent: ["完整匹配", "分组一", "分组二"])
        XCTAssertEqual(second, "分组二")
    }

    func testCrossMergeOperator() {
        // %% 交叉合并：按索引交替取各分支结果
        let html = """
        <div id="a"><p>甲1</p><p>甲2</p></div>
        <div id="b"><p>乙1</p><p>乙2</p></div>
        """
        let rule = AnalyzeRule(source: nil)
        rule.setContent(html)
        XCTAssertEqual(rule.getStringList("#a@p@text%%#b@p@text"),
                       ["甲1", "乙1", "甲2", "乙2"])
    }

    func testPutWithStandardJSON() {
        let rule = AnalyzeRule(source: nil)
        rule.setContent("<div class=\"n\">书名</div>")
        let value = rule.getString(#"@put:{"k":".n@text"}@get:{k}"#)
        XCTAssertEqual(value, "书名")
    }

    func testWebJsRuleRoutesThroughHandler() {
        // @webjs 需要 WebView；这里注入假的 handler 验证规则被正确分流
        let rule = AnalyzeRule(source: nil)
        rule.setContent("<div>原始内容</div>")
        rule.webJsHandler = { js, _ in
            XCTAssertEqual(js, "document.title")
            return "来自WebView"
        }
        XCTAssertEqual(rule.getString("@webjs:document.title"), "来自WebView")
    }

    func testPutAndGetVariableStore() {
        let rule = AnalyzeRule(source: nil)
        rule.setContent("<i>值</i>")
        _ = rule.put("k", "v1")
        XCTAssertEqual(rule.get("k"), "v1")
    }

    // MARK: - 选择器前缀

    func testClassPrefixWithMultipleClasses() {
        // `class.dir clear` 是 Jsoup 的多类名写法（空格分隔取交集），
        // SwiftSoup 的 getElementsByClass 不拆空格，必须由引擎补上
        let html = """
        <div class="dir clear"><ul><li><a>第1章</a></li><li><a>第2章</a></li></ul></div>
        <div class="dir"><ul><li><a>干扰项</a></li></ul></div>
        <div class="clear"><ul><li><a>干扰项2</a></li></ul></div>
        """
        let rule = AnalyzeRule(source: nil)
        rule.setContent(html)
        XCTAssertEqual(rule.getStringList("class.dir clear@li@a@text"), ["第1章", "第2章"])
        // 单个类名照常：dir 命中 2 个 div（含「dir clear」），共 3 个 li
        XCTAssertEqual(rule.getStringList("class.dir@li@a@text")?.count, 3)
        XCTAssertEqual(rule.getStringList("class.clear@li@a@text")?.count, 3)
    }

    func testTagIdTextPrefixes() {
        let html = #"<div id="box"><span class="n">书名</span><a href="/next">下一页</a></div>"#
        let rule = AnalyzeRule(source: nil)
        rule.setContent(html)
        XCTAssertEqual(rule.getString("tag.span@text"), "书名")
        XCTAssertEqual(rule.getString("id.box@tag.span@text"), "书名")
        XCTAssertEqual(rule.getString("text.下一页@href"), "/next")
    }
}
