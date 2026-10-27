import SwiftUI

// MARK: - 状态

struct SourceDebugState {
    var keyword = ""
    /// 详情 / 目录阶段用的地址
    var bookUrl = ""
    /// 正文阶段用的地址
    var chapterUrl = ""
    var running = false
    var currentStage: SourceStage?
    /// 各阶段最近一次回显（同阶段覆盖，不堆积）
    var traces: [SourceTrace] = []
    /// 展开原始响应的阶段
    var expanded: Set<Int> = []
    var output = ""
    var books: [SearchBook] = []
    var chapters: [BookChapter] = []
    var content = ""
    var logVersion = 0

    func trace(_ stage: SourceStage) -> SourceTrace? {
        traces.first { $0.stage == stage }
    }
}

enum SourceDebugIntent {
    case runAll
    case run(SourceStage)
    case toggleStage(SourceStage)
    case selectChapter(BookChapter)
    case refreshLog
    case clearLog
}

// MARK: - ViewModel

@MainActor
@Observable
final class SourceDebugViewModel {
    private(set) var state = SourceDebugState()
    private(set) var source: BookSource
    private let container: AppContainer
    /// 调试专用实例：把 trace 挂在这上面，不影响主流程里的共享 WebBook
    private let webBook: WebBook

    init(source: BookSource, container: AppContainer) {
        self.source = source
        self.container = container
        self.webBook = WebBook(settings: container.settings,
                               httpClient: container.httpClient,
                               cookieStore: container.cookieStore,
                               bookRepository: container.bookRepository)
        state.keyword = source.getCheckKeyWord(default: "诡秘之主")
        state.bookUrl = source.bookSourceUrl
        webBook.trace = { [weak self] trace in
            Task { @MainActor [weak self] in self?.receive(trace) }
        }
    }

    func send(_ intent: SourceDebugIntent) {
        switch intent {
        case .runAll: runAll()
        case .run(let stage): run(stage)
        case .toggleStage(let stage):
            if state.expanded.contains(stage.rawValue) {
                state.expanded.remove(stage.rawValue)
            } else {
                state.expanded.insert(stage.rawValue)
            }
        case .selectChapter(let chapter):
            state.chapterUrl = chapter.getAbsoluteURL()
        case .refreshLog:
            state.logVersion += 1
        case .clearLog:
            DebugLog.shared.clear()
            state.logVersion += 1
        }
    }

    func update(_ mutate: (inout SourceDebugState) -> Void) {
        mutate(&state)
    }

    // MARK: - 执行

    private func receive(_ trace: SourceTrace) {
        if let index = state.traces.firstIndex(where: { $0.stage == trace.stage }) {
            state.traces[index] = trace
        } else {
            // 保持阶段顺序，而不是到达顺序
            state.traces.append(trace)
            state.traces.sort { $0.stage.rawValue < $1.stage.rawValue }
        }
        if !trace.isSuccess { state.expanded.insert(trace.stage.rawValue) }
        state.currentStage = nil
    }

    private func runAll() {
        guard !state.running else { return }
        begin()
        Task {
            defer { state.running = false }
            do {
                let keyword = state.keyword
                state.currentStage = .search
                let books = try await webBook.searchBook(source, key: keyword)
                state.books = books
                guard let first = books.first else {
                    state.output = "搜索无结果：可能关键字校验失败、需要登录，或被 CF 拦截。展开「搜索」看原始响应。"
                    return
                }
                state.bookUrl = first.bookUrl

                state.currentStage = .info
                let book = try await webBook.getBookInfo(source, book: first.toBook())
                if !book.tocUrl.isBlank { state.bookUrl = book.tocUrl }

                state.currentStage = .toc
                let chapters = try await webBook.getChapterList(source, book: book)
                state.chapters = chapters
                guard let chapter = readableChapter(in: chapters) else {
                    state.output = "目录为空"
                    return
                }
                state.chapterUrl = chapter.getAbsoluteURL()

                state.currentStage = .content
                let content = try await webBook.getContent(source, book: book, chapter: chapter,
                                                           needSave: false)
                state.content = content
                state.output = "全链路通过：\(books.count) 本 → 《\(book.name)》 → \(chapters.count) 章 → 正文 \(content.count) 字"
            } catch {
                state.output = "失败：" + errorText(error)
            }
        }
    }

