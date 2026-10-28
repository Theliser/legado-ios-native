import Foundation

// MARK: - 下载

struct DownloadProgress: Sendable, Equatable {
    var completed: Int = 0
    var failed: Int = 0
    var total: Int = 0
    var currentTitle: String = ""

    var fraction: Double {
        total > 0 ? Double(completed + failed) / Double(total) : 0
    }
}

struct DownloadFailure: Sendable, Equatable {
    var index: Int
    var title: String
    var reason: String
}

struct DownloadSummary: Sendable, Equatable {
    var total: Int = 0
    /// 成功（含命中缓存）
    var completed: Int = 0
    var failed: Int { failures.count }
    var skipped: Int = 0
    var failures: [DownloadFailure] = []
    var cancelled = false
}

/// 整本 / 批量章节缓存。复用 `WebBook.getContent` 的解析与 `ChapterCache` 的落盘，
/// 失败章节不中断整批，最后统一返回。
final class BookDownloader: @unchecked Sendable {

    private final class WebBookBox: @unchecked Sendable {
        let webBook: WebBook
        init(_ webBook: WebBook) { self.webBook = webBook }
    }

    let webBook: WebBook
    let concurrency: Int

    init(webBook: WebBook, concurrency: Int = 3) {
        self.webBook = webBook
        self.concurrency = max(1, concurrency)
    }

    /// - Parameters:
    ///   - chapters: 按目录顺序
    ///   - force: true 时忽略已有缓存重新下载
    ///   - progress: 每完成一章回调一次（可能来自任意线程）
    func download(book: Book, source: BookSource, chapters: [BookChapter],
                  force: Bool = false,
                  progress: (@Sendable (DownloadProgress) -> Void)? = nil) async -> DownloadSummary {
        let readable = chapters.filter { !$0.isVolume }
        var summary = DownloadSummary(total: readable.count)
        guard !readable.isEmpty else { return summary }

        let nextChapterUrl: (BookChapter) -> String? = { chapter in
            guard chapter.index + 1 < chapters.count else { return nil }
            return chapters[chapter.index + 1].url
        }
        let box = WebBookBox(webBook)
        let cache = webBook.chapterCache

        var pending: [BookChapter] = []
        for chapter in readable {
            if !force, cache.has(book: book, chapter: chapter) {
                summary.completed += 1
                summary.skipped += 1
            } else {
                pending.append(chapter)
            }
        }
        var progressState = DownloadProgress(completed: summary.skipped,
                                             failed: 0,
                                             total: readable.count,
                                             currentTitle: "")
        progress?(progressState)
        if pending.isEmpty {
            return summary
        }

        var failures: [DownloadFailure] = []
        var completed = summary.completed

        await withTaskGroup(of: (BookChapter, String?).self) { group in
            var iterator = pending.makeIterator()
            var running = 0

            func addNext() -> Bool {
                guard let chapter = iterator.next() else { return false }
                group.addTask {
                    do {
                        _ = try await box.webBook.getContent(source, book: book,
                                                             chapter: chapter,
                                                             nextChapterUrl: nextChapterUrl(chapter),
                                                             needSave: true)
                        return (chapter, nil)
                    } catch is CancellationError {
                        return (chapter, "已取消")
                    } catch {
                        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                        return (chapter, text)
                    }
                }
                return true
            }

            while running < concurrency, addNext() { running += 1 }

            while let (chapter, error) = await group.next() {
                running -= 1
                if let error {
                    failures.append(DownloadFailure(index: chapter.index,
                                                    title: chapter.title,
                                                    reason: error))
                    progressState.failed += 1
                } else {
                    completed += 1
                    summary.completed = completed
                    progressState.completed += 1
                }
                progressState.currentTitle = chapter.title
                progress?(progressState)
                if Task.isCancelled {
                    summary.cancelled = true
                    group.cancelAll()
                    break
                }
                _ = addNext()
                running += 1
            }
            if summary.cancelled { group.cancelAll() }
        }

        cache.flush()
        summary.failures = failures.sorted { $0.index < $1.index }
        return summary
    }

    /// 删除一本书的全部离线缓存
    func clearCache(book: Book) {
        webBook.chapterCache.remove(book: book)
    }
}
