import Foundation
import JavaScriptCore
import SwiftSoup

// MARK: - 变量读写

protocol JSVariableStore: AnyObject {
    func jsGet(_ key: String) -> String
    func jsPut(_ key: String, _ value: String)
}

// MARK: - 评估环境

struct JSEnvironment {
    var source: BookSource?
    var book: Book?
    var chapter: BookChapter?
    var baseUrl: String?
    var result: Any?
    var content: Any?
    var page: Int?
    var key: String?
    var nextChapterUrl: String?
    var title: String?
    /// formatJs 里可用的 1 基章节序号
    var index: Int?
    var infoMap: [String: String]?
    var fromBookInfo: Bool = false
    /// callBackJs 的事件名
    var event: String?
    var ajax: ((String, Double?) -> String)?
    /// java.get / post / connect / ajaxAll 共用。返回 nil 表示环境不支持
    var request: ((JSHttpRequest) -> JSHttpResult?)?
    var requestAll: (([JSHttpRequest]) -> [JSHttpResult])?
    /// 需要原始字节的接口（图片解密、downloadFile）
    var dataRequest: ((JSHttpRequest) -> Data?)?
    /// 规则求值（java.getString / getElements 复用当前 AnalyzeRule）
    var analyzer: AnalyzeRule?
    var variables: JSVariableStore?
    /// 隐藏 WKWebView（java.webView / webViewGetSource / webViewGetOverrideUrl）
    var webView: ((_ html: String?, _ url: String?, _ js: String?,
                   _ sourceRegex: String?, _ overrideUrlRegex: String?,
                   _ delayMs: Int) -> String?)?
    var toast: ((String) -> Void)?
    var settings: AppSettings?
}

// MARK: - Java 互操作（对应上游 `java` 变量）

@objc protocol JSJavaExports: JSExport {
    // 网络。JSExport 同名方法只能导出一个（按参数最多的那个声明），
    // 少传的参数 JSC 会补 nil，所以这里不再声明 1/2 参重载。
    func ajax(_ url: Any?, _ timeout: NSNumber?) -> String?
    func ajaxAll(_ urls: [String], _ skipRateLimit: NSNumber?) -> [JSResponse]?
    func ajaxTestAll(_ urls: [String], _ timeout: NSNumber?, _ skipRateLimit: NSNumber?) -> [JSResponse]?
    func connect(_ url: String, _ header: Any?, _ timeout: NSNumber?) -> JSResponse?
    func get(_ url: String, _ headers: Any?, _ timeout: NSNumber?) -> JSResponse?
    func head(_ url: String, _ headers: Any?, _ timeout: NSNumber?) -> JSResponse?
    func post(_ url: String, _ body: String?, _ headers: Any?, _ timeout: NSNumber?) -> JSResponse?
    func webView(_ html: String?, _ url: String?, _ js: String?,
                 _ cacheFirst: NSNumber?) -> String?
    func webViewGetSource(_ html: String?, _ url: String?, _ js: String?,
                          _ sourceRegex: String?, _ cacheFirst: NSNumber?,
                          _ delayMs: NSNumber?) -> String?
    func webViewGetOverrideUrl(_ html: String?, _ url: String?, _ js: String?,
                               _ overrideUrlRegex: String?, _ cacheFirst: NSNumber?,
                               _ delayMs: NSNumber?) -> String?
    // 浏览器 / 验证码（iOS 不弹窗，记日志并返回空，避免书源 JS 抛错）
    func startBrowser(_ url: String, _ title: String)
    func startBrowserAwait(_ url: String, _ title: String) -> JSResponse?
    func getVerificationCode(_ imageUrl: String) -> String

    // 编码 / 摘要
    func base64Encode(_ text: String?, _ flags: Any?) -> String?
    func base64Decode(_ text: String?, _ arg: Any?) -> String?
    func base64DecodeToByteArray(_ text: String?) -> [Int]?
    func hexEncodeToString(_ text: String?) -> String?
    func hexDecodeToString(_ text: String?) -> String?
    func hexDecodeToByteArray(_ text: String?) -> [Int]?
    func md5Encode(_ text: String?) -> String?
    func md5Encode16(_ text: String?) -> String?
    func encodeURI(_ text: String?, _ charset: String?) -> String?
    func htmlFormat(_ html: String?) -> String?
    func timeFormat(_ time: NSNumber?) -> String?
    func timeFormatUTC(_ time: NSNumber?, _ format: String?, _ sh: NSNumber?) -> String?
    func strToBytes(_ text: String?, _ charset: String?) -> [Int]?
    func bytesToStr(_ bytes: Any?, _ charset: String?) -> String?

    // 规则 / 变量 / 缓存
    func getString(_ rule: String?, _ content: Any?, _ isUrl: NSNumber?) -> String
    func getStringList(_ rule: String?, _ content: Any?, _ isUrl: NSNumber?) -> [String]?
    func getElement(_ rule: String?) -> JSElement?
    func getElements(_ rule: String?) -> JSElements?
    func put(_ key: String, _ value: String?) -> String?
    func getFromCache(_ key: String) -> String?
    func toNumChapter(_ text: String?) -> String?

