import Foundation
import SwiftSoup

/// 规则解析核心，逐条对齐上游 `AnalyzeRule`：
/// 规则切分（`@js` / `<js>` / `@webjs` / `@CSS` / `@XPath` / `@Json` / 正则）、
/// `@put` / `@get` / `{{js}}` / `$1..$99` 回填、`##替换`、变量表、JS 求值。
final class AnalyzeRule {

    enum Mode {
        case xpath, json, `default`, js, regex, webJs
    }

    // MARK: - 状态

    private var source: BookSource?
    private var book: Book?
    private var chapter: BookChapter?
    private var ruleData: RuleData?
    private var preUpdateJs: Bool
    private var isFromBookInfo: Bool

    private var content: Any?
    private var baseUrl: String?
    private var redirectUrl: String?
    private var nextChapterUrl: String?
    private var isJSON = false
    private var isRegex = false

    private var analyzeByXPath: AnalyzeByXPath?
    private var analyzeByJSoup: AnalyzeByJSoup?
    private var analyzeByJSONPath: AnalyzeByJSONPath?

    private var stringRuleCache: [String: [SourceRule]] = [:]
    private var ruleName: String?

    var runtime: JSRuntime = .shared
    var cookieStore: CookieStore?
    var httpClient: HTTPClient?
    /// webJs 规则需要 WebView，由 WebBook 注入
    var webJsHandler: ((_ js: String, _ result: Any?) -> String?)?
    /// preUpdateJs 中刷新目录链接
    var refreshTocHandler: (() -> Void)?

    init(book: Book? = nil, source: BookSource?, preUpdateJs: Bool = false, isFromBookInfo: Bool = false) {
        self.book = book
        self.source = source
        self.preUpdateJs = preUpdateJs
        self.isFromBookInfo = isFromBookInfo
    }

    init(ruleData: RuleData?, source: BookSource?) {
        self.ruleData = ruleData
        self.source = source
        self.preUpdateJs = false
        self.isFromBookInfo = false
    }

    convenience init(source: BookSource?) {
        self.init(book: nil, source: source)
    }

    // MARK: - 内容

    @discardableResult
    func setContent(_ content: Any?, baseUrl: String? = nil) -> AnalyzeRule {
        guard let content else {
            DebugLog.shared.log(source?.bookSourceName, "≡内容不可空")
            return self
        }
        self.content = content
        if content is XPathNode || content is SwiftSoup.Element {
            isJSON = false
        } else {
            isJSON = "\(content)".isJSONText
        }
        if let baseUrl { self.baseUrl = baseUrl }
        analyzeByXPath = nil
        analyzeByJSoup = nil
        analyzeByJSONPath = nil
        return self
    }

    @discardableResult
    func setBaseUrl(_ baseUrl: String?) -> AnalyzeRule {
        if let baseUrl { self.baseUrl = baseUrl }
        return self
    }

    @discardableResult
    func setRedirectUrl(_ url: String?) -> AnalyzeRule {
        guard let url, !url.isDataURL else { return self }
        redirectUrl = url
        return self
    }

    @discardableResult
    func setChapter(_ chapter: BookChapter?) -> AnalyzeRule {
        self.chapter = chapter
        return self
    }

    @discardableResult
    func setNextChapterUrl(_ url: String?) -> AnalyzeRule {
        nextChapterUrl = url
        return self
    }

    @discardableResult
    func setRuleData(_ data: RuleData?) -> AnalyzeRule {
        ruleData = data
        return self
    }

    @discardableResult
    func setBook(_ book: Book?) -> AnalyzeRule {
        self.book = book
        return self
    }

    func setRuleName(_ name: String) {
        if !name.isBlank { ruleName = name }
    }

    var sourceRef: BookSource? { source }
    var bookRef: Book? { book }

    // MARK: - 解析器

    private func getAnalyzeByXPath(_ object: Any) -> AnalyzeByXPath {
        if let node = object as? XPathNode, let contentNode = content as? XPathNode, node == contentNode {
            if let cached = analyzeByXPath { return cached }
            let analyzer = AnalyzeByXPath(content!)
            analyzeByXPath = analyzer
            return analyzer
        }
        if let element = object as? SwiftSoup.Element,
           let contentElement = content as? SwiftSoup.Element,
           element === contentElement {
            if let cached = analyzeByJSoup { _ = cached }
        }
        return AnalyzeByXPath(object)
    }

