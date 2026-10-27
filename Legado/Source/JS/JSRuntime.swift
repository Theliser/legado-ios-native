import Foundation
import JavaScriptCore

/// JavaScriptCore 运行时，替代上游的 Rhino。
///
/// 与上游一致的地方：按书源 key 复用同一个 JS 作用域（书源自定义函数、全局变量可跨规则保留），
/// 每次求值重新绑定 `java` / `cookie` / `cache` / `source` / `book` 等环境变量。
final class JSRuntime: @unchecked Sendable {

    static let shared = JSRuntime()

    private let lock = NSRecursiveLock()
    private var contexts: [String: JSContext] = [:]
    private var order: [String] = []
    private let limit = 8
    private var cookieStore: CookieStore?

    func configure(cookieStore: CookieStore) {
        self.cookieStore = cookieStore
    }

    @discardableResult
    func evaluate(_ script: String, key: String, env: JSEnvironment) -> Any? {
        lock.lock()
        defer { lock.unlock() }

        guard !script.isBlank else { return nil }
        let context = context(for: key, env: env)
        bind(env, in: context, key: key)

        context.exception = nil
        let value = context.evaluateScript(script)
        if let exception = context.exception {
            DebugLog.shared.log(env.source?.bookSourceName ?? key,
                                "≡JS 执行出错: \(exception.toString() ?? "")")
            context.exception = nil
            return nil
        }
        return Self.toSwift(value)
    }

    /// 执行一段不关心返回值的脚本（例如 jsLib 预置）
    func evaluateSilently(_ script: String, key: String, env: JSEnvironment) {
        _ = evaluate(script, key: key, env: env)
    }

    func clearContexts() {
        lock.lock()
        contexts.removeAll()
        order.removeAll()
        lock.unlock()
    }

    // MARK: - 上下文

    private func context(for key: String, env: JSEnvironment) -> JSContext {
        if let hit = contexts[key] {
            return hit
        }
        let context = JSContext()!
        context.name = key
        context.exceptionHandler = { _, exception in
            if let exception {
                DebugLog.shared.log(key, "≡JS 异常: \(exception.toString() ?? "")")
            }
        }
        // 预置 jsLib（书源自定义函数库）
        if let lib = env.source?.jsLib, !lib.isBlank {
            context.evaluateScript(lib)
            context.exception = nil
        }
        if contexts.count >= limit, let first = order.first {
            order.removeFirst()
            contexts.removeValue(forKey: first)
        }
        contexts[key] = context
        order.append(key)
        return context
    }

    private func bind(_ env: JSEnvironment, in context: JSContext, key: String) {
        let global = context.globalObject!

        let javaBridge = JSJavaBridge(env: env, cookieStore: cookieStore)
        global.setObject(javaBridge, forKeyedSubscript: "java" as NSString)
        global.setObject(JSCookieBridge(cookieStore: cookieStore), forKeyedSubscript: "cookie" as NSString)
        global.setObject(JSCacheBridge(env: env), forKeyedSubscript: "cache" as NSString)

        if let source = env.source {
            global.setObject(JSSourceBridge(source), forKeyedSubscript: "source" as NSString)
        }
        if let book = env.book {
            global.setObject(JSBookBridge(book), forKeyedSubscript: "book" as NSString)
        }
        if let chapter = env.chapter {
            global.setObject(JSChapterBridge(chapter), forKeyedSubscript: "chapter" as NSString)
        }

        global.setObject(env.baseUrl, forKeyedSubscript: "baseUrl" as NSString)
        global.setObject(env.result ?? NSNull(), forKeyedSubscript: "result" as NSString)
        global.setObject(env.content ?? NSNull(), forKeyedSubscript: "src" as NSString)
        global.setObject(env.title as Any?, forKeyedSubscript: "title" as NSString)
        global.setObject(env.nextChapterUrl as Any?, forKeyedSubscript: "nextChapterUrl" as NSString)
        global.setObject(env.page as Any?, forKeyedSubscript: "page" as NSString)
        global.setObject(env.index as Any?, forKeyedSubscript: "index" as NSString)
        global.setObject(env.key as Any?, forKeyedSubscript: "key" as NSString)
        global.setObject(env.infoMap as Any?, forKeyedSubscript: "infoMap" as NSString)
        global.setObject(env.fromBookInfo, forKeyedSubscript: "fromBookInfo" as NSString)
        _ = key
    }

    // MARK: - 类型转换

    static func toSwift(_ value: JSValue?) -> Any? {
        guard let value else { return nil }
        if value.isUndefined || value.isNull { return nil }
        if value.isString { return value.toString() }
        if value.isBoolean { return value.toBool() }
        if value.isNumber { return value.toNumber() }
        if value.isArray {
            guard let array = value.toArray() else { return nil }
            return array.map { Self.convert($0) }
        }
        if value.isObject {
            if let dict = value.toDictionary() as? [String: Any] {
                return dict.mapValues { Self.convert($0) }
            }
            return value.toObject()
        }
        return value.toObject()
    }

    private static func convert(_ value: Any?) -> Any? {
        switch value {
        case let v as JSValue:
            return toSwift(v)
        case let v as NSNull:
            _ = v
            return nil
        case let v as NSNumber:
            return v.doubleValue
        case let v as NSDictionary:
            var dict: [String: Any] = [:]
            for (k, val) in v {
                dict["\(k)"] = convert(val)
            }
            return dict
        case let v as NSArray:
            return v.map { convert($0) }
        default:
            return value
        }
    }
}
