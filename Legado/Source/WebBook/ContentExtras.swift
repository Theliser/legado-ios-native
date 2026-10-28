import Foundation

// MARK: - 书籍图片样式

extension Book {
    /// 书级图片样式（`FULL` / `SINGLE` / `TEXT`…），对齐上游 `Book.getImageStyle()`。
    var imageStyle: String? {
        get { readConfigObject["imageStyle"] as? String }
        set {
            var config = readConfigObject
            if let newValue, !newValue.isEmpty {
                config["imageStyle"] = newValue
            } else {
                config.removeValue(forKey: "imageStyle")
            }
            readConfig = JSONTool.stringify(config)
        }
    }

    /// 阅读时把书源正文规则里的 imageStyle 落到书籍配置（对齐上游 ReadBook 的做法）。
    mutating func applyContentRule(_ rule: ContentRule?) {
        guard let style = rule?.imageStyle, !style.isBlank else { return }
        imageStyle = style
    }
}

// MARK: - 图片二次解密

/// `coverDecodeJs` / `ruleContent.imageDecode`。
/// JS 里 `result` 是可读写的字节数组（JS Array of numbers），`src` 是图片地址，
/// 返回值同样按字节数组（或 base64 字符串）接收。
enum ImageDecodeService {

    static func rule(source: BookSource, isCover: Bool) -> String? {
        let js = isCover ? source.coverDecodeJs : source.contentRule.imageDecode
        guard let js, !js.isBlank else { return nil }
        return js
    }

    /// - Returns: 解密后的数据；没有规则时返回 nil，规则执行失败也返回 nil（与上游一致）
    static func decode(src: String, data: Data, isCover: Bool,
                       source: BookSource, book: Book?,
                       webBook: WebBook) -> Data? {
        guard let js = rule(source: source, isCover: isCover) else { return nil }
        let rule = webBook.makeRule(book: book, source: source)
        rule.setContent(src)
        let bytes = data.map { Int($0) }
        let value = rule.evalJS(js, result: bytes)
        guard let value else {
            DebugLog.shared.log(source.bookSourceUrl, "≡图片解密无返回值：\(src)")
            return nil
        }
        if let decoded = JSJavaBridge.data(from: value) {
            return decoded
        }
        if let text = value as? String, !text.isEmpty,
           let decoded = CryptoUtils.base64DecodeData(text) {
            return decoded
        }
        DebugLog.shared.log(source.bookSourceUrl, "≡图片解密返回值不是字节数组：\(src)")
        return nil
    }

    /// 便捷入口：带上源数据，规则为空时原样返回
    static func decodeIfNeeded(src: String, data: Data, isCover: Bool,
                               source: BookSource, book: Book?, webBook: WebBook) -> Data? {
        guard rule(source: source, isCover: isCover) != nil else { return data }
        return decode(src: src, data: data, isCover: isCover,
                      source: source, book: book, webBook: webBook)
    }
}

// MARK: - 书源回调（callBackJs）

/// 对齐上游 `SourceCallBack` 的事件名
enum SourceCallBackEvent {
    static let clickAuthor = "clickAuthor"
    static let longClickAuthor = "longClickAuthor"
    static let clickBookName = "clickBookName"
    static let longClickBookName = "longClickBookName"
    static let clickCustomButton = "clickCustomButton"
    static let longClickCustomButton = "longClickCustomButton"
    static let clickShareBook = "clickShareBook"
    static let clickClearCache = "clickClearCache"
    static let clickCopyBookUrl = "clickCopyBookUrl"
    static let clickCopyTocUrl = "clickCopyTocUrl"
    static let clickCopyPlayUrl = "clickCopyPlayUrl"

    static let addBookShelf = "addBookShelf"
    static let delBookShelf = "delBookShelf"
    static let saveRead = "saveRead"
    static let startRead = "startRead"
    static let endRead = "endRead"
    static let startShelfRefresh = "startShelfRefresh"
    static let endShelfRefresh = "endShelfRefresh"
}

enum SourceCallBack {

    /// 执行 `callBackJs`。书源未开启 `eventListener` 或没有回调脚本时直接返回 false。
    /// - Returns: 脚本返回值是否为 true（上游用这个决定要不要继续执行默认行为）
    @discardableResult
    static func run(_ event: String, source: BookSource, book: Book?,
                    chapter: BookChapter? = nil, result: String? = nil,
                    webBook: WebBook) -> Bool {
        guard source.eventListener else { return false }
        guard let js = source.contentRule.callBackJs, !js.isBlank else { return false }
        let rule = webBook.makeRule(book: book, source: source)
        rule.setChapter(chapter)
        let value = rule.evalJS(js, result: result, event: event)
        let handled = isTrue(value)
        DebugLog.shared.log(source.bookSourceUrl, "≡回调 \(event)：\(handled ? "已处理" : "未处理")")
        return handled
    }

    static func isTrue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        let text = AnalyzeRule.stringValue(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.lowercased() == "true"
    }
}