    private func getAnalyzeByJSoup(_ object: Any) -> AnalyzeByJSoup {
        let isSame: Bool
        if let a = object as? SwiftSoup.Element, let b = content as? SwiftSoup.Element {
            isSame = a === b
        } else if let a = object as? String, let b = content as? String {
            isSame = a == b
        } else {
            isSame = false
        }
        if isSame {
            if let cached = analyzeByJSoup { return cached }
            let analyzer = AnalyzeByJSoup(content!)
            analyzeByJSoup = analyzer
            return analyzer
        }
        return AnalyzeByJSoup(object)
    }

    private func getAnalyzeByJSONPath(_ object: Any) -> AnalyzeByJSONPath {
        if let cached = analyzeByJSONPath, let a = object as? String, let b = content as? String, a == b {
            return cached
        }
        let analyzer = AnalyzeByJSONPath(object)
        if let a = object as? String, let b = content as? String, a == b {
            analyzeByJSONPath = analyzer
        }
        return analyzer
    }

    // MARK: - 取字符串列表

    func getStringList(_ rule: String?, mContent: Any? = nil, isUrl: Bool = false) -> [String]? {
        guard let rule, !rule.isEmpty else { return nil }
        return getStringList(splitSourceRuleCache(rule), mContent: mContent, isUrl: isUrl)
    }

    func getStringList(_ ruleList: [SourceRule], mContent: Any? = nil, isUrl: Bool = false) -> [String]? {
        guard !ruleList.isEmpty else { return nil }
        var result: Any? = mContent ?? content
        guard result != nil else { return nil }

        if let dict = result as? [String: Any] {
            let sourceRule = ruleList[0]
            putRule(sourceRule.putMap)
            sourceRule.makeUpRule(result: result)
            var ruleResult: Any?
            switch sourceRule.mode {
            case .js:
                ruleResult = evalJS(sourceRule.rule, result: result)
            case .json:
                ruleResult = getAnalyzeByJSONPath(result!).getStringList(sourceRule.rule)
            default:
                if sourceRule.paramCount > 1 {
                    ruleResult = sourceRule.rule
                } else {
                    ruleResult = dict[sourceRule.rule]
                }
            }
            _ = dict
            result = ruleResult
            if let value = result, sourceRule.replaceRegex.isEmpty == false {
                if let list = value as? [Any] {
                    result = list.map { replaceRegex("\($0)", sourceRule) }
                } else {
                    result = replaceRegex("\(value)", sourceRule)
                }
            }
        } else {
            for sourceRule in ruleList {
                putRule(sourceRule.putMap)
                sourceRule.makeUpRule(result: result)
                guard let current = result else { continue }
                let rule = sourceRule.rule
                if !rule.isEmpty {
                    switch sourceRule.mode {
                    case .webJs:
                        let webResult = getWebJsResult(rule, result: current) ?? ""
                        result = JSONTool.parseArray(webResult) ?? webResult
                    case .js:
                        result = evalJS(rule, result: current)
                    case .json:
                        result = getAnalyzeByJSONPath(current).getStringList(rule)
                    case .xpath:
                        result = getAnalyzeByXPath(current).getStringList(rule)
                    case .default:
                        result = getAnalyzeByJSoup(current).getStringList(rule)
                    case .regex:
                        result = rule
                    }
                }
                if let value = result, !sourceRule.replaceRegex.isEmpty {
                    if let list = value as? [Any] {
                        result = list.map { replaceRegex("\($0)", sourceRule) }
                    } else if let list = value as? [String] {
                        result = list.map { replaceRegex($0, sourceRule) }
                    } else {
                        result = replaceRegex("\(value)", sourceRule)
                    }
                }
            }
        }

        guard let final = result else { return nil }
        var list: [String]
        if let s = final as? String {
            list = s.components(separatedBy: "\n")
        } else if let arr = final as? [String] {
            list = arr
        } else if let arr = final as? [Any] {
            list = arr.map { Self.stringValue($0) }
        } else {
            list = [Self.stringValue(final)]
        }

        if isUrl {
            var urlList: [String] = []
            for item in list {
                let absolute = NetworkUtils.getAbsoluteURL(redirectUrl ?? baseUrl, item)
                if !absolute.isEmpty && !urlList.contains(absolute) {
                    urlList.append(absolute)
                }
            }
            return urlList
        }
        return list
    }

    // MARK: - 取字符串