    // 文件（书源可写目录内）
    func importScript(_ path: String) -> String
    func cacheFile(_ url: String, _ saveTime: NSNumber?) -> String
    func downloadFile(_ url: String) -> String
    func readTxtFile(_ path: String, _ charset: String?) -> String
    func readFile(_ path: String) -> [Int]?
    func deleteFile(_ path: String) -> Bool
    func getTxtInFolder(_ path: String) -> String

    // 杂项
    func getSource() -> JSSourceBridge?
    func getTag() -> String?
    func log(_ message: Any?) -> Any?
    func toast(_ message: Any?)
    func longToast(_ message: Any?)
    func logType(_ any: Any?)
    func getCookie(_ tag: String, _ key: String?) -> String?
    func clearCookie(_ tag: String)
    func randomUUID() -> String
    func getWebViewUA() -> String
    func getReadBookConfig() -> String
    func getReadBookConfigMap() -> [String: Any]
    func getThemeMode() -> String
    func getThemeConfig() -> String
    func t2s(_ text: String?) -> String?
    func s2t(_ text: String?) -> String?
    func openUrl(_ url: String)
}

@objc final class JSJavaBridge: NSObject, JSJavaExports {
    var env: JSEnvironment
    var cookieStore: CookieStore?
    var sourceKey: String?

    init(env: JSEnvironment, cookieStore: CookieStore?) {
        self.env = env
        self.cookieStore = cookieStore
    }

    private var tag: String { env.source?.bookSourceName ?? sourceKey ?? "" }

    // MARK: 网络

    func ajax(_ url: Any?, _ timeout: NSNumber?) -> String? {
        let urlStr: String
        if let list = url as? [Any], let first = list.first {
            urlStr = "\(first)"
        } else {
            urlStr = "\(url ?? "")"
        }
        guard let handler = env.ajax else {
            DebugLog.shared.log(sourceKey, "≡JS 环境未提供 ajax")
            return nil
        }
        return handler(urlStr, timeout?.doubleValue)
    }

    func ajaxAll(_ urls: [String], _ skipRateLimit: NSNumber?) -> [JSResponse]? {
        // 上游 `skipRateLimit` 只是跳过并发率；iOS 侧并发率在 AnalyzeUrl 内统一处理，
        // 这里保持参数兼容即可（书源里传 true 的很少）。
        _ = skipRateLimit
        let requests = urls.map { JSHttpRequest(url: $0) }
        let results = env.requestAll?(requests) ?? requests.compactMap { env.request?($0) }
        return results.map { JSResponse(result: $0) }
    }

    func ajaxTestAll(_ urls: [String], _ timeout: NSNumber?, _ skipRateLimit: NSNumber?) -> [JSResponse]? {
        _ = timeout
        return ajaxAll(urls, skipRateLimit)
    }

    func connect(_ url: String, _ header: Any?, _ timeout: NSNumber?) -> JSResponse? {
        send(JSHttpRequest(url: url, timeout: timeout?.doubleValue,
                           headers: Self.parseHeaders(header)))
    }

    func get(_ url: String, _ headers: Any?, _ timeout: NSNumber?) -> JSResponse? {
        send(JSHttpRequest(url: url, timeout: timeout?.doubleValue,
                           headers: Self.parseHeaders(headers)))
    }

    func head(_ url: String, _ headers: Any?, _ timeout: NSNumber?) -> JSResponse? {
        send(JSHttpRequest(url: url, method: "HEAD", timeout: timeout?.doubleValue,
                           headers: Self.parseHeaders(headers)))
    }

    func post(_ url: String, _ body: String?, _ headers: Any?, _ timeout: NSNumber?) -> JSResponse? {
        send(JSHttpRequest(url: url, method: "POST", body: body,
                           timeout: timeout?.doubleValue,
                           headers: Self.parseHeaders(headers)))
    }

    func webView(_ html: String?, _ url: String?, _ js: String?,
                 _ cacheFirst: NSNumber?) -> String? {
        guard let handler = env.webView else {
            DebugLog.shared.log(sourceKey, "≡JS 环境未提供 WebView")
            return nil
        }
        _ = cacheFirst
        return handler(html, url, js, nil, nil, 0)
    }

    func webViewGetSource(_ html: String?, _ url: String?, _ js: String?,
                          _ sourceRegex: String?, _ cacheFirst: NSNumber?,
                          _ delayMs: NSNumber?) -> String? {
        guard let handler = env.webView else { return nil }
        _ = cacheFirst
        return handler(html, url, js, sourceRegex, nil, delayMs?.intValue ?? 0)
    }

    func webViewGetOverrideUrl(_ html: String?, _ url: String?, _ js: String?,
                               _ overrideUrlRegex: String?, _ cacheFirst: NSNumber?,
                               _ delayMs: NSNumber?) -> String? {
        guard let handler = env.webView else { return nil }
        _ = cacheFirst
        return handler(html, url, js, nil, overrideUrlRegex, delayMs?.intValue ?? 0)
    }

    func startBrowser(_ url: String, _ title: String) {
        DebugLog.shared.log(tag, "≡startBrowser 在 iOS 端暂不支持：\(title) \(url)")
    }

    func startBrowserAwait(_ url: String, _ title: String) -> JSResponse? {
        DebugLog.shared.log(tag, "≡startBrowserAwait 在 iOS 端暂不支持：\(title) \(url)")
        return JSResponse(url: url, body: "")
    }

