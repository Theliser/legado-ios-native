import SwiftUI

// MARK: - 详情

@MainActor
@Observable
final class BookDetailViewModel {
    struct State {
        var book: Book
        var chapters: [BookChapter] = []
        var isLoading = false
        var message: String?
        var toast: ToastMessage?
        var inShelf = false
        var isDownloading = false
        var downloadText: String?
    }

    enum Intent {
        case load
        case refresh
        case addToShelf
        case deleteFromShelf
        case downloadAll
        case toast(String)
    }

    private(set) var state: State
    private let container: AppContainer

    init(book: Book, container: AppContainer) {
        self.state = State(book: book)
        self.container = container
        self.state.inShelf = container.bookRepository.exists(book.bookUrl)
    }

    func send(_ intent: Intent) {
        switch intent {
        case .load:
            load()
        case .refresh:
            refresh()
        case .addToShelf:
            addToShelf()
        case .deleteFromShelf:
            container.bookRepository.delete(state.book)
            state.inShelf = false
            state.toast = ToastMessage(text: "已移出书架")
            runCallback(SourceCallBackEvent.delBookShelf, book: state.book)
        case .downloadAll:
            downloadAll()
        case .toast(let text):
            state.toast = ToastMessage(text: text, isError: true)
        }
    }

    private func load() {
        state.book = container.bookRepository.book(state.book.bookUrl) ?? state.book
        let cached = container.bookRepository.chapters(of: state.book)
        if !cached.isEmpty {
            state.chapters = cached
        } else {
            fetchToc()
        }
    }

    private func fetchToc() {
        guard let source = container.bookSourceRepository.source(for: state.book.origin) else {
            state.toast = ToastMessage(text: "书源不存在，无法拉取目录", isError: true)
            return
        }
        state.isLoading = true
        Task {
            do {
                var book = state.book
                if book.name.isEmpty || book.tocUrl.isEmpty {
                    book = try await container.webBook.getBookInfo(source, book: book)
                }
                let chapters = try await container.webBook.getChapterList(source, book: book)
                container.bookRepository.replaceChapters(chapters, of: book.bookUrl)
                book.totalChapterNum = chapters.count
                container.bookRepository.save(book)
                state.book = book
                state.chapters = chapters
            } catch {
                state.toast = ToastMessage(text: error.localizedDescription, isError: true)
            }
            state.isLoading = false
        }
    }

    private func refresh() {
        guard let source = container.bookSourceRepository.source(for: state.book.origin) else { return }
        state.isLoading = true
        Task {
            do {
                var book = state.book
                book = try await container.webBook.getBookInfo(source, book: book)
                let chapters = try await container.webBook.getChapterList(source, book: book)
                container.bookRepository.replaceChapters(chapters, of: book.bookUrl)
                book.totalChapterNum = chapters.count
                container.bookRepository.save(book)
                state.book = book
                state.chapters = chapters
                state.toast = ToastMessage(text: "已刷新：\(chapters.count) 章")
            } catch {
                state.toast = ToastMessage(text: error.localizedDescription, isError: true)
            }
            state.isLoading = false
        }
    }

    private func addToShelf() {
        var book = state.book
        if !container.bookRepository.exists(book.bookUrl) {
            book.tocUrl = book.tocUrl.isEmpty ? book.bookUrl : book.tocUrl
            container.bookRepository.save(book)
        }
        state.inShelf = true
        state.toast = ToastMessage(text: "已加入书架")
        runCallback(SourceCallBackEvent.addBookShelf, book: book)
    }

    private func runCallback(_ event: String, book: Book) {
        guard let source = container.bookSourceRepository.source(for: book.origin) else { return }
        let webBook = container.webBook
        Task.detached(priority: .utility) {
            _ = SourceCallBack.run(event, source: source, book: book, webBook: webBook)
        }
    }