    private func run(_ stage: SourceStage) {
        guard !state.running else { return }
        begin()
        Task {
            defer { state.running = false }
            state.currentStage = stage
            do {
                switch stage {
                case .search:
                    let books = try await webBook.searchBook(source, key: state.keyword)
                    state.books = books
                    state.output = books.isEmpty ? "搜索无结果" : "搜索到 \(books.count) 本"
                    if let first = books.first {
                        state.bookUrl = first.bookUrl
                        state.chapterUrl = first.bookUrl
                    }
                case .info:
                    let book = try await webBook.getBookInfo(source, book: draftBook())
                    if !book.tocUrl.isBlank { state.bookUrl = book.tocUrl }
                    state.output = """
                    书名：\(book.name)
                    作者：\(book.author)
                    分类：\(book.kind ?? "")
                    字数：\(book.wordCount ?? "")
                    最新章节：\(book.latestChapterTitle ?? "")
                    目录：\(book.tocUrl)
                    """
                case .toc:
                    let book = try await webBook.getBookInfo(source, book: draftBook())
                    let chapters = try await webBook.getChapterList(source, book: book)
                    state.chapters = chapters
                    state.output = "目录 \(chapters.count) 章"
                    if let chapter = readableChapter(in: chapters) {
                        state.chapterUrl = chapter.getAbsoluteURL()
                    }
                case .content:
                    let book = try await webBook.getBookInfo(source, book: draftBook())
                    let chapters = state.chapters.isEmpty
                        ? (try await webBook.getChapterList(source, book: book))
                        : state.chapters
                    state.chapters = chapters
                    guard let chapter = chapters.first(where: { $0.getAbsoluteURL() == state.chapterUrl })
                            ?? readableChapter(in: chapters) else {
                        state.output = "目录为空，无法解析正文"
                        return
                    }
                    state.chapterUrl = chapter.getAbsoluteURL()
                    let content = try await webBook.getContent(source, book: book, chapter: chapter,
                                                               needSave: false)
                    state.content = content
                    state.output = "正文 \(content.count) 字"
                }
            } catch {
                state.output = "失败：" + errorText(error)
            }
        }
    }

    private func begin() {
        state.running = true
        state.output = ""
        state.content = ""
        state.books = []
        state.chapters = []
        state.traces = []
        state.expanded = []
        DebugLog.shared.clear()
    }

    /// 单步调试时按地址造一本书，避免必须先跑搜索
    private func draftBook() -> Book {
        var book = Book()
        book.bookUrl = state.bookUrl.isEmpty ? source.bookSourceUrl : state.bookUrl
        book.tocUrl = book.bookUrl
        book.origin = source.bookSourceUrl
        book.type = source.bookType
        return book
    }

    private func readableChapter(in chapters: [BookChapter]) -> BookChapter? {
        chapters.first { !($0.isVolume && $0.url.hasPrefix($0.title)) }
    }

    private func errorText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

// MARK: - 详情 / 调试页

struct SourceDetailView: View {
    let source: BookSource
    var onChanged: () -> Void

    @Environment(AppContainer.self) private var container
    @State private var model: SourceDebugViewModel?
    @State private var toast: ToastMessage?

