import Foundation

/// 详情页的「关联书籍」（`ruleBookInfo.relatedBooks`）。
///
/// 书源里是一段 JSON：`[{"key":"sameAuthor","title":"同作者","url":"/author/1.html"}]`。
/// 每个模块都是一次发现页请求，单个模块失败不影响其他模块。
struct RelatedBookModule: Identifiable, Equatable {
    var key: String
    var title: String
    var url: String
    var resolvedUrl: String
    var books: [SearchBook]

    var id: String { key.isEmpty ? title + "|" + url : key }
}

enum RelatedBooks {

    struct Definition {
        var key: String?
        var title: String?
        var url: String?
    }

    /// 解析并请求所有关联模块。过滤掉当前书籍自身。
    static func load(webBook: WebBook, source: BookSource, book: Book) async -> [RelatedBookModule] {
        guard let json = source.bookInfoRule.relatedBooks, !json.isBlank else { return [] }
        return await load(webBook: webBook, source: source, book: book, json: json)
    }

    static func load(webBook: WebBook, source: BookSource, book: Book,
                     json: String) async -> [RelatedBookModule] {
        guard !json.isBlank else { return [] }
        DebugLog.shared.log(source.bookSourceUrl, "︾开始解析关联书籍 relatedBooks")
        guard let definitions = parseDefinitions(json) else {
            DebugLog.shared.log(source.bookSourceUrl, "︾关联书籍 relatedBooks 配置解析失败")
            return []
        }

        var modules: [RelatedBookModule] = []
        for (index, definition) in definitions.enumerated() {
            let label = "关联书籍 relatedBooks[\(index + 1)] \(definition.title ?? "")"
            let url = definition.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !url.isEmpty else {
                DebugLog.shared.log(source.bookSourceUrl, "︾\(label): url 为空，跳过")
                continue
            }
            do {
                let (resolvedUrl, books) = try await webBook.exploreBookWithResolvedUrl(
                    source, url: url, page: 1
                )
                let filtered = books.filter { $0.bookUrl != book.bookUrl }
                DebugLog.shared.log(source.bookSourceUrl,
                                    "︾\(label): 获取 \(books.count) 本，过滤当前书籍后 \(filtered.count) 本")
                guard !filtered.isEmpty else { continue }
                modules.append(RelatedBookModule(
                    key: definition.key ?? definition.title ?? "",
                    title: definition.title ?? "",
                    url: url,
                    resolvedUrl: resolvedUrl,
                    books: filtered
                ))
            } catch is CancellationError {
                return modules
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                DebugLog.shared.log(source.bookSourceUrl, "︾\(label): 请求或解析失败 \(text)")
            }
        }
        DebugLog.shared.log(source.bookSourceUrl,
                            "︽关联书籍 relatedBooks 解析完成，显示 \(modules.count) 个模块")
        return modules
    }

    static func parseDefinitions(_ json: String) -> [Definition]? {
        guard let array = JSONTool.parseArray(json) else { return nil }
        var result: [Definition] = []
        for item in array {
            guard let dict = item as? [String: Any] else { continue }
            result.append(Definition(
                key: dict["key"].map { AnalyzeRule.stringValue($0) },
                title: dict["title"].map { AnalyzeRule.stringValue($0) },
                url: dict["url"].map { AnalyzeRule.stringValue($0) }
            ))
        }
        return result
    }
}

extension WebBook {
    func loadRelatedBooks(source: BookSource, book: Book) async -> [RelatedBookModule] {
        await RelatedBooks.load(webBook: self, source: source, book: book)
    }
}
