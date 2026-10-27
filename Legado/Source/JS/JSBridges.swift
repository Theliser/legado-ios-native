import Foundation
import JavaScriptCore

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
    var infoMap: [String: String]?
    var fromBookInfo: Bool = false
    var ajax: ((String, Double?) -> String)?
    var variables: JSVariableStore?
}

// MARK: - Java 互操作（对应上游 `java` 变量）

@objc protocol JSJavaExports: JSExport {
    func ajax(_ url: Any?) -> String?
    func ajax(_ url: Any?, _ timeout: NSNumber?) -> String?
    func connect(_ url: String) -> JSResponse?
    func get(_ url: String) -> String?
    func post(_ url: String, _ body: String) -> String?
    func base64Encode(_ text: String?) -> String?
    func base64Decode(_ text: String?) -> String?
    func base64DecodeToByteArray(_ text: String?) -> String?
    func hexEncodeToString(_ text: String?) -> String?
    func hexDecodeToString(_ text: String?) -> String?
    func md5Encode(_ text: String?) -> String?
    func md5Encode16(_ text: String?) -> String?
    func encodeURI(_ text: String?) -> String?
    func htmlFormat(_ html: String?) -> String?
    func timeFormat(_ time: NSNumber?) -> String?
    func put(_ key: String, _ value: String?) -> String?
    func getFromCache(_ key: String) -> String?
    func log(_ message: String?)
    func toast(_ message: String?)
    func getCookie(_ tag: String) -> String?
    func getCookie(_ tag: String, _ key: String?) -> String?
    func randomUUID() -> String
}

@objc final class JSJavaBridge: NSObject, JSJavaExports {
    var env: JSEnvironment
    var cookieStore: CookieStore?
    var sourceKey: String?

    init(env: JSEnvironment, cookieStore: CookieStore?) {
        self.env = env
        self.cookieStore = cookieStore
    }

    func ajax(_ url: Any?) -> String? {
        ajax(url, nil)
    }

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
        let value = handler(urlStr, timeout?.doubleValue)
        return value
    }

    func connect(_ url: String) -> JSResponse? {
        guard let handler = env.ajax else { return nil }
        let body = handler(url, 30000)
        return JSResponse(url: url, body: body ?? "")
    }

    func get(_ url: String) -> String? {
        env.ajax?(url, nil)
    }

    func post(_ url: String, _ body: String) -> String? {
        // 多数书源用 java.ajax 处理 POST；这里退化为 GET，保持不崩
        env.ajax?(url, nil)
    }

    func base64Encode(_ text: String?) -> String? {
        guard let text else { return nil }
        return CryptoUtils.base64Encode(text)
    }

    func base64Decode(_ text: String?) -> String? {
        guard let text else { return nil }
        return CryptoUtils.base64Decode(text)
    }

    func base64DecodeToByteArray(_ text: String?) -> String? {
        guard let text, let data = CryptoUtils.base64DecodeData(text) else { return nil }
        return String(data: data, encoding: .isoLatin1)
    }

    func hexEncodeToString(_ text: String?) -> String? {
        guard let text else { return nil }
        return CryptoUtils.hexEncode(text)
    }

    func hexDecodeToString(_ text: String?) -> String? {
        guard let text else { return nil }
        return CryptoUtils.hexDecodeToString(text)
    }

    func md5Encode(_ text: String?) -> String? {
        guard let text else { return nil }
        return CryptoUtils.md5(text)
    }

    func md5Encode16(_ text: String?) -> String? {
        guard let text else { return nil }
        let md5 = CryptoUtils.md5(text)
        let start = md5.index(md5.startIndex, offsetBy: 8)
        let end = md5.index(md5.startIndex, offsetBy: 24)
        return String(md5[start..<end])
    }

    func encodeURI(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }

    func htmlFormat(_ html: String?) -> String? {
        HtmlFormatter.format(html)
    }

    func timeFormat(_ time: NSNumber?) -> String? {
        guard let time else { return nil }
        let date = Date(timeIntervalSince1970: time.doubleValue > 10_000_000_000 ? time.doubleValue / 1000 : time.doubleValue)
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f.string(from: date)
    }

    func put(_ key: String, _ value: String?) -> String? {
        env.variables?.jsPut(key, value ?? "")
        return value
    }

    func getFromCache(_ key: String) -> String? {
        env.variables?.jsGet(key)
    }

    func log(_ message: String?) {
        DebugLog.shared.log(sourceKey, message ?? "")
    }

    func toast(_ message: String?) {
        DebugLog.shared.log(sourceKey, message ?? "")
    }

    func getCookie(_ tag: String) -> String? {
        cookieStore?.getCookie(tag)
    }

    func getCookie(_ tag: String, _ key: String?) -> String? {
        guard let key else { return cookieStore?.getCookie(tag) }
        return cookieStore?.getKey(tag, key)
    }

    func randomUUID() -> String {
        UUID().uuidString
    }
}

/// `java.connect()` 返回对象
@objc protocol JSResponseExports: JSExport {
    func body() -> String?
    func url() -> String
    func code() -> Int
    func header(_ name: String) -> String?
}

@objc final class JSResponse: NSObject, JSResponseExports {
    let responseURL: String
    let responseBody: String

    init(url: String, body: String) {
        self.responseURL = url
        self.responseBody = body
    }

    func body() -> String? { responseBody }
    func url() -> String { responseURL }
    func code() -> Int { 200 }
    func header(_ name: String) -> String? { nil }
}

// MARK: - cookie

@objc protocol JSCookieExports: JSExport {
    func getCookie(_ tag: String) -> String
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

    func getCookie(_ tag: String) -> String { cookieStore?.getCookie(tag) ?? "" }
    func getCookie(_ tag: String, _ key: String?) -> String {
        guard let key else { return getCookie(tag) }
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

// MARK: - source / book

@objc protocol JSSourceExports: JSExport {
    func getKey() -> String
    func getTag() -> String
    func getVariable() -> String?
    func setVariable(_ value: String?)
    var bookSourceUrl: String { get set }
    var bookSourceName: String { get set }
    var header: String? { get set }
    var loginUrl: String? { get set }
    var bookSourceComment: String? { get set }
}

@objc final class JSSourceBridge: NSObject, JSSourceExports {
    var source: BookSource
    init(_ source: BookSource) { self.source = source }

    func getKey() -> String { source.bookSourceUrl }
    func getTag() -> String { source.bookSourceName }
    func getVariable() -> String? { source.variableComment }
    func setVariable(_ value: String?) { source.variableComment = value }

    var bookSourceUrl: String {
        get { source.bookSourceUrl }
        set { source.bookSourceUrl = newValue }
    }
    var bookSourceName: String {
        get { source.bookSourceName }
        set { source.bookSourceName = newValue }
    }
    var header: String? {
        get { source.header }
        set { source.header = newValue }
    }
    var loginUrl: String? {
        get { source.loginUrl }
        set { source.loginUrl = newValue }
    }
    var bookSourceComment: String? {
        get { source.bookSourceComment }
        set { source.bookSourceComment = newValue }
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
