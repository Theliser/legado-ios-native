import Foundation
import SwiftUI

#if DEBUG
/// 仅 Debug 构建可用的启动参数，用于在模拟器上快速复现真实书源链路、截图验收。
///
/// 支持的参数：
/// - `-LEGADO_DEBUG_SOURCES <path>`      启动时导入书源 JSON（单条或数组）
/// - `-LEGADO_DEBUG_TAB shelf|explore|sources|profile` 初始 Tab
/// - `-LEGADO_DEBUG_SEARCH <keyword>`    「发现」页自动搜索
/// - `-LEGADO_DEBUG_READ_SOURCES <path>` 直接进入阅读页：导入书源并跑完整链路
/// - `-LEGADO_DEBUG_READ_KEYWORD <kw>`   阅读页自动准备时使用的关键字
enum DebugLaunch {

    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        let value = arguments[index + 1]
        return value.hasPrefix("-") ? nil : value
    }

    static var initialTab: AppTab? {
        switch value(after: "-LEGADO_DEBUG_TAB") {
        case "shelf": return .shelf
        case "explore": return .explore
        case "sources": return .sources
        case "profile": return .profile
        default: return nil
        }
    }

    static var searchKeyword: String? { value(after: "-LEGADO_DEBUG_SEARCH") }

    static var readSourcesPath: String? { value(after: "-LEGADO_DEBUG_READ_SOURCES") }
    static var readKeyword: String { value(after: "-LEGADO_DEBUG_READ_KEYWORD") ?? "剑来" }

    static func importSources(into container: AppContainer) {
        guard let path = value(after: "-LEGADO_DEBUG_SOURCES")
                ?? readSourcesPath else { return }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            DebugLog.shared.log("DEBUG", "导入书源失败：读不到 \(path)")
            return
        }
        let result = container.bookSourceRepository.importJSON(text)
        DebugLog.shared.log("DEBUG", "调试导入书源：新增 \(result.added) 更新 \(result.updated) 失败 \(result.failed)")
    }
}

/// 直接进入阅读页：导入书源 → 搜索 → 详情 → 目录 → 首章正文，全部走真实网络。
struct DebugReaderHost: View {
    let container: AppContainer

    @State private var book: Book?
    @State private var status = "准备书源…"
    @State private var error: String?

    var body: some View {
        Group {
            if let book {
                ReaderView(book: book, startIndex: 0)
                    .environment(container)
            } else {
                ZStack {
                    AppBackground()
                    VStack(spacing: 14) {
                        if let error {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundStyle(.orange)
                            Text("准备失败").font(.headline)
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        } else {
                            ProgressView()
                            Text(status).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task { await prepare() }
    }

    private func prepare() async {
        guard let path = DebugLaunch.readSourcesPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            error = "没有传入 -LEGADO_DEBUG_READ_SOURCES"
            return
        }
        container.bookSourceRepository.importJSON(text)
        // 只取本次导入的书源，避免数据库里其它书源（可能已失效）干扰
        var importedURL: String?
        if let data = text.data(using: .utf8),
           let imported = try? JSONDecoder().decode(BookSource.self, from: data) {
            importedURL = imported.bookSourceUrl
        }
        let source = container.bookSourceRepository.enabledSources
            .first { $0.bookSourceUrl == importedURL }
            ?? container.bookSourceRepository.enabledSources.first
        guard let source else {
            error = "书源导入失败"
            return
        }
        status = "搜索 \(DebugLaunch.readKeyword)…"
        do {
            let results = try await container.webBook.searchBook(source, key: DebugLaunch.readKeyword)
            guard let first = results.first else {
                error = "「\(DebugLaunch.readKeyword)」没有搜到结果"
                return
            }
            status = "获取《\(first.name)》详情…"
            var book = first.toBook()
            book.type = source.bookType
            book = try await container.webBook.getBookInfo(source, book: book)
            status = "获取目录…"
            let chapters = try await container.webBook.getChapterList(source, book: book)
            guard let chapter = chapters.first(where: { !$0.isVolume }) else {
                error = "目录为空"
                return
            }
            container.bookRepository.replaceChapters(chapters, of: book.bookUrl)
            book.totalChapterNum = chapters.count
            container.bookRepository.save(book)

            status = "获取《\(chapter.title)》正文…"
            let content = try await container.webBook.getContent(source, book: book,
                                                                 chapter: chapter)
            container.bookRepository.save(chapter: chapter)
            DebugLog.shared.log("DEBUG", "阅读页准备完成：《\(book.name)》 \(chapters.count) 章，正文 \(content.count) 字")
            self.book = book
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