    func getString(_ ruleStr: String?, mContent: Any? = nil, isUrl: Bool = false, unescape: Bool = true) -> String {
        guard let ruleStr, !ruleStr.isEmpty else { return "" }
        return getString(splitSourceRuleCache(ruleStr), mContent: mContent, isUrl: isUrl, unescape: unescape)
    }

    func getString(_ ruleList: [SourceRule], mContent: Any? = nil, isUrl: Bool = false,
                   unescape: Bool = true) -> String {
        guard !ruleList.isEmpty else { return "" }
        var result: Any? = mContent ?? content
        guard result != nil else { return "" }

        if let dict = result as? [String: Any] {
            let sourceRule = ruleList[0]
            putRule(sourceRule.putMap)
            sourceRule.makeUpRule(result: result)
            var value: Any?
            switch sourceRule.mode {
            case .js:
                value = evalJS(sourceRule.rule, result: result)
            case .json:
                value = getAnalyzeByJSONPath(result!).getString(sourceRule.rule)
            default:
                if sourceRule.paramCount > 1 {
                    value = sourceRule.rule
                } else {
                    value = Self.stringValue(dict[sourceRule.rule] as Any)
                }
            }
            result = value.map { replaceRegex(Self.stringValue($0), sourceRule) }
        } else {
            for sourceRule in ruleList {
                putRule(sourceRule.putMap)
                sourceRule.makeUpRule(result: result)
                guard let current = result else { continue }
                let rule = sourceRule.rule
                if !rule.isBlank || sourceRule.replaceRegex.isEmpty {
                    switch sourceRule.mode {
                    case .webJs:
                        result = getWebJsResult(rule, result: current)
                    case .js:
                        result = evalJS(rule, result: current)
                    case .json:
                        result = getAnalyzeByJSONPath(current).getString(rule)
                    case .xpath:
                        result = getAnalyzeByXPath(current).getString(rule)
                    case .default:
                        if isUrl {
                            result = getAnalyzeByJSoup(current).getString0(rule)
                        } else {
                            result = getAnalyzeByJSoup(current).getString(rule)
                        }
                    case .regex:
                        result = rule
                    }
                }
                if let value = result, !sourceRule.replaceRegex.isEmpty {
                    result = replaceRegex(Self.stringValue(value), sourceRule)
                }
            }
        }

        let resultStr = result.map { Self.stringValue($0) } ?? ""
        var text = resultStr
        if unescape && resultStr.contains("&") {
            text = resultStr.unescapeHTML
        }

        if isUrl {
            if text.isBlank { return baseUrl ?? "" }
            return NetworkUtils.getAbsoluteURL(redirectUrl ?? baseUrl, text)
        }
        return text
    }

    // MARK: - Element / Elements

    func getElement(_ ruleStr: String) -> Any? {
        guard !ruleStr.isEmpty else { return nil }
        var result: Any? = content
        let ruleList = splitSourceRule(ruleStr, allInOne: true)
        guard content != nil, !ruleList.isEmpty else { return nil }

        for sourceRule in ruleList {
            putRule(sourceRule.putMap)
            sourceRule.makeUpRule(result: result)
            guard let current = result else { continue }
            let rule = sourceRule.rule
            switch sourceRule.mode {
            case .regex:
                // 上游这里直接把 List<String> 作为结果往下传，不做拼接
                result = AnalyzeByRegex.getElement(Self.stringValue(current), rule.splitNotBlank("&&"))
            case .webJs:
                result = JSONTool.parseObject(getWebJsResult(rule, result: current) ?? "")
            case .js:
                result = evalJS(rule, result: current)
            case .json:
                result = getAnalyzeByJSONPath(current).getObject(rule)
            case .xpath:
                result = getAnalyzeByXPath(current).getElements(rule).first
            case .default:
                result = getAnalyzeByJSoup(current).getElements(rule).first
            }
            if let value = result, !sourceRule.replaceRegex.isEmpty {
                result = replaceRegex(Self.stringValue(value), sourceRule)
            }
        }
        return result
    }