    var body: some View {
        ZStack {
            AppBackground()
            if let model {
                ScrollView {
                    VStack(spacing: 16) {
                        infoCard(model)
                        runCard(model)
                        tracesCard(model)
                        chapterCard(model)
                        logCard(model)
                    }
                    .padding(16)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle(source.bookSourceName)
        .navigationBarTitleDisplayMode(.inline)
        .toast($toast)
        .task {
            if model == nil {
                model = SourceDebugViewModel(source: source, container: container)
            }
        }
    }

    // MARK: 书源信息

    private func infoCard(_ model: SourceDebugViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.source.bookSourceUrl)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                badge(model.source.sourceType.label)
                badge(model.source.enabledCookieJar == true ? "CookieJar 开" : "CookieJar 关")
                badge(model.source.enabled ? "已启用" : "已停用")
                if model.source.isJsSource { badge("JS 源") }
            }
            if let group = model.source.bookSourceGroup, !group.isEmpty {
                Text("分组：\(group)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let comment = model.source.bookSourceComment, !comment.isEmpty {
                Text(comment.prefix(200))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
    }

    // MARK: 运行区

    private func runCard(_ model: SourceDebugViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("规则调试")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                TextField("搜索关键字", text: Binding(
                    get: { model.state.keyword },
                    set: { value in model.update { $0.keyword = value } }))
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .accessibilityLabel("搜索关键字")

                Button {
                    model.send(.runAll)
                } label: {
                    HStack(spacing: 6) {
                        if model.state.running, model.state.currentStage != nil {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.state.running ? "运行中" : "全链路")
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.state.running)
                .accessibilityLabel("运行全链路调试")
            }

            TextField("详情 / 目录地址", text: Binding(
                get: { model.state.bookUrl },
                set: { value in model.update { $0.bookUrl = value } }))
                .font(.caption)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .accessibilityLabel("详情或目录地址")

            TextField("正文页地址", text: Binding(
                get: { model.state.chapterUrl },
                set: { value in model.update { $0.chapterUrl = value } }))
                .font(.caption)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .accessibilityLabel("正文页地址")

            HStack(spacing: 8) {
                ForEach(SourceStage.allCases) { stage in
                    Button {
                        model.send(.run(stage))
                    } label: {
                        VStack(spacing: 2) {
                            Text(stage.label).font(.caption.weight(.medium))
                            if let trace = model.state.trace(stage) {
                                Image(systemName: trace.isSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(trace.isSuccess ? Color.green : Color.red)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.glass)
                    .disabled(model.state.running)
                    .accessibilityLabel("单独运行\(stage.label)解析")
                }
            }

            if !model.state.output.isEmpty {
                Text(model.state.output)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    // MARK: 阶段回显

    private func tracesCard(_ model: SourceDebugViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("阶段回显").font(.subheadline.weight(.semibold))
                Spacer()
                if model.state.running, let stage = model.state.currentStage {
                    Text("正在解析\(stage.label)…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if model.state.traces.isEmpty {
                Text("点「全链路」或下面的分阶段按钮开始")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.state.traces, id: \.stage) { trace in
                    traceRow(trace, model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    private func traceRow(_ trace: SourceTrace, model: SourceDebugViewModel) -> some View {
        let expanded = model.state.expanded.contains(trace.stage.rawValue)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                model.send(.toggleStage(trace.stage))
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: trace.isSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(trace.isSuccess ? Color.green : Color.red)
                    Text(trace.stage.label).font(.caption.weight(.semibold))
                    Text(trace.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if trace.code > 0 {
                        Text("\(trace.code)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Text("\(trace.elapsedMs)ms")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(trace.stage.label)阶段，\(trace.summary)，点击展开")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("URL").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Text(trace.url)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                    if let error = trace.error {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if let body = trace.body, !body.isEmpty {
                        ScrollView(.vertical) {
                            Text(String(body.prefix(4000)))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                        .padding(8)
                        .glassEffect(.regular, in: .rect(cornerRadius: 10))
                    }
                    Button {
                        UIPasteboard.general.string = trace.body ?? trace.url
                        toast = ToastMessage(text: "已复制")
                    } label: {
                        Label("复制响应", systemImage: "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("复制该阶段的原始响应")
                }
                .padding(.leading, 20)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: 章节选择

    @ViewBuilder
    private func chapterCard(_ model: SourceDebugViewModel) -> some View {
        if !model.state.chapters.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("目录（\(model.state.chapters.count) 章）")
                    .font(.subheadline.weight(.semibold))
                Text("点任意章节把地址填入正文调试")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.state.chapters.prefix(60)) { chapter in
                            Button {
                                model.send(.selectChapter(chapter))
                            } label: {
                                HStack(spacing: 6) {
                                    Text(chapter.title)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                    if chapter.getAbsoluteURL() == model.state.chapterUrl {
                                        Image(systemName: "arrow.left.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("选择章节 \(chapter.title)")
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassCard()
        }
    }

    // MARK: 日志

    private func logCard(_ model: SourceDebugViewModel) -> some View {
        let entries = DebugLog.shared.snapshot()
            .filter { $0.tag == model.source.bookSourceUrl || $0.tag == model.source.bookSourceName }
            .suffix(120)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("解析日志").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    model.send(.refreshLog)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("刷新日志")

                Button {
                    UIPasteboard.general.string = entries.map { "\($0.timeText) \($0.message)" }
                        .joined(separator: "\n")
                    toast = ToastMessage(text: "日志已复制")
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("复制全部日志")
            }

            if entries.isEmpty {
                Text("暂无日志").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(entries)) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text(entry.timeText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(entry.message)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(entry.message.hasPrefix("≡") || entry.message.hasPrefix("⇒")
                                             ? Color.orange : Color.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, entry.message.hasPrefix("└") ? 10 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
        .id(model.state.logVersion)
    }
}
