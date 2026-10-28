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

    /// 在独立作用域里执行脚本并调用其中一个函数（JS 单文件书源用）。
    /// 参数既作为全局绑定，也按位置传给函数，兼容 `function search(key, page)` 两种写法。
    func callFunction(_ script: String, function: String, arguments: [Any],
                      env: JSEnvironment, bindings: [String: Any] = [:]) -> Any? {
        lock.lock()
        defer { lock.unlock() }

        guard !script.isBlank else { return nil }
        let context = JSContext()!
        context.name = "js-source"
        context.exceptionHandler = { _, exception in
            if let exception {
                DebugLog.shared.log(env.source?.bookSourceName ?? "js",
                                    "≡JS 异常: \(exception.toString() ?? "")")
            }
        }
        bind(env, in: context, key: env.source?.bookSourceUrl ?? "js")
        let global = context.globalObject!
        for (key, value) in bindings {
            global.setObject(value, forKeyedSubscript: key as NSString)
        }

        context.exception = nil
        _ = context.evaluateScript(script)
        if let exception = context.exception {
            DebugLog.shared.log(env.source?.bookSourceName ?? "js",
                                "≡JS 主脚本出错: \(exception.toString() ?? "")")
            context.exception = nil
            return nil
        }

        guard let target = context.objectForKeyedSubscript(function),
              !target.isUndefined, !target.isNull else {
            return nil
        }
        context.exception = nil
        let value = target.call(withArguments: arguments)
        if let exception = context.exception {
            DebugLog.shared.log(env.source?.bookSourceName ?? "js",
                                "≡JS \(function) 出错: \(exception.toString() ?? "")")
            context.exception = nil
            return nil
        }
        return Self.toSwift(value)
    }

    func evaluateFresh(_ script: String, env: JSEnvironment,
                       bindings: [String: Any] = [:]) -> Any? {
        lock.lock()
        defer { lock.unlock() }

        guard !script.isBlank else { return nil }
        let context = JSContext()!
        context.name = "fresh"
        context.exceptionHandler = { _, exception in
            if let exception {
                DebugLog.shared.log(env.source?.bookSourceName ?? "js",
                                    "≡JS 异常: \(exception.toString() ?? "")")
            }
        }
        bind(env, in: context, key: env.source?.bookSourceUrl ?? "js")
        let global = context.globalObject!
        for (key, value) in bindings {
            global.setObject(value, forKeyedSubscript: key as NSString)
        }
        context.exception = nil
        let value = context.evaluateScript(script)
        if let exception = context.exception {
            DebugLog.shared.log(env.source?.bookSourceName ?? "js",
                                "≡JS 执行出错: \(exception.toString() ?? "")")
            context.exception = nil
            return nil
        }
        return Self.toSwift(value)
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
            // exceptionHandler 比 context.exception 可靠：JSC 在 handler 里已经
            // 取走异常时，context.exception 可能读到 nil。
            var libError: String?
            let previousHandler = context.exceptionHandler
            context.exceptionHandler = { context, exception in
                libError = exception?.toString() ?? "unknown"
                previousHandler?(context, exception)
            }
            context.evaluateScript(lib)
            context.exceptionHandler = previousHandler
            if let libError {
                // Rhino 允许 `function f(x) { let x = ... }` 这种参数重声明，
                // JSC 会直接 SyntaxError。整个 jsLib 失效会连带后续规则全部报
                // “找不到变量”，所以失败时按 Rhino 的宽松语义降级重试一次。
                DebugLog.shared.log(key, "≡jsLib 语法与 JSC 不兼容，按宽松模式重试: \(libError)")
                context.exception = nil
                context.evaluateScript(Self.lenientJSLib(lib))
            }
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
            let sourceBridge = JSSourceBridge(source)
            global.setObject(sourceBridge, forKeyedSubscript: "source" as NSString)
            // 官方 JS 源把同一对象也暴露为 sourceApi
            global.setObject(sourceBridge, forKeyedSubscript: "sourceApi" as NSString)
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
        global.setObject(env.event as Any?, forKeyedSubscript: "event" as NSString)
        _ = key
    }

    /// 把 Rhino 里能跑、JSC 会报错的写法降级成 var。
    /// 只在 jsLib 首次求值失败时使用，正常书源不受影响。
    static func lenientJSLib(_ script: String) -> String {
        script
            .replacingRegex("\\blet\\s+", with: "var ")
            .replacingRegex("\\bconst\\s+", with: "var ")
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