    func getElements(_ ruleStr: String) -> [Any] {
        guard !ruleStr.isEmpty, content != nil else { return [] }
        var result: Any? = content
        let ruleList = splitSourceRule(ruleStr, allInOne: true)

        for sourceRule in ruleList {
            putRule(sourceRule.putMap)
            guard let current = result else { continue }
            let rule = sourceRule.rule
            switch sourceRule.mode {
            case .regex:
                let groups = AnalyzeByRegex.getElements(Self.stringValue(current), rule.splitNotBlank("&&"))
                result = groups
            case .webJs:
                result = JSONTool.parseArray(getWebJsResult(rule, result: current) ?? "") ?? []
            case .js:
                result = evalJS(rule, result: current)
            case .json:
                result = getAnalyzeByJSONPath(current).getList(rule)
            case .xpath:
                result = getAnalyzeByXPath(current).getElements(rule)
            case .default:
                result = getAnalyzeByJSoup(current).getElements(rule)
            }
        }
        if let list = result as? [Any] { return list }
        if let node = result as? XPathNode { return [node] }
        if let element = result as? SwiftSoup.Element { return [element] }
        return []
    }

    // MARK: - 变量

    private func putRule(_ map: [String: String]) {
        for (key, value) in map {
            _ = put(key, getString(value))
        }
    }

    @discardableResult
    func put(_ key: String, _ value: String) -> String {
        if var chapter {
            var map = chapter.variableMap
            map[key] = value
            chapter.variableMap = map
        } else if var book {
            var map = book.variableMap
            map[key] = value
            book.variableMap = map
            self.book = book
        } else if let ruleData {
            ruleData.putVariable(key, value)
        } else {
            AppVariableStore.shared.put(sourceKey, key, value)
        }
        return value
    }

    func get(_ key: String) -> String {
        if key == "bookName", let book { return book.name }
        if key == "title", let chapter { return chapter.title }

        if let chapter, let value = chapter.variableMap[key], !value.isEmpty { return value }
        if let book, let value = book.variableMap[key], !value.isEmpty { return value }
        if let ruleData, let value = ruleData.variableMap[key], !value.isEmpty { return value }
        return AppVariableStore.shared.get(sourceKey, key)
    }

    private var sourceKey: String { source?.bookSourceUrl ?? ruleName ?? "default" }

    // MARK: - JS

    func evalJS(_ jsStr: String, result: Any? = nil) -> Any? {
        guard !jsStr.isBlank else { return nil }
        var env = JSEnvironment()
        env.source = source
        env.book = book
        env.chapter = chapter
        env.baseUrl = baseUrl
        env.result = Self.jsValue(result)
        env.content = Self.jsValue(content)
        env.nextChapterUrl = nextChapterUrl
        env.title = chapter?.title
        env.fromBookInfo = isFromBookInfo
        env.variables = self
        env.ajax = { [weak self] url, timeout in
            self?.ajax(url, timeout: timeout) ?? ""
        }
        return runtime.evaluate(jsStr, key: sourceKey, env: env)
    }

    /// 把 Swift 值转成 JS 可接受的值
    private static func jsValue(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if let element = value as? SwiftSoup.Element {
            return (try? element.outerHtml()) ?? ""
        }
        if let node = value as? XPathNode { return node.outerHtml }
        return value
    }

    /// js 实现跨域访问
    func ajax(_ url: String, timeout: Double? = nil) -> String? {
        guard let httpClient, let source else { return nil }
        let analyzeUrl = AnalyzeUrl(url: url, source: source, book: book, chapter: chapter,
                                    ruleData: ruleData, httpClient: httpClient,
                                    cookieStore: cookieStore, settings: nil)
        do {
            let response = try SyncBridge.run {
                try await analyzeUrl.strResponse()
            }
            return response.body
        } catch {
            DebugLog.shared.log(source.bookSourceName, "ajax(\(url)) error\n\(error.localizedDescription)")
            return nil
        }
    }