    /// 把整本目录逐章抓下来写进本地缓存（阅读时直接命中，断网也能看）
    private func downloadAll() {
        guard let source = container.bookSourceRepository.source(for: state.book.origin) else {
            state.toast = ToastMessage(text: "书源不存在，无法下载", isError: true)
            return
        }
        guard !state.chapters.isEmpty else {
            state.toast = ToastMessage(text: "目录为空，请先刷新", isError: true)
            return
        }
        guard !state.isDownloading else { return }
        state.isDownloading = true
        state.downloadText = "准备下载 \(state.chapters.count) 章…"

        let book = state.book
        let chapters = state.chapters
        let webBook = container.webBook
        let limit = max(1, min(4, container.settings.threadCount))
        Task {
            let downloader = BookDownloader(webBook: webBook, concurrency: limit)
            let summary = await downloader.download(book: book, source: source,
                                                    chapters: chapters) { [weak self] progress in
                Task { @MainActor in
                    self?.state.downloadText = "缓存 \(progress.completed + progress.failed)/\(progress.total)" +
                        (progress.failed > 0 ? "（失败 \(progress.failed)）" : "")
                }
            }
            state.isDownloading = false
            state.downloadText = nil
            if summary.cancelled {
                state.toast = ToastMessage(text: "下载已取消", isError: true)
            } else if summary.failed > 0 {
                state.toast = ToastMessage(
                    text: "完成 \(summary.completed) 章，失败 \(summary.failed) 章：\(summary.failures.first?.reason ?? "")",
                    isError: true
                )
            } else {
                state.toast = ToastMessage(text: "已缓存 \(summary.completed) 章（跳过已有 \(summary.skipped) 章）")
            }
        }
    }
}

struct BookDetailView: View {
    let book: Book
    var onRead: (Int) -> Void

    @Environment(AppContainer.self) private var container
    @State private var model: BookDetailViewModel?
    @State private var showAllChapters = false

    var body: some View {
        ZStack {
            AppBackground()
            if let model {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(model)
                        actions(model)
                        introCard(model)
                        chapterSection(model)
                    }
                    .padding(20)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .toast(Binding(get: { model.state.toast }, set: { _ in }))
            }
        }
        .navigationTitle("详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                model = BookDetailViewModel(book: book, container: container)
                model?.send(.load)
            }
        }
    }

    private func header(_ model: BookDetailViewModel) -> some View {
        HStack(alignment: .top, spacing: 16) {
            BookCoverView(book: model.state.book)
                .frame(width: 108, height: 152)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(model.state.book.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                Text(model.state.book.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let kind = model.state.book.kind, !kind.isEmpty {
                    Text(kind)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassEffect(.regular, in: .capsule)
                }
                HStack(spacing: 10) {
                    if let word = model.state.book.wordCount, !word.isEmpty {
                        Label(word, systemImage: "text.alignleft")
                    }
                    if model.state.chapters.count > 0 {
                        Label("\(model.state.chapters.count) 章", systemImage: "list.bullet")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassCard()
    }

    private func actions(_ model: BookDetailViewModel) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
            Button {
                onRead(model.state.book.durChapterIndex)
            } label: {
                Label(model.state.book.durChapterTime > 0 ? "继续阅读" : "开始阅读",
                      systemImage: "book")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.glassProminent)

            if model.state.inShelf {
                Button {
                    model.send(.deleteFromShelf)
                } label: {
                    Image(systemName: "bookmark.slash")
                        .padding(.vertical, 12)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.glass)
            } else {
                Button {
                    model.send(.addToShelf)
                } label: {
                    Image(systemName: "plus")
                        .padding(.vertical, 12)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.glass)
            }

            Button {
                model.send(.downloadAll)
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .padding(.vertical, 12)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.glass)
            .disabled(model.state.isLoading || model.state.isDownloading)

            Button {
                model.send(.refresh)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .padding(.vertical, 12)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.glass)
            .disabled(model.state.isLoading || model.state.isDownloading)
            }

            if let text = model.state.downloadText {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func introCard(_ model: BookDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("简介")
                .font(.headline)
            Text(model.state.book.displayIntro ?? "暂无简介")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    private func chapterSection(_ model: BookDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("目录")
                    .font(.headline)
                Spacer()
                if model.state.isLoading {
                    ProgressView().controlSize(.small)
                }
                Button(model.state.chapters.count > 60 ? "查看全部" : "刷新") {
                    if model.state.chapters.count > 60 {
                        showAllChapters = true
                    } else {
                        model.send(.refresh)
                    }
                }
                .font(.subheadline)
            }

            let chapters = showAllChapters ? model.state.chapters : Array(model.state.chapters.prefix(60))
            LazyVStack(spacing: 0) {
                ForEach(chapters) { chapter in
                    Button {
                        onRead(chapter.index)
                    } label: {
                        HStack(spacing: 10) {
                            Text(chapter.title)
                                .font(.subheadline)
                                .foregroundStyle(chapter.index == model.state.book.durChapterIndex
                                                 ? Theme.accent : .primary)
                                .lineLimit(1)
                            Spacer()
                            if chapter.isVip {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.4)
                }
            }
            if let message = model.state.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassCard()
    }
}