    func getVerificationCode(_ imageUrl: String) -> String {
        DebugLog.shared.log(tag, "≡getVerificationCode 在 iOS 端暂不支持：\(imageUrl)")
        return ""
    }

    private func send(_ request: JSHttpRequest) -> JSResponse? {
        guard let handler = env.request else {
            // 没有 request 钩子时退回旧的 ajax（至少能拿到正文）
            if request.method == "GET", let text = env.ajax?(request.url, nil) {
                return JSResponse(result: JSHttpResult(url: request.url, code: 200,
                                                       body: text, headers: [:]))
            }
            DebugLog.shared.log(sourceKey, "≡JS 环境未提供 request")
            return nil
        }
        guard let result = handler(request) else { return nil }
        return JSResponse(result: result)
    }

    /// headers 允许是对象字面量、JSON 字符串或 null。
    /// JS 对象字面量经 JSExport 过来可能是 JSValue（大多数情况）或 NSDictionary。
    static func parseHeaders(_ raw: Any?) -> [String: String] {
        guard let raw else { return [:] }
        if let value = raw as? JSValue {
            if value.isObject, let dict = value.toDictionary() as? [String: Any] {
                return parseHeaders(dict)
            }
            if value.isString, let text = value.toString() {
                return parseHeaders(text)
            }
            return [:]
        }
        if let dict = raw as? [String: Any] {
            return dict.reduce(into: [:]) { out, pair in
                out[pair.key] = AnalyzeRule.stringValue(pair.value)
            }
        }
        if let text = raw as? String {
            if let parsed = JSONTool.parseObject(text) {
                return parsed.reduce(into: [:]) { out, pair in
                    out[pair.key] = AnalyzeRule.stringValue(pair.value)
                }
            }
            // 也接受 `a=b; c=d` 形式
            var result: [String: String] = [:]
            for pair in text.components(separatedBy: CharacterSet(charactersIn: ";\n")) {
                let parts = pair.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2, !parts[0].isEmpty { result[parts[0]] = parts[1] }
            }
            return result
        }
        return [:]
    }

    // MARK: 编码 / 摘要

    func base64Encode(_ text: String?, _ flags: Any?) -> String? {
        // 上游 flags 控制 NO_WRAP/URL_SAFE；书源里传 2 表示无换行，Data.base64 默认即无换行
        _ = flags
        guard let text else { return nil }
        return CryptoUtils.base64Encode(text)
    }

    func base64Decode(_ text: String?, _ arg: Any?) -> String? {
        guard let text else { return nil }
        if let charset = arg as? String, !charset.isEmpty {
            guard let data = CryptoUtils.base64DecodeData(text) else { return nil }
            return String(data: data, encoding: EncodingDetect.stringEncoding(for: charset))
        }
        // 数字 flags：忽略（iOS 的 Data 解码默认宽容）
        return CryptoUtils.base64Decode(text)
    }

    func base64DecodeToByteArray(_ text: String?) -> [Int]? {
        guard let text, let data = CryptoUtils.base64DecodeData(text) else { return nil }
        return data.map { Int($0) }
    }

    func hexEncodeToString(_ text: String?) -> String? {
        guard let text else { return nil }
        return CryptoUtils.hexEncode(text)
    }

    func hexDecodeToString(_ text: String?) -> String? {
        guard let text else { return nil }
        return CryptoUtils.hexDecodeToString(text)
    }

    func hexDecodeToByteArray(_ text: String?) -> [Int]? {
        guard let text, let data = CryptoUtils.hexDecode(text) else { return nil }
        return data.map { Int($0) }
    }

    func md5Encode(_ text: String?) -> String? {
        guard let text else { return nil }
        return CryptoUtils.md5(text)
    }

    func md5Encode16(_ text: String?) -> String? {
        guard let text else { return nil }
        let md5 = CryptoUtils.md5(text)
        guard md5.count >= 24 else { return md5 }
        let start = md5.index(md5.startIndex, offsetBy: 8)
        let end = md5.index(md5.startIndex, offsetBy: 24)
        return String(md5[start..<end])
    }

