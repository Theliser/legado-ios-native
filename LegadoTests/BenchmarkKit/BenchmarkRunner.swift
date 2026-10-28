import Foundation
@testable import Legado

/// 跑一遍「搜索 → 详情 → 目录 → 正文」，只产出可比较的指标。
/// 录制和回放共用同一段代码，保证两边请求序列一致。
enum BenchmarkRunner {

    struct Outcome {
        var bookName: String
        var keyword: String
        var searchCount: Int
        var chapters: Int
        var contentChars: Int

        var summary: String {
            "《\(bookName)》 搜索 \(searchCount) · 目录 \(chapters) 章 · 正文 \(contentChars) 字"
        }
    }

    enum Failure: LocalizedError {
        case noResults
        case emptyToc
        case emptyContent

        var errorDescription: String? {
            switch self {
            case .noResults: return "搜索无结果"
            case .emptyToc: return "目录为空"
            case .emptyContent: return "正文为空"
            }
        }
    }

    /// - Parameter keywords: 依次尝试，第一个有结果的即采用（站点对不同书的覆盖不一样）
    static func run(webBook: WebBook, source: BookSource,
                    keywords: [String]) async throws -> Outcome {
        var books: [SearchBook] = []
        var usedKeyword = ""
        for keyword in keywords {
            let found = (try? await webBook.searchBook(source, key: keyword)) ?? []
            if !found.isEmpty {
                books = found
                usedKeyword = keyword
                break
            }
        }
        guard let first = books.first else { throw Failure.noResults }

        var book = first.toBook()
        book.origin = source.bookSourceUrl
        book = try await webBook.getBookInfo(source, book: book, canReName: true)

        let chapters = try await webBook.getChapterList(source, book: book)
        guard let chapter = chapters.first(where: { !($0.isVolume && $0.url.hasPrefix($0.title)) })
                ?? chapters.first else {
            throw Failure.emptyToc
        }

        let content = try await webBook.getContent(source, book: book, chapter: chapter,
                                                   nextChapterUrl: nil, needSave: false)
        guard !content.isBlank else { throw Failure.emptyContent }

        return Outcome(bookName: book.name,
                       keyword: usedKeyword,
                       searchCount: books.count,
                       chapters: chapters.count,
                       contentChars: content.count)
    }
}

// MARK: - 仓库路径与夹具读写

enum BenchmarkStorage {

    /// 仓库根目录（从本文件的编译期路径推出来，不依赖运行目录）
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // LegadoTests/BenchmarkKit/BenchmarkModels 同级
            .deletingLastPathComponent()          // BenchmarkKit
            .deletingLastPathComponent()          // LegadoTests
            .deletingLastPathComponent()          // repo root
    }

    static var fixtureDirectory: URL {
        repoRoot.appendingPathComponent("LegadoTests/BenchmarkKit/fixtures", isDirectory: true)
    }

    /// 候选池：网络抓下来、还没验证过的书源
    static var poolDirectory: URL {
        repoRoot.appendingPathComponent("LegadoTests/BenchmarkKit/pool", isDirectory: true)
    }

    static func loadFixtures() -> [BenchmarkFixture] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: fixtureDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(BenchmarkFixture.self, from: data)
            }
    }

    static func loadPool() -> [BookSource] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: poolDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                if let source = try? JSONDecoder().decode(BookSource.self, from: data),
                   !source.bookSourceUrl.isBlank, source.bookSourceType == 0 {
                    return source
                }
                if let list = try? JSONDecoder().decode([BookSource].self, from: data) {
                    return list.first { !$0.bookSourceUrl.isBlank && $0.bookSourceType == 0 }
                }
                return nil
            }
    }

    @discardableResult
    static func save(_ fixture: BenchmarkFixture) -> URL? {
        try? FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let url = fixtureDirectory.appendingPathComponent(fixture.fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(fixture) else { return nil }
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