    private func getWebJsResult(_ js: String, result: Any?) -> String? {
        if let handler = webJsHandler {
            return handler(js, result)
        }
        guard let httpClient, let source else { return nil }
        var options = WebViewFetcherOptions()
        options.js = js
        options.html = Self.stringValue(content)
        options.url = baseUrl
        options.headers = source.headerMap(userAgent: nil)
        options.cookieKeyURL = source.bookSourceUrl
        do {
            let response = try SyncBridge.run { [cookieStore] in
                try await WebViewService.shared.fetch(options, cookieStore: cookieStore, cookieJar: true)
            }
            return response.body
        } catch {
            DebugLog.shared.log(source.bookSourceName, "webJs 执行失败: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - preUpdateJs 能力

    func refreshTocUrl() {
        guard preUpdateJs else {
            DebugLog.shared.log(sourceKey, "只能在 preUpdateJs 中调用 refreshTocUrl")
            return
        }
        if isFromBookInfo {
            DebugLog.shared.log(sourceKey, "已跳过重复加载详情页，请优化代码")
            return
        }
        refreshTocHandler?()
    }

    func reGetBook() {
        guard preUpdateJs else {
            DebugLog.shared.log(sourceKey, "只能在 preUpdateJs 中调用 reGetBook")
            return
        }
    }

    // MARK: - 规则切分

    func splitSourceRuleCache(_ ruleStr: String) -> [SourceRule] {
        if let cached = stringRuleCache[ruleStr] { return cached }
        let rules = splitSourceRule(ruleStr)
        stringRuleCache[ruleStr] = rules
        return rules
    }

    func splitSourceRule(_ ruleStr: String?, allInOne: Bool = false) -> [SourceRule] {
        guard let ruleStr, !ruleStr.isEmpty else { return [] }
        var ruleList: [SourceRule] = []
        var mode: Mode = .default
        var start = 0

        if allInOne && ruleStr.hasPrefix(":") {
            mode = .regex
            isRegex = true
            start = 1
        } else if isRegex {
            mode = .regex
        }

        let ns = ruleStr as NSString
        let jsMatches = Self.jsPattern.matches(in: ruleStr, options: [], range: NSRange(location: 0, length: ns.length))
        for match in jsMatches {
            if match.range.location > start {
                let tmp = ns.substring(with: NSRange(location: start, length: match.range.location - start))
                    .trimmingCharacters(in: .whitespaces)
                if !tmp.isEmpty { ruleList.append(SourceRule(analyze: self, ruleStr: tmp, mode: mode)) }
            }
            // 两个捕获组只会命中一个，未命中的 range 是 NSNotFound，必须走带兜底的切片
            let group2 = ns.substring(with: match.range(at: 2), fallback: "")
            let group1 = ns.substring(with: match.range(at: 1), fallback: "")
            ruleList.append(SourceRule(analyze: self, ruleStr: group2.isEmpty ? group1 : group2, mode: .js))
            start = match.range.location + match.range.length
        }

        let webMatches = Self.webJsPattern.matches(in: ruleStr, options: [], range: NSRange(location: 0, length: ns.length))
        for match in webMatches {
            if match.range.location > start {
                let tmp = ns.substring(with: NSRange(location: start, length: match.range.location - start))
                    .trimmingCharacters(in: .whitespaces)
                if !tmp.isEmpty { ruleList.append(SourceRule(analyze: self, ruleStr: tmp, mode: mode)) }
            }
            let group1 = ns.substring(with: match.range(at: 1), fallback: "")
            ruleList.append(SourceRule(analyze: self, ruleStr: group1, mode: .webJs))
            start = match.range.location + match.range.length
        }

        if ns.length > start {
            let tmp = ns.substring(from: start).trimmingCharacters(in: .whitespaces)
            if !tmp.isEmpty { ruleList.append(SourceRule(analyze: self, ruleStr: tmp, mode: mode)) }
        }
        return ruleList
    }

    // MARK: - 替换

    private func replaceRegex(_ result: String, _ rule: SourceRule) -> String {
        guard !rule.replaceRegex.isEmpty else { return result }
        guard let regex = RegexCache.shared.regex(rule.replaceRegex) else {
            return result.replacingOccurrences(of: rule.replaceRegex, with: rule.replacement)
        }
        if rule.replaceFirst {
            guard let match = regex.firstMatch(in: result, options: [],
                                               range: NSRange(location: 0, length: result.utf16Count)) else {
                return rule.replacement
            }
            let matched = (result as NSString).substring(with: match.range)
            return matched.replacingRegex(rule.replaceRegex, with: rule.replacement)
        }
        return regex.stringByReplacingMatches(in: result, options: [],
                                              range: NSRange(location: 0, length: result.utf16Count),
                                              withTemplate: rule.replacement)
    }

    // MARK: - 静态工具

    static func stringValue(_ value: Any?) -> String {
        guard let value else { return "" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let d = value as? Double {
            if d.truncatingRemainder(dividingBy: 1) == 0 { return String(format: "%.0f", d) }
            return "\(d)"
        }
        if let i = value as? Int { return "\(i)" }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let dict = value as? [String: Any] {
            return JSONTool.stringify(dict) ?? ""
        }
        if let array = value as? [Any] {
            return array.map { stringValue($0) }.joined(separator: "\n")
        }
        if let node = value as? XPathNode { return node.stringValue }
        if let element = value as? SwiftSoup.Element { return (try? element.text()) ?? "" }
        return "\(value)"
    }

    private static let jsPattern = try! NSRegularExpression(
        pattern: "<js>([\\w\\W]*?)</js>|@js:([\\w\\W]*)",
        options: [.caseInsensitive]
    )

    private static let webJsPattern = try! NSRegularExpression(
        pattern: "@webjs:([\\w\\W]{5,})",
        options: [.caseInsensitive]
    )

    static let putPattern = try! NSRegularExpression(
        pattern: "@put:(\\{[^}]+?\\})",
        options: [.caseInsensitive]
    )

    static let evalPattern = try! NSRegularExpression(
        pattern: "@get:\\{[^}]+?\\}|\\{\\{[\\w\\W]*?\\}\\}",
        options: [.caseInsensitive]
    )

    static let dollarPattern = try! NSRegularExpression(
        pattern: "\\$\\d{1,2}",
        options: []
    )

    // MARK: - 规则对象

    final class SourceRule {
        private unowned let analyze: AnalyzeRule
        private(set) var rule: String
        private(set) var mode: Mode
        private(set) var replaceRegex = ""
        private(set) var replacement = ""
        private(set) var replaceFirst = false
        private(set) var putMap: [String: String] = [:]

        private var ruleParam: [String] = []
        private var ruleType: [Int] = []

        private let getRuleType = -2
        private let jsRuleType = -1
        private let defaultRuleType = 0

        init(analyze: AnalyzeRule, ruleStr: String, mode: Mode = .default) {
            self.analyze = analyze
            var working = ruleStr
            var mode = mode

            if mode == .js || mode == .regex {
                // 保持原样
            } else if ruleStr.lowercased().hasPrefix("@css:") {
                mode = .default
            } else if ruleStr.hasPrefix("@@") {
                mode = .default
                working = String(ruleStr.dropFirst(2))
            } else if ruleStr.lowercased().hasPrefix("@xpath:") {
                mode = .xpath
                working = String(ruleStr.dropFirst(7))
            } else if ruleStr.lowercased().hasPrefix("@json:") {
                mode = .json
                working = String(ruleStr.dropFirst(6))
            } else if analyze.isJSON || ruleStr.hasPrefix("$.") || ruleStr.hasPrefix("$[") {
                mode = .json
            } else if ruleStr.hasPrefix("/") {
                mode = .xpath
            }

            self.mode = mode
            self.rule = working

            // 分离 @put
            self.rule = splitPutRule(self.rule)

            // 拆 @get / {{ }} / $n
            let ns = self.rule as NSString
            let full = NSRange(location: 0, length: ns.length)
            var start = 0

            if let first = AnalyzeRule.evalPattern.firstMatch(in: self.rule, options: [], range: full) {
                let prefix = ns.substring(to: first.range.location)
                if mode != .js && mode != .regex && (first.range.location == 0 || !prefix.contains("##")) {
                    self.mode = .regex
                    mode = .regex
                }
            }

            for match in AnalyzeRule.evalPattern.matches(in: self.rule, options: [], range: full) {
                if match.range.location > start {
                    let tmp = ns.substring(with: NSRange(location: start, length: match.range.location - start))
                    splitRegex(tmp)
                }
                let tmp = ns.substring(with: match.range)
                if tmp.lowercased().hasPrefix("@get:") {
                    ruleType.append(getRuleType)
                    ruleParam.append(String(tmp.dropFirst(6).dropLast()))
                } else if tmp.hasPrefix("{{") {
                    ruleType.append(jsRuleType)
                    ruleParam.append(String(tmp.dropFirst(2).dropLast(2)))
                } else {
                    splitRegex(tmp)
                }
                start = match.range.location + match.range.length
            }
            if ns.length > start {
                splitRegex(ns.substring(from: start))
            }
        }

        private func splitPutRule(_ ruleStr: String) -> String {
            var result = ruleStr
            let ns = result as NSString
            let matches = AnalyzeRule.putPattern.matches(in: result, options: [],
                                                        range: NSRange(location: 0, length: ns.length))
            for match in matches {
                result = result.replacingOccurrences(of: ns.substring(with: match.range), with: "")
                let json = ns.substring(with: match.range(at: 1))
                if let obj = JSONTool.parseObject(json) as [String: Any]? {
                    for (k, v) in obj {
                        if let s = v as? String {
                            putMap[k] = s
                        } else {
                            putMap[k] = JSONTool.stringify(v)
                        }
                    }
                }
            }
            return result
        }

        private func splitRegex(_ ruleStr: String) {
            var start = 0
            let parts = ruleStr.components(separatedBy: "##")
            let head = parts.first ?? ""
            if head.containsRegex("\\$\\d{1,2}") {
                if mode != .js && mode != .regex { mode = .regex }
            }
            // `$n` 只在首段里找；但切片必须用整串，把 `##正则##替换` 保留下来，
            // 否则 makeUpRule 拿到的 rule 里已经没有 `##`，替换规则会丢。
            let headNS = head as NSString
            let matches = AnalyzeRule.dollarPattern.matches(in: head, options: [],
                                                           range: NSRange(location: 0, length: headNS.length))
            for match in matches {
                if match.range.location > start {
                    ruleType.append(defaultRuleType)
                    ruleParam.append(headNS.substring(with: NSRange(location: start,
                                                                   length: match.range.location - start)))
                }
                let value = headNS.substring(with: match.range)
                ruleType.append(Int(value.dropFirst()) ?? 0)
                ruleParam.append(value)
                start = match.range.location + match.range.length
            }
            let ns = ruleStr as NSString
            if ns.length > start {
                ruleType.append(defaultRuleType)
                ruleParam.append(ns.substring(from: start))
            }
        }

        var paramCount: Int { ruleParam.count }

        /// 回填 `@get` / `{{}}` / `$n`，并拆出 `##替换`
        func makeUpRule(result: Any?) {
            if !ruleParam.isEmpty {
                var infoVal = ""
                var index = ruleParam.count
                while index > 0 {
                    index -= 1
                    let regType = ruleType[index]
                    if regType > defaultRuleType {
                        if let list = result as? [Any], list.count > regType {
                            infoVal = AnalyzeRule.stringValue(list[regType]) + infoVal
                        } else if !(result is [Any]) {
                            infoVal = ruleParam[index] + infoVal
                        }
                    } else if regType == jsRuleType {
                        let param = ruleParam[index]
                        if isRule(param) {
                            infoVal = analyze.getString(param) + infoVal
                        } else {
                            let value = analyze.evalJS(param, result: result)
                            if let value {
                                infoVal = AnalyzeRule.stringValue(value) + infoVal
                            }
                        }
                    } else if regType == getRuleType {
                        infoVal = analyze.get(ruleParam[index]) + infoVal
                    } else {
                        infoVal = ruleParam[index] + infoVal
                    }
                }
                rule = infoVal
            }

            let parts = rule.components(separatedBy: "##")
            rule = (parts.first ?? "").trimmed
            if parts.count > 1 { replaceRegex = parts[1] }
            if parts.count > 2 { replacement = parts[2] }
            if parts.count > 3 { replaceFirst = true }
        }

        private func isRule(_ ruleStr: String) -> Bool {
            ruleStr.hasPrefix("@") || ruleStr.hasPrefix("$.") || ruleStr.hasPrefix("$[") || ruleStr.hasPrefix("//")
        }
    }
}

// MARK: - 全局变量 / 内存

/// 书源级变量（`java.put` / `java.get`、`@put` 无书籍上下文时）
final class AppVariableStore {
    static let shared = AppVariableStore()
    private var map: [String: [String: String]] = [:]
    private let lock = NSLock()

    func put(_ sourceKey: String, _ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        map[sourceKey, default: [:]][key] = value
    }

    func get(_ sourceKey: String, _ key: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return map[sourceKey]?[key] ?? ""
    }
}

/// 搜索/发现用的临时变量容器
final class RuleData: RuleDataInterface {
    var variableMap: [String: String] = [:]

    @discardableResult
    func putVariable(_ key: String, _ value: String?) -> Bool {
        variableMap[key] = value ?? ""
        return true
    }
}

extension AnalyzeRule: JSVariableStore {
    func jsGet(_ key: String) -> String { get(key) }
    func jsPut(_ key: String, _ value: String) { _ = put(key, value) }
}

// MARK: - NSString 安全切片

extension NSString {
    func substring(with range: NSRange, fallback: String) -> String {
        guard range.location != NSNotFound, range.location + range.length <= length else { return fallback }
        return substring(with: range)
    }
}
