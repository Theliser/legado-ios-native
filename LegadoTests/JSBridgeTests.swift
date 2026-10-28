import XCTest
import JavaScriptCore
@testable import Legado

/// JS 桥（java.*）与宽松解析。
/// 网络一律用 HTTPHook 回放，不发真请求。
final class JSBridgeTests: XCTestCase {

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var specs: [HTTPRequestSpec] = []
        func append(_ spec: HTTPRequestSpec) {
            lock.lock(); specs.append(spec); lock.unlock()
        }
    }

    private var db: AppDatabase!
    private var settings: AppSettings!
    private var cookieStore: CookieStore!
    private var capture: Capture!
    private var client: HTTPClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(inMemory: true)
        AppVariableStore.shared.clear()
        settings = AppSettings(defaults: UserDefaults(suiteName: "jsbridge.\(UUID().uuidString)")!)
        cookieStore = CookieStore(dao: CookieDao(db: db))
        capture = Capture()
        client = HTTPClient(settings: settings, cookieStore: cookieStore)
        let capture = self.capture!
        client.hook = HTTPHook(replay: { spec in
            capture.append(spec)
            var response = StrResponse(url: spec.url,
                                       body: "{\"code\":0,\"data\":[{\"name\":\"书名\"}]}",
                                       code: 200)
            response.headers = ["Content-Type": "application/json", "X-Token": "abc"]
            return response
        }, record: nil)
    }

    private func makeSource() -> BookSource {
        var source = BookSource()
        source.bookSourceName = "测试源"
        source.bookSourceUrl = "https://demo.test"
        return source
    }

    // MARK: - java.get / post

    func testJavaPostSendsRealBody() throws {
        let analyze = AnalyzeUrl(url: "https://demo.test", source: makeSource(),
                                 httpClient: client, cookieStore: cookieStore, settings: settings)
        let value = analyze.evalJS("java.post('https://demo.test/api', 'q=1&sign=x').body()")
        XCTAssertNotNil(value, "java.post 应返回响应对象")

        let spec = try XCTUnwrap(capture.specs.last)
        XCTAssertEqual(spec.method, "POST")
        let body = try XCTUnwrap(spec.body)
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(text.contains("q=1"), "POST body 不能丢：\(text)")
        XCTAssertTrue(text.contains("sign=x"), "实际：\(text)")
    }

    func testJavaGetCarriesHeaders() throws {
        let analyze = AnalyzeUrl(url: "https://demo.test", source: makeSource(),
                                 httpClient: client, cookieStore: cookieStore, settings: settings)
        _ = analyze.evalJS("java.get('https://demo.test/api', {'X-Requested-With':'XMLHttpRequest'}).body()")
        let spec = try XCTUnwrap(capture.specs.last)
        XCTAssertEqual(spec.method, "GET")
        XCTAssertEqual(spec.headers["X-Requested-With"], "XMLHttpRequest")
    }

    func testJavaResponseExposesCodeAndHeaders() throws {
        let analyze = AnalyzeUrl(url: "https://demo.test", source: makeSource(),
                                 httpClient: client, cookieStore: cookieStore, settings: settings)
        let code = analyze.evalJS("java.get('https://demo.test/api').code()") as? Int
        XCTAssertEqual(code, 200)
        let token = analyze.evalJS("java.get('https://demo.test/api').header('x-token')")
        XCTAssertEqual(token as? String, "abc", "响应头大小写不敏感")
        let text = analyze.evalJS("String(java.get('https://demo.test/api'))")
        XCTAssertEqual(text as? String, "{\"code\":0,\"data\":[{\"name\":\"书名\"}]}")
    }

    func testJavaAjaxAll() throws {
        let analyze = AnalyzeUrl(url: "https://demo.test", source: makeSource(),
                                 httpClient: client, cookieStore: cookieStore, settings: settings)
        let value = analyze.evalJS("java.ajaxAll(['https://demo.test/a','https://demo.test/b']).length")
        XCTAssertEqual(value as? Int, 2)
        XCTAssertEqual(capture.specs.count, 2)
    }

    // MARK: - 请求参数转换

    func testOptionJSONBuildsMethodBodyHeaders() {
        let request = JSHttpRequest(url: "https://a.com", method: "post",
                                    body: "a=1", headers: ["X": "y"])
        let option = try! XCTUnwrap(request.optionJSON)
        let object = try! XCTUnwrap(JSONTool.parseObject(option))
        XCTAssertEqual(object["method"] as? String, "POST")
        XCTAssertEqual(object["body"] as? String, "a=1")
        XCTAssertEqual((object["headers"] as? [String: String])?["X"], "y")
    }

    func testOptionJSONNilForPlainGet() {
        let request = JSHttpRequest(url: "https://a.com")
        XCTAssertNil(request.optionJSON)
    }

    func testParseHeadersAcceptsObjectAndJSON() {
        XCTAssertEqual(JSJavaBridge.parseHeaders(["A": "b"])["A"], "b")
        XCTAssertEqual(JSJavaBridge.parseHeaders("{\"A\":\"b\"}")["A"], "b")
        XCTAssertTrue(JSJavaBridge.parseHeaders(nil).isEmpty)
    }

    // MARK: - java.getString / getElements / source 变量

    func testJavaGetStringUsesCurrentContent() {
        let analyze = AnalyzeRule(source: makeSource())
        analyze.setContent("<div class=\"n\">书名</div>")
        XCTAssertEqual(analyze.evalJS("java.getString('.n@text')") as? String, "书名")
    }

    func testJavaGetElements() {
        let analyze = AnalyzeRule(source: makeSource())
        analyze.setContent("""
        <div class="n">甲</div><div class="n">乙</div>
        """)
        let value = analyze.evalJS("""
        var list = java.getElements('.n');
        list.size() + ':' + list.get(0).text() + ':' + list.get(1).text();
        """) as? String
        XCTAssertEqual(value, "2:甲:乙")
    }

    func testSourcePutGet() {
        var source = makeSource()
        source.bookSourceUrl = "https://demo.test/\(UUID().uuidString)"
        let analyze = AnalyzeRule(source: source)
        let value = analyze.evalJS("source.put('k', 'v'); source.get('k')") as? String
        XCTAssertEqual(value, "v")
    }

    func testResponseCookies() {
        client.hook = HTTPHook(replay: { spec in
            var response = StrResponse(url: spec.url, body: "ok", code: 200)
            response.headers = ["Set-Cookie": "sid=abc; Path=/, tok=1; Path=/"]
            return response
        })
        let analyze = AnalyzeRule(source: makeSource())
        analyze.httpClient = client
        let value = analyze.evalJS("""
        java.get('https://demo.test/x').cookies().toString()
        """) as? String
        let text = try? XCTUnwrap(value)
        XCTAssertTrue(text?.contains("sid=abc") == true)
        XCTAssertTrue(text?.contains("tok=1") == true)
    }

    func testHeadRequest() {
        let analyze = AnalyzeRule(source: makeSource())
        analyze.httpClient = client
        _ = analyze.evalJS("java.head('https://demo.test/x', {})")
        XCTAssertEqual(capture.specs.last?.method, "HEAD")
    }

    func testByteArrayRoundTrip() {
        let analyze = AnalyzeRule(source: makeSource())
        // 5L2g5aW9 = "你好"
        let value = analyze.evalJS("java.bytesToStr(java.base64DecodeToByteArray('5L2g5aW9'))") as? String
        XCTAssertEqual(value, "你好")
    }

    // MARK: - @put 宽松解析

    func testPutWithUnquotedKeys() {
        // 真源里 `@put:{name:.n@text}` 键不带引号，标准 JSON 解析必失败
        let rule = AnalyzeRule(source: nil)
        rule.setContent("<div class=\"n\">书名</div>")
        let value = rule.getString("@put:{name:.n@text}@get:{name}")
        XCTAssertEqual(value, "书名")
    }

    func testPutWithSingleQuotesAndCommaInValue() {
        let rule = AnalyzeRule(source: nil)
        rule.setContent("<div class=\"n\">甲,乙</div>")
        let value = rule.getString("@put:{'name':'.n@text'}@get:{name}")
        XCTAssertEqual(value, "甲,乙")
    }

    func testLenientJSONEdgeCases() {
        // JSONTool 自带「严格 → 宽松」兜底，键不带引号、值用单引号都能读
        XCTAssertEqual(JSONTool.parseObject("{a:1}")?["a"] as? Int, 1)
        XCTAssertEqual(JSONTool.parseObject("{\"a\":\"x,y\"}")?["a"] as? String, "x,y")
        XCTAssertEqual(JSONTool.parseObject("{a:'x,y'}")?["a"] as? String, "x,y")
        XCTAssertNil(JSONTool.parseObject("not json"))
        // `{}` 本身是合法 JSON，得到空字典而不是 nil
        XCTAssertEqual(JSONTool.parseObject("{}")?.count, 0)
        XCTAssertEqual(JSONTool.parseObject("{\"a\":123}")?["a"] as? Int, 123)
    }
}