    func encodeURI(_ text: String?, _ charset: String?) -> String? {
        guard let text else { return nil }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "*-._!~*'()"))
        if let charset, !charset.isEmpty,
           EncodingDetect.stringEncoding(for: charset) != .utf8 {
            // 非 UTF-8（书源里常见 GBK）：按字节百分号编码
            guard let data = text.data(using: EncodingDetect.stringEncoding(for: charset)) else {
                return text.addingPercentEncoding(withAllowedCharacters: allowed)
            }
            return data.map { byte -> String in
                let scalar = UnicodeScalar(byte)
                if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                    || "-_.!~*'()".unicodeScalars.contains(scalar) {
                    return String(Character(scalar))
                }
                return String(format: "%%%02X", byte)
            }.joined()
        }
        return text.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    func htmlFormat(_ html: String?) -> String? {
        HtmlFormatter.formatKeepImg(html ?? "", redirectUrl: nil)
    }

    func timeFormat(_ time: NSNumber?) -> String? {
        guard let time else { return nil }
        let value = time.doubleValue > 10_000_000_000 ? time.doubleValue / 1000 : time.doubleValue
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: value))
    }

    func timeFormatUTC(_ time: NSNumber?, _ format: String?, _ sh: NSNumber?) -> String? {
        guard let time else { return nil }
        let value = time.doubleValue > 10_000_000_000 ? time.doubleValue / 1000 : time.doubleValue
        let formatter = DateFormatter()
        formatter.dateFormat = (format?.isEmpty == false) ? format : "yyyy/MM/dd HH:mm"
        // 对齐 SimpleTimeZone(sh, "UTC")：小时偏移量，东八区传 8
        let hours = sh?.intValue ?? 0
        formatter.timeZone = TimeZone(secondsFromGMT: hours * 3600)
        return formatter.string(from: Date(timeIntervalSince1970: value))
    }

    func strToBytes(_ text: String?, _ charset: String?) -> [Int]? {
        guard let text else { return nil }
        let encoding = charset.map { EncodingDetect.stringEncoding(for: $0) } ?? .utf8
        guard let data = text.data(using: encoding) else { return nil }
        return data.map { Int($0) }
    }

    func bytesToStr(_ bytes: Any?, _ charset: String?) -> String? {
        guard let data = Self.data(from: bytes) else { return nil }
        let encoding = charset.map { EncodingDetect.stringEncoding(for: $0) } ?? .utf8
        return String(data: data, encoding: encoding)
    }

    // MARK: 规则

    func getString(_ rule: String?, _ content: Any?, _ isUrl: NSNumber?) -> String {
        guard let analyzer = env.analyzer, let rule, !rule.isEmpty else { return "" }
        let target = content.map { Self.unwrap($0) }
        return analyzer.getString(rule, mContent: target, isUrl: isUrl?.boolValue ?? false)
    }

    func getStringList(_ rule: String?, _ content: Any?, _ isUrl: NSNumber?) -> [String]? {
        guard let analyzer = env.analyzer, let rule, !rule.isEmpty else { return nil }
        let target = content.map { Self.unwrap($0) }
        return analyzer.getStringList(rule, mContent: target, isUrl: isUrl?.boolValue ?? false)
    }

    func getElement(_ rule: String?) -> JSElement? {
        guard let analyzer = env.analyzer, let rule, !rule.isEmpty else { return nil }
        return analyzer.getElement(rule).map { JSElement($0) }
    }

    func getElements(_ rule: String?) -> JSElements? {
        guard let analyzer = env.analyzer, let rule, !rule.isEmpty else { return nil }
        return JSElements(analyzer.getElements(rule))
    }

    func put(_ key: String, _ value: String?) -> String? {
        env.variables?.jsPut(key, value ?? "")
        return value
    }

    func getFromCache(_ key: String) -> String? {
        env.variables?.jsGet(key)
    }

    func toNumChapter(_ text: String?) -> String? {
        guard let text else { return nil }
        // 仅处理书源里常见的「第X章」数字中文/阿拉伯数字，避免引入完整汉字数字库
        let pattern = "^(.*?)([0-9]+|[零一二三四五六七八九十百千万两]+)(.*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges >= 4 else { return text }
        let ns = text as NSString
        let numberText = ns.substring(with: match.range(at: 2))
        guard let number = Self.chineseNumber(numberText) else { return text }
        return ns.substring(with: match.range(at: 1)) + "\(number)" + ns.substring(with: match.range(at: 3))
    }

    // MARK: 文件

    func importScript(_ path: String) -> String {
        if path.lowercased().hasPrefix("http") {
            return cacheFile(path, nil)
        }
        return readTxtFile(path, nil)
    }

    func cacheFile(_ url: String, _ saveTime: NSNumber?) -> String {
        let key = CryptoUtils.md5(url)
        let path = "cache/\(key).txt"
        let seconds = saveTime?.doubleValue ?? 0
        if let file = JSFileStore.resolve(path),
           let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attributes[.modificationDate] as? Date {
            let alive = seconds <= 0 || Date().timeIntervalSince(modified) < seconds
            if alive, let text = try? String(contentsOf: file, encoding: .utf8) {
                return text
            }
        }
        guard let data = env.dataRequest?(JSHttpRequest(url: url)) ?? requestData(url) else {
            DebugLog.shared.log(tag, "≡cacheFile 下载失败：\(url)")
            return ""
        }
        let text = EncodingDetect.decode(data, charset: EncodingDetect.htmlEncoding(data))
        JSFileStore.write(path, text: text)
        return text
    }

    func downloadFile(_ url: String) -> String {
        guard let data = env.dataRequest?(JSHttpRequest(url: url)) ?? requestData(url) else {
            DebugLog.shared.log(tag, "≡downloadFile 下载失败：\(url)")
            return ""
        }
        var ext = URL(string: url)?.pathExtension ?? "bin"
        if ext.isEmpty { ext = "bin" }
        let path = "download/\(CryptoUtils.md5(url)).\(ext)"
        JSFileStore.write(path, data: data)
        return path
    }

    func readTxtFile(_ path: String, _ charset: String?) -> String {
        guard let file = JSFileStore.resolve(path), FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file) else { return "" }
        if let charset, !charset.isEmpty,
           let text = String(data: data, encoding: EncodingDetect.stringEncoding(for: charset)) {
            return text
        }
        return EncodingDetect.decode(data, charset: EncodingDetect.htmlEncoding(data))
    }

    func readFile(_ path: String) -> [Int]? {
        guard let file = JSFileStore.resolve(path),
              let data = try? Data(contentsOf: file) else { return nil }
        return data.map { Int($0) }
    }

    func deleteFile(_ path: String) -> Bool {
        guard let file = JSFileStore.resolve(path) else { return false }
        return (try? FileManager.default.removeItem(at: file)) != nil
    }

    func getTxtInFolder(_ path: String) -> String {
        guard let folder = JSFileStore.resolve(path) else { return "" }
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder,
                                                                       includingPropertiesForKeys: nil)
        else { return "" }
        var parts: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let data = try? Data(contentsOf: file) {
                parts.append(EncodingDetect.decode(data, charset: EncodingDetect.htmlEncoding(data)))
            }
        }
        try? FileManager.default.removeItem(at: folder)
        return parts.joined(separator: "\n")
    }

    private func requestData(_ url: String) -> Data? {
        guard let envHandler = env.dataRequest else { return nil }
        return envHandler(JSHttpRequest(url: url))
    }

    // MARK: 杂项

    func getSource() -> JSSourceBridge? {
        env.source.map { JSSourceBridge($0) }
    }

    func getTag() -> String? {
        env.source?.bookSourceName
    }

    func log(_ message: Any?) -> Any? {
        DebugLog.shared.log(tag, "\(message ?? "")")
        return message
    }

    func toast(_ message: Any?) {
        let text = "\(message ?? "")"
        DebugLog.shared.log(tag, "⇒\(text)")
        env.toast?(text)
    }

    func longToast(_ message: Any?) {
        toast(message)
    }

    func logType(_ any: Any?) {
        guard let any else {
            log("null")
            return
        }
        log(type(of: any))
    }

    func getCookie(_ tag: String, _ key: String?) -> String? {
        guard let key else { return cookieStore?.getCookie(tag) }
        return cookieStore?.getKey(tag, key)
    }

    func clearCookie(_ tag: String) {
        cookieStore?.removeCookie(tag)
    }

    func randomUUID() -> String {
        UUID().uuidString
    }

    func getWebViewUA() -> String {
        env.settings?.userAgent ?? AppSettings.defaultUserAgent
    }

    func getReadBookConfig() -> String {
        "{}"
    }

    func getReadBookConfigMap() -> [String: Any] {
        [:]
    }

    func getThemeMode() -> String {
        "light"
    }

    func getThemeConfig() -> String {
        "{}"
    }

    func t2s(_ text: String?) -> String? {
        text
    }

    func s2t(_ text: String?) -> String? {
        text
    }

    func openUrl(_ url: String) {
        DebugLog.shared.log(tag, "≡openUrl：\(url)")
    }

    // MARK: 转换工具

    /// JS 数组 / JSValue / NSArray → Data
    static func data(from value: Any?) -> Data? {
        guard let value else { return nil }
        if let data = value as? Data { return data }
        if let list = value as? [Any] {
            var data = Data()
            data.reserveCapacity(list.count)
            for item in list {
                if let number = item as? NSNumber {
                    data.append(UInt8(truncatingIfNeeded: number.intValue))
                } else if let int = item as? Int {
                    data.append(UInt8(truncatingIfNeeded: int))
                } else if let double = item as? Double {
                    data.append(UInt8(truncatingIfNeeded: Int(double)))
                }
            }
            return data
        }
        if let value = value as? JSValue, let list = value.toArray() {
            return data(from: list)
        }
        return nil
    }

    /// JS 侧传入的 content 可能是 JSValue / JSElement，统一还原成 AnalyzeRule 能吃的值
    static func unwrap(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if let element = value as? JSElement { return element.rawValue }
        if let value = value as? JSValue {
            if value.isUndefined || value.isNull { return nil }
            if value.isString { return value.toString() }
            if value.isNumber { return value.toNumber() }
            if value.isArray || value.isObject { return JSRuntime.toSwift(value) }
            return value.toObject()
        }
        return value
    }

    static func chineseNumber(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                                        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "万": 10000]
        var total = 0
        var section = 0
        var number = 0
        for char in text {
            if let digit = digits[char] {
                number = digit
            } else if let unit = units[char] {
                if unit == 10000 {
                    section = (section + number) * unit
                    total += section
                    section = 0
                } else {
                    section += (number == 0 ? 1 : number) * unit
                }
                number = 0
            } else {
                return nil
            }
        }
        return total + section + number
    }
}

