import SwiftUI

@MainActor
@Observable
final class ReaderViewModel {
    struct State {
        var book: Book
        var chapters: [BookChapter] = []
        var index: Int = 0
        var content: String = ""
        var isLoading = false
        var error: String?
        var showCatalog = false
        var showSettings = false
        var fromCache = false
    }

    enum Intent {
        case prepare
        case open(Int)
        case next
        case previous
        case retry
        case toggleCatalog(Bool)
        case toggleSettings(Bool)
    }

    private(set) var state: State
    private let container: AppContainer
    private var loadingTask: Task<Void, Never>?
    private var loadedIndex: Int = -1

    init(book: Book, startIndex: Int, container: AppContainer) {
        var state = State(book: book)
        state.index = max(0, startIndex)
        self.state = state
        self.container = container
    }

    func send(_ intent: Intent) {
        switch intent {
        case .prepare:
            prepare()
        case .open(let index):
            state.showCatalog = false
            load(index: index)
        case .next:
            guard state.index + 1 < state.chapters.count else { return }
            load(index: state.index + 1)
        case .previous:
            guard state.index > 0 else { return }
            load(index: state.index - 1)
        case .retry:
            loadedIndex = -1
            load(index: state.index)
        case .toggleCatalog(let show):
            state.showCatalog = show
        case .toggleSettings(let show):
            state.showSettings = show
        }
    }

    private func prepare() {
        state.chapters = container.bookRepository.chapters(of: state.book)
        if state.chapters.isEmpty {
            fetchChapters()
        } else {
            load(index: min(state.index, max(0, state.chapters.count - 1)))
        }
    }

    private func fetchChapters() {
        guard let source = container.bookSourceRepository.source(for: state.book.origin) else {
            state.error = "书源已不存在"
            return
        }
        state.isLoading = true
        Task {
            do {
                var book = state.book
                if book.tocUrl.isEmpty {
                    book = try await container.webBook.getBookInfo(source, book: book)
                }
                let chapters = try await container.webBook.getChapterList(source, book: book)
                container.bookRepository.replaceChapters(chapters, of: book.bookUrl)
                book.totalChapterNum = chapters.count
                container.bookRepository.save(book)
                state.book = book
                state.chapters = chapters
                state.isLoading = false
                load(index: min(state.index, max(0, chapters.count - 1)))
            } catch {
                state.isLoading = false
                state.error = error.localizedDescription
            }
        }
    }

    private func load(index: Int) {
        guard state.chapters.indices.contains(index) else { return }
        state.index = index
        let chapter = state.chapters[index]
        state.book.durChapterIndex = index
        state.book.durChapterTitle = chapter.title

        if let cached = container.webBook.chapterCache.load(book: state.book, chapter: chapter),
           !cached.isBlank {
            state.content = cached
            state.fromCache = true
            state.error = nil
            loadedIndex = index
            saveProgress(chapter)
            return
        }

        state.isLoading = true
        state.error = nil
        state.content = ""
        loadedIndex = index

        loadingTask?.cancel()
        loadingTask = Task {
            guard let source = container.bookSourceRepository.source(for: state.book.origin) else {
                state.error = "书源已不存在"
                state.isLoading = false
                return
            }
            do {
                let next = index + 1 < state.chapters.count ? state.chapters[index + 1].url : nil
                let content = try await container.webBook.getContent(source, book: state.book,
                                                                     chapter: chapter,
                                                                     nextChapterUrl: next)
                guard !Task.isCancelled, state.index == index else { return }
                state.content = content
                state.isLoading = false
                state.fromCache = false
                saveProgress(chapter)
                prefetch(around: index)
            } catch {
                guard !Task.isCancelled else { return }
                state.isLoading = false
                state.error = error.localizedDescription
            }
        }
    }

    private func saveProgress(_ chapter: BookChapter) {
        container.bookRepository.updateProgress(book: state.book, index: chapter.index,
                                                title: chapter.title)
    }

    private func prefetch(around index: Int) {
        guard let source = container.bookSourceRepository.source(for: state.book.origin) else { return }
        let nextIndex = index + 1
        guard state.chapters.indices.contains(nextIndex) else { return }
        let chapter = state.chapters[nextIndex]
        if container.webBook.chapterCache.load(book: state.book, chapter: chapter) != nil { return }
        Task.detached(priority: .utility) { [container, book = state.book] in
            _ = try? await container.webBook.getContent(source, book: book, chapter: chapter)
        }
    }

    var chapter: BookChapter? {
        state.chapters.indices.contains(state.index) ? state.chapters[state.index] : nil
    }
}

// MARK: - 阅读器

struct ReaderView: View {
    let book: Book
    let startIndex: Int

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var model: ReaderViewModel?