// MARK: - 响应对象（对应 Jsoup Connection.Response / 上游 StrResponse）

@objc protocol JSResponseExports: JSExport {
    func body() -> String?
    func url() -> String
    func code() -> Int
    func statusCode() -> Int
    func statusMessage() -> String?
    func contentType() -> String?
    func charset() -> String?
    func header(_ name: String) -> String?
    func headers() -> [String: String]
    func cookies() -> JSCookies
    /// 书源里常见 `String(resp)`，需要把对象直接转成正文
    func toString() -> String
}

@objc final class JSResponse: NSObject, JSResponseExports {
    let responseURL: String
    let responseBody: String
    let responseCode: Int
    let responseMessage: String
    let responseHeaders: [String: String]

    init(url: String, body: String, code: Int = 200, message: String = "OK",
         headers: [String: String] = [:]) {
        self.responseURL = url
        self.responseBody = body
        self.responseCode = code
        self.responseMessage = message
        self.responseHeaders = headers
    }

    convenience init(result: JSHttpResult) {
        self.init(url: result.url, body: result.body, code: result.code,
                  message: result.message, headers: result.headers)
    }

    func body() -> String? { responseBody }
    func url() -> String { responseURL }
    func code() -> Int { responseCode }
    func statusCode() -> Int { responseCode }
    func statusMessage() -> String? { responseMessage }
    func headers() -> [String: String] { responseHeaders }
    func toString() -> String { responseBody }

    func contentType() -> String? { header("Content-Type") }
    func charset() -> String? {
        guard let type = header("Content-Type"),
              let range = type.range(of: "charset=([\\w\\-]+)", options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return String(type[range]).replacingOccurrences(of: "charset=", with: "",
                                                        options: .caseInsensitive)
    }

    func header(_ name: String) -> String? {
        if let exact = responseHeaders[name] { return exact }
        let lower = name.lowercased()
        return responseHeaders.first { $0.key.lowercased() == lower }?.value
    }

    func cookies() -> JSCookies {
        JSCookies(Self.cookieMap(from: responseHeaders))
    }

    private static func cookieMap(from headers: [String: String]) -> [String: String] {
        guard let raw = headers.first(where: { $0.key.lowercased() == "set-cookie" })?.value
        else { return [:] }
        var result: [String: String] = [:]
        for item in HTTPClient.splitCombinedSetCookie(raw) {
            let head = item.split(separator: ";", maxSplits: 1).first.map(String.init) ?? item
            let parts = head.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                result[parts[0].trimmingCharacters(in: .whitespaces)] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }
}

/// Java `Map<String,String>` 的替身：书源里常用 `.toString()` 拼 cookie 头
@objc protocol JSCookiesExports: JSExport {
    func get(_ key: String) -> String?
    func size() -> Int
    func toString() -> String
}

@objc final class JSCookies: NSObject, JSCookiesExports {
    private let map: [String: String]
    init(_ map: [String: String]) { self.map = map }

    func get(_ key: String) -> String? { map[key] }
    func size() -> Int { map.count }
    func toString() -> String {
        "{" + map.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + "}"
    }
}

// MARK: - JS 侧 Element / Elements

@objc protocol JSElementExports: JSExport {
    /// 无参取文本，带参设置文本（JSExport 同名只能导出一个，靠 value 是否为 nil 区分）
    func text(_ value: Any?) -> Any?
    func ownText() -> String?
    func textNodes() -> String?
    func html() -> String?
    func outerHtml() -> String?
    func attr(_ name: String, _ value: Any?) -> Any?
    func select(_ rule: String) -> JSElements?
    func toString() -> String
}

@objc final class JSElement: NSObject, JSElementExports {
    private let element: SwiftSoup.Element?
    private let node: XPathNode?

    init(_ value: Any) {
        if let element = value as? SwiftSoup.Element {
            self.element = element
            self.node = nil
        } else if let node = value as? XPathNode {
            self.element = nil
            self.node = node
        } else {
            self.element = try? SwiftSoup.parse("\(value)").body()
            self.node = nil
        }
        super.init()
    }

    var rawValue: Any { element ?? node as Any }

    func text(_ value: Any?) -> Any? {
        if let value {
            let text = AnalyzeRule.stringValue(value)
            if let element { _ = try? element.text(text) }
            return self
        }
        if let element { return (try? element.text()) ?? "" }
        return node?.stringValue ?? ""
    }

    func ownText() -> String? {
        element.flatMap { try? $0.ownText() } ?? node?.stringValue
    }

    func textNodes() -> String? {
        guard let element else { return node?.stringValue }
        return element.textNodes().compactMap { $0.text().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    func html() -> String? {
        if let element { return try? element.html() }
        return node?.innerHtml
    }

    func outerHtml() -> String? {
        if let element { return try? element.outerHtml() }
        return node?.outerHtml
    }

    func attr(_ name: String, _ value: Any?) -> Any? {
        if let value {
            let text = AnalyzeRule.stringValue(value)
            if let element { _ = try? element.attr(name, text) }
            return self
        }
        if let element { return (try? element.attr(name)) ?? "" }
        return node?.attr(name) ?? ""
    }

    func select(_ rule: String) -> JSElements? {
        guard let element, let selected = try? element.select(rule) else { return nil }
        return JSElements(selected.array())
    }

    func toString() -> String { (text(nil) as? String) ?? "" }
}

@objc protocol JSElementsExports: JSExport {
    func size() -> Int
    func get(_ index: Int) -> JSElement?
    func first() -> JSElement?
    func last() -> JSElement?
    func toString() -> String
}

@objc final class JSElements: NSObject, JSElementsExports {
    private let items: [Any]

    init(_ items: [Any]) { self.items = items }

    func size() -> Int { items.count }
    func get(_ index: Int) -> JSElement? {
        guard index >= 0, index < items.count else { return nil }
        return JSElement(items[index])
    }
    func first() -> JSElement? { items.first.map { JSElement($0) } }
    func last() -> JSElement? { items.last.map { JSElement($0) } }
    func toString() -> String {
        items.map { AnalyzeRule.stringValue($0) }.joined(separator: "\n")
    }
}

// MARK: - cookie

@objc protocol JSCookieExports: JSExport {
    func getCookie(_ tag: String, _ key: String?) -> String
    func setCookie(_ tag: String, _ cookie: String?)
    func replaceCookie(_ tag: String, _ cookie: String)
    func removeCookie(_ tag: String)
    func getKey(_ tag: String, _ key: String) -> String
}

@objc final class JSCookieBridge: NSObject, JSCookieExports {
    var cookieStore: CookieStore?

    init(cookieStore: CookieStore?) {
        self.cookieStore = cookieStore
    }

    func getCookie(_ tag: String, _ key: String?) -> String {
        guard let key else { return cookieStore?.getCookie(tag) ?? "" }
        return cookieStore?.getKey(tag, key) ?? ""
    }
    func setCookie(_ tag: String, _ cookie: String?) { cookieStore?.setCookie(tag, cookie) }
    func replaceCookie(_ tag: String, _ cookie: String) { cookieStore?.replaceCookie(tag, cookie) }
    func removeCookie(_ tag: String) { cookieStore?.removeCookie(tag) }
    func getKey(_ tag: String, _ key: String) -> String { cookieStore?.getKey(tag, key) ?? "" }
}

// MARK: - cache

@objc protocol JSCacheExports: JSExport {
    func get(_ key: String) -> String?
    func put(_ key: String, _ value: String?)
    func delete(_ key: String)
    func getFromMemory(_ key: String) -> String?
    func putMemory(_ key: String, _ value: String?)
    func deleteMemory(_ key: String)
}

@objc final class JSCacheBridge: NSObject, JSCacheExports {
    var env: JSEnvironment
    init(env: JSEnvironment) { self.env = env }

    func get(_ key: String) -> String? { env.variables?.jsGet(key) }
    func put(_ key: String, _ value: String?) { env.variables?.jsPut(key, value ?? "") }
    func delete(_ key: String) { env.variables?.jsPut(key, "") }
    func getFromMemory(_ key: String) -> String? { MemoryCache.shared.get(key) }
    func putMemory(_ key: String, _ value: String?) { MemoryCache.shared.put(key, value) }
    func deleteMemory(_ key: String) { MemoryCache.shared.remove(key) }
}

// MARK: - source / book / chapter

@objc protocol JSSourceExports: JSExport {
    func getKey() -> String
    func getTag() -> String
    func get(_ key: String) -> String
    func put(_ key: String, _ value: String) -> String
    func getVariable() -> String?
    func setVariable(_ value: String?)
    func putVariable(_ value: String?)
    func getLoginInfo() -> String?
    func putLoginInfo(_ info: String) -> Bool
    func getLoginInfoMap() -> [String: String]
    func getLoginHeader() -> String?
    func getLoginHeaderMap() -> [String: String]
    func putLoginHeader(_ header: String?) -> String?
    func removeLoginHeader()
    func getHeaderMap() -> [String: String]
    var bookSourceUrl: String { get set }
    var bookSourceName: String { get set }
    var bookSourceType: Int { get }
    var header: String? { get set }
    var loginUrl: String? { get set }
    var loginUi: String? { get set }
    var bookSourceComment: String? { get set }
    var jsLib: String? { get set }
    var concurrentRate: String? { get set }
    var enabledCookieJar: Bool { get set }
}

@objc final class JSSourceBridge: NSObject, JSSourceExports {
    var source: BookSource
    init(_ source: BookSource) { self.source = source }

    func getKey() -> String { source.bookSourceUrl }
    func getTag() -> String { source.bookSourceName }
    func get(_ key: String) -> String { SourceVariableStore.get(source.bookSourceUrl, key) }
    func put(_ key: String, _ value: String) -> String {
        SourceVariableStore.put(source.bookSourceUrl, key, value)
        return value
    }
    func getVariable() -> String? { SourceVariableStore.get(source.bookSourceUrl, "__variable__") }
    func setVariable(_ value: String?) {
        SourceVariableStore.put(source.bookSourceUrl, "__variable__", value ?? "")
    }
    func putVariable(_ value: String?) { setVariable(value) }
    func getLoginInfo() -> String? {
        SourceVariableStore.get(source.bookSourceUrl, "__loginInfo__")
    }
    func putLoginInfo(_ info: String) -> Bool {
        SourceVariableStore.put(source.bookSourceUrl, "__loginInfo__", info)
        return true
    }
    func getLoginInfoMap() -> [String: String] {
        guard let text = getLoginInfo(), let map = JSONTool.parseObject(text) else { return [:] }
        return map.reduce(into: [:]) { $0[$1.key] = AnalyzeRule.stringValue($1.value) }
    }
    func getLoginHeader() -> String? {
        let value = SourceVariableStore.get(source.bookSourceUrl, "__loginHeader__")
        return value.isEmpty ? nil : value
    }
    func getLoginHeaderMap() -> [String: String] {
        guard let text = getLoginHeader(), let map = JSONTool.parseObject(text) else { return [:] }
        return map.reduce(into: [:]) { $0[$1.key] = AnalyzeRule.stringValue($1.value) }
    }
    func putLoginHeader(_ header: String?) -> String? {
        SourceVariableStore.put(source.bookSourceUrl, "__loginHeader__", header ?? "")
        return header
    }
    func removeLoginHeader() {
        SourceVariableStore.put(source.bookSourceUrl, "__loginHeader__", "")
    }
    func getHeaderMap() -> [String: String] { source.headerMap(userAgent: nil) }

    var bookSourceUrl: String {
        get { source.bookSourceUrl }
        set { source.bookSourceUrl = newValue }
    }
    var bookSourceName: String {
        get { source.bookSourceName }
        set { source.bookSourceName = newValue }
    }
    var bookSourceType: Int { source.bookSourceType }
    var header: String? {
        get { source.header }
        set { source.header = newValue }
    }
    var loginUrl: String? {
        get { source.loginUrl }
        set { source.loginUrl = newValue }
    }
    var loginUi: String? {
        get { source.loginUi }
        set { source.loginUi = newValue }
    }
    var bookSourceComment: String? {
        get { source.bookSourceComment }
        set { source.bookSourceComment = newValue }
    }
    var jsLib: String? {
        get { source.jsLib }
        set { source.jsLib = newValue }
    }
    var concurrentRate: String? {
        get { source.concurrentRate }
        set { source.concurrentRate = newValue }
    }
    var enabledCookieJar: Bool {
        get { source.enabledCookieJar ?? false }
        set { source.enabledCookieJar = newValue }
    }
}

@objc protocol JSBookExports: JSExport {
    func getVariable(_ key: String) -> String?
    func putVariable(_ key: String, _ value: String?)
    var name: String { get set }
    var author: String { get set }
    var bookUrl: String { get set }
    var tocUrl: String { get set }
    var origin: String { get set }
    var type: Int { get set }
    var variable: String? { get set }
}

@objc final class JSBookBridge: NSObject, JSBookExports {
    var book: Book
    init(_ book: Book) { self.book = book }

    func getVariable(_ key: String) -> String? { book.variableMap[key] }
    func putVariable(_ key: String, _ value: String?) {
        var map = book.variableMap
        map[key] = value ?? ""
        book.variableMap = map
    }

    var name: String { get { book.name } set { book.name = newValue } }
    var author: String { get { book.author } set { book.author = newValue } }
    var bookUrl: String { get { book.bookUrl } set { book.bookUrl = newValue } }
    var tocUrl: String { get { book.tocUrl } set { book.tocUrl = newValue } }
    var origin: String { get { book.origin } set { book.origin = newValue } }
    var type: Int { get { book.type } set { book.type = newValue } }
    var variable: String? { get { book.variable } set { book.variable = newValue } }
}

@objc protocol JSChapterExports: JSExport {
    func getVariable(_ key: String) -> String?
    func putVariable(_ key: String, _ value: String?)
    var title: String { get set }
    var url: String { get set }
    var index: Int { get set }
}

@objc final class JSChapterBridge: NSObject, JSChapterExports {
    var chapter: BookChapter
    init(_ chapter: BookChapter) { self.chapter = chapter }

    func getVariable(_ key: String) -> String? { chapter.variableMap[key] }
    func putVariable(_ key: String, _ value: String?) {
        var map = chapter.variableMap
        map[key] = value ?? ""
        chapter.variableMap = map
    }

    var title: String { get { chapter.title } set { chapter.title = newValue } }
    var url: String { get { chapter.url } set { chapter.url = newValue } }
    var index: Int { get { chapter.index } set { chapter.index = newValue } }
}

// MARK: - 内存缓存

final class MemoryCache: @unchecked Sendable {
    static let shared = MemoryCache()
    private var map: [String: String] = [:]
    private let lock = NSLock()

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }

    func put(_ key: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        if let value { map[key] = value } else { map.removeValue(forKey: key) }
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        map.removeValue(forKey: key)
    }
}

// MARK: - 书源级持久变量（source.put / get、登录信息）

enum SourceVariableStore {
    private static let prefix = "legado.source.vars."
    private static let lock = NSLock()

    static func put(_ sourceKey: String, _ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        var map = load(sourceKey)
        map[key] = value
        UserDefaults.standard.set(map, forKey: prefix + sourceKey)
    }

    static func get(_ sourceKey: String, _ key: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return load(sourceKey)[key] ?? ""
    }

    private static func load(_ sourceKey: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: prefix + sourceKey) as? [String: String] ?? [:]
    }
}

// MARK: - JS 文件读写（限制在缓存目录内）

enum JSFileStore {
    static var root: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/js", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func resolve(_ path: String) -> URL? {
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let candidate = root.appendingPathComponent(cleaned).standardizedFileURL
        let base = root.standardizedFileURL.path
        guard candidate.path == base || candidate.path.hasPrefix(base + "/") else { return nil }
        return candidate
    }

    @discardableResult
    static func write(_ path: String, data: Data) -> Bool {
        guard let file = resolve(path) else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    @discardableResult
    static func write(_ path: String, text: String) -> Bool {
        write(path, data: Data(text.utf8))
    }
}