    var body: some View {
        ZStack {
            readerBackground.ignoresSafeArea()

            if let model {
                VStack(spacing: 0) {
                    topBar(model)
                    content(model)
                    bottomBar(model)
                }
                .sheet(isPresented: Binding(
                    get: { model.state.showCatalog },
                    set: { model.send(.toggleCatalog($0)) }
                )) {
                    CatalogSheet(model: model)
                }
                .sheet(isPresented: Binding(
                    get: { model.state.showSettings },
                    set: { model.send(.toggleSettings($0)) }
                )) {
                    ReaderSettingsSheet()
                }
            } else {
                ProgressView()
            }
        }
        .task {
            if model == nil {
                let vm = ReaderViewModel(book: book, startIndex: startIndex, container: container)
                model = vm
                vm.send(.prepare)
            }
        }
        .statusBarHidden(false)
    }

    private var readerBackground: Color {
        switch container.settings.readerTheme {
        case 1: return Color(white: 0.99)
        case 2: return Color(red: 0.09, green: 0.09, blue: 0.11)
        default: return Color(red: 0.96, green: 0.93, blue: 0.85)
        }
    }

    private var textColor: Color {
        container.settings.readerTheme == 2 ? Color(white: 0.82) : Color(red: 0.18, green: 0.16, blue: 0.13)
    }

    private func topBar(_ model: ReaderViewModel) -> some View {
        HStack(spacing: 14) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.state.chapters.isEmpty ? model.state.book.name : model.chapter?.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(model.state.book.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                model.send(.toggleCatalog(true))
            } label: {
                Image(systemName: "list.bullet")
            }
            Button {
                model.send(.toggleSettings(true))
            } label: {
                Image(systemName: "textformat.size")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 0))
    }

    @ViewBuilder
    private func content(_ model: ReaderViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = model.state.error {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("加载失败").font(.headline)
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        Button("重试") { model.send(.retry) }
                            .buttonStyle(.glassProminent)
                    }
                    .padding(.top, 40)
                } else if model.state.isLoading && model.state.content.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在加载正文…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)
                } else {
                    Text(model.chapter?.title ?? "")
                        .font(.system(size: container.settings.fontSize + 2, weight: .semibold, design: .serif))
                        .padding(.bottom, 4)
                    ForEach(Array(paragraphs(model.state.content).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: container.settings.fontSize, design: .serif))
                            .lineSpacing(container.settings.lineSpacing)
                    }
                    if model.state.index + 1 < model.state.chapters.count {
                        Button {
                            model.send(.next)
                        } label: {
                            Text("下一章")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.glass)
                        .padding(.top, 20)
                    }
                    Text("— 本章完 —")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private func bottomBar(_ model: ReaderViewModel) -> some View {
        HStack {
            Button {
                model.send(.previous)
            } label: {
                Label("上一章", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .font(.footnote)
            }
            .disabled(model.state.index == 0)

            Spacer()

            Text("\(model.state.index + 1) / \(max(1, model.state.chapters.count))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                model.send(.next)
            } label: {
                Label("下一章", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
                    .font(.footnote)
            }
            .disabled(model.state.index + 1 >= model.state.chapters.count)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 0))
    }

    private func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - 目录

struct CatalogSheet: View {
    let model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { chapter in
                    Button {
                        model.send(.open(chapter.index))
                    } label: {
                        HStack {
                            Text(chapter.title)
                                .font(.subheadline)
                                .foregroundStyle(chapter.index == model.state.index ? Theme.accent : .primary)
                            Spacer()
                            if chapter.isVip {
                                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $keyword, prompt: "搜索章节")
            .navigationTitle("目录（\(model.state.chapters.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
        }
    }

    private var filtered: [BookChapter] {
        guard !keyword.isEmpty else { return model.state.chapters }
        return model.state.chapters.filter { $0.title.contains(keyword) }
    }
}

// MARK: - 阅读设置

struct ReaderSettingsSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("字号") {
                    HStack {
                        Image(systemName: "textformat.size.smaller")
                        Slider(value: Binding(get: { container.settings.fontSize },
                                              set: { container.settings.fontSize = $0 }),
                               in: 14...30, step: 1)
                        Image(systemName: "textformat.size.larger")
                    }
                }
                Section("行距") {
                    Slider(value: Binding(get: { container.settings.lineSpacing },
                                          set: { container.settings.lineSpacing = $0 }),
                           in: 2...20, step: 1)
                }
                Section("背景") {
                    Picker("主题", selection: Binding(get: { container.settings.readerTheme },
                                                      set: { container.settings.readerTheme = $0 })) {
                        Text("纸黄").tag(0)
                        Text("纯白").tag(1)
                        Text("夜间").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
