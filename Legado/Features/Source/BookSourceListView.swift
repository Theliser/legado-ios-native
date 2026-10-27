import SwiftUI
import UniformTypeIdentifiers

// MARK: - 书源列表

struct SourceListState {
    var sources: [BookSource] = []
    var groups: [String] = []
    var selectedGroup: String?
    var toast: ToastMessage?
    var showImport = false
}

enum SourceListIntent {
    case reload
    case selectGroup(String?)
    case toggle(BookSource)
    case delete(BookSource)
    case showImport(Bool)
    case toast(String, Bool)
}

@MainActor
@Observable
final class SourceListViewModel: MVIViewModel {
    private(set) var state = SourceListState()
    private let container: AppContainer

    init(container: AppContainer) { self.container = container }

    func send(_ intent: SourceListIntent) {
        switch intent {
        case .reload: reload()
        case .selectGroup(let group):
            state.selectedGroup = group
            reload()
        case .toggle(let source):
            container.bookSourceRepository.toggleEnabled(source)
            reload()
        case .delete(let source):
            container.bookSourceRepository.delete(source)
            state.toast = ToastMessage(text: "已删除：\(source.bookSourceName)")
            reload()
        case .showImport(let show):
            state.showImport = show
        case .toast(let text, let isError):
            state.toast = ToastMessage(text: text, isError: isError)
        }
    }

    func reload() {
        let all = container.bookSourceRepository.all
        state.groups = container.bookSourceRepository.groups
        if let group = state.selectedGroup {
            state.sources = all.filter { $0.hasGroup(group) }
        } else {
            state.sources = all
        }
    }
}

struct BookSourceListView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: SourceListViewModel?
    @State private var detail: BookSource?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if let model {
                    content(model)
                }
            }
            .navigationTitle("书源")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model?.send(.showImport(true))
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
            .navigationDestination(item: $detail) { source in
                SourceDetailView(source: source) {
                    model?.send(.reload)
                }
            }
            .sheet(isPresented: Binding(get: { model?.state.showImport ?? false },
                                        set: { model?.send(.showImport($0)) })) {
                SourceImportView { result in
                    model?.send(.showImport(false))
                    model?.send(.toast(result.summary, result.failed > 0))
                    model?.send(.reload)
                }
            }
        }
        .task {
            if model == nil {
                model = SourceListViewModel(container: container)
                model?.send(.reload)
            }
        }
    }

    @ViewBuilder
    private func content(_ model: SourceListViewModel) -> some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    chip("全部", selected: model.state.selectedGroup == nil) {
                        model.send(.selectGroup(nil))
                    }
                    ForEach(model.state.groups, id: \.self) { group in
                        chip(group, selected: model.state.selectedGroup == group) {
                            model.send(.selectGroup(group))
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)

            if model.state.sources.isEmpty {
                EmptyStateView(icon: "square.stack.3d.up",
                               title: "还没有书源",
                               message: "支持导入阅读 3.0 格式的书源 JSON",
                               actionTitle: "导入书源") {
                    model.send(.showImport(true))
                }
            } else {
                List {
                    ForEach(model.state.sources) { source in
                        Button {
                            detail = source
                        } label: {
                            row(source, model: model)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions {
                            Button(role: .destructive) {
                                model.send(.delete(source))
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .toast(Binding(get: { model.state.toast }, set: { _ in }))
    }

    private func row(_ source: BookSource, model: SourceListViewModel) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.coverColor(source.bookSourceUrl).opacity(0.25))
                Text(String(source.bookSourceName.prefix(1)))
                    .font(.subheadline.weight(.semibold))
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(source.bookSourceName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(source.enabled ? .primary : .secondary)
                Text(source.bookSourceUrl)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(source.sourceType.label)
                    if let group = source.bookSourceGroup, !group.isEmpty {
                        Text(group).lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { source.enabled },
                set: { _ in model.send(.toggle(source)) }
            ))
            .labelsHidden()
            .controlSize(.mini)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .glassCard(cornerRadius: 18)
        .padding(.vertical, 4)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(selected ? .regular.tint(Theme.accent.opacity(0.25)) : .clear, in: .capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Theme.accent : .primary)
    }
}

// MARK: - 导入

struct SourceImportView: View {
    var completion: (SourceImportResult) -> Void

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var showFilePicker = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .glassCard(cornerRadius: 18)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("粘贴书源 JSON（单条或数组）")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(18)
                                .allowsHitTesting(false)
                        }
                    }

                HStack(spacing: 10) {
                    Button {
                        if let paste = UIPasteboard.general.string {
                            text = paste
                        }
                    } label: {
                        Label("剪贴板", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.glass)

                    Button {
                        showFilePicker = true
                    } label: {
                        Label("文件", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.glass)
                }

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(16)
            .background(AppBackground())
            .navigationTitle("导入书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { importJSON() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.json, .plainText, .text]) { result in
                switch result {
                case .success(let url):
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url),
                       let content = EncodingDetect.decode(data, charset: EncodingDetect.htmlEncoding(data)) as String? {
                        text = content
                    }
                case .failure(let err):
                    error = err.localizedDescription
                }
            }
        }
    }

    private func importJSON() {
        let result = container.bookSourceRepository.importJSON(text)
        if result.added + result.updated == 0 {
            error = result.messages.first ?? "导入失败"
            return
        }
        completion(result)
        dismiss()
    }
}

// MARK: - 详情 / 调试

struct SourceDebugState {
    var section = 0
    var keyword = "诡秘之主"
    var bookUrl = ""
    var chapterUrl = ""
    var running = false
    var output = ""
    var books: [SearchBook] = []
    var chapters: [BookChapter] = []
    var content = ""
}

@MainActor
@Observable
final class SourceDebugViewModel {
    private(set) var state = SourceDebugState()
    private(set) var source: BookSource
    private let container: AppContainer

    init(source: BookSource, container: AppContainer) {
        self.source = source
        self.container = container
        self.state.bookUrl = source.bookSourceUrl
        self.state.keyword = source.getCheckKeyWord(default: "诡秘之主")
    }

    func update(_ mutate: (inout SourceDebugState) -> Void) {
        mutate(&state)
    }

    func runSearch() {
        guard !state.running else { return }
        state.running = true
        state.output = ""
        Task {
            do {
                let books = try await container.webBook.searchBook(source, key: state.keyword)
                state.books = books
                state.output = books.isEmpty
                    ? "搜索无结果（可能是关键字校验、需要登录或被 CF 拦截，请看日志）"
                    : "搜索到 \(books.count) 本"
                if let first = books.first { state.bookUrl = first.bookUrl }
            } catch {
                state.output = "失败：\(error.localizedDescription)"
            }
            state.running = false
        }
    }

    func runInfo() {
        guard !state.running else { return }
        state.running = true
        state.output = ""
        Task {
            do {
                var book = Book()
                book.bookUrl = state.bookUrl
                book.origin = source.bookSourceUrl
                book = try await container.webBook.getBookInfo(source, book: book)
                state.output = """
                书名：\(book.name)
                作者：\(book.author)
                分类：\(book.kind ?? "")
                字数：\(book.wordCount ?? "")
                最新章节：\(book.latestChapterTitle ?? "")
                目录：\(book.tocUrl)
                """
                state.chapterUrl = book.bookUrl
            } catch {
                state.output = "失败：\(error.localizedDescription)"
            }
            state.running = false
        }
    }

    func runToc() {
        guard !state.running else { return }
        state.running = true
        state.output = ""
        Task {
            do {
                var book = Book()
                book.bookUrl = state.bookUrl
                book.tocUrl = state.bookUrl
                book.origin = source.bookSourceUrl
                book = try await container.webBook.getBookInfo(source, book: book)
                let chapters = try await container.webBook.getChapterList(source, book: book)
                state.chapters = chapters
                state.output = "目录 \(chapters.count) 章，首章：\(chapters.first?.title ?? "")"
                if let chapter = chapters.first, state.chapterUrl.isEmpty {
                    state.chapterUrl = chapter.url
                }
            } catch {
                state.output = "失败：\(error.localizedDescription)"
            }
            state.running = false
        }
    }

    func runContent() {
        guard !state.running else { return }
        state.running = true
        state.output = ""
        Task {
            do {
                var book = Book()
                book.bookUrl = state.bookUrl
                book.origin = source.bookSourceUrl
                book.tocUrl = state.bookUrl
                var chapter = BookChapter(bookUrl: state.bookUrl, baseUrl: state.bookUrl)
                chapter.url = state.chapterUrl.isEmpty ? state.bookUrl : state.chapterUrl
                chapter.title = "调试章节"
                chapter.index = 0
                let content = try await container.webBook.getContent(source, book: book,
                                                                     chapter: chapter, needSave: false)
                state.content = content
                state.output = "正文 \(content.count) 字"
            } catch {
                state.output = "失败：\(error.localizedDescription)"
            }
            state.running = false
        }
    }

    func updateSource(_ mutate: (inout BookSource) -> Void) {
        mutate(&source)
    }

    func save() {
        container.bookSourceRepository.save(source)
    }
}

struct SourceDetailView: View {
    let source: BookSource
    var onChanged: () -> Void

    @Environment(AppContainer.self) private var container
    @State private var model: SourceDebugViewModel?
    @State private var refreshTick = 0

    var body: some View {
        ZStack {
            AppBackground()
            if let model {
                ScrollView {
                    VStack(spacing: 14) {
                        infoCard(model)
                        debugCard(model)
                        logCard(model)
                    }
                    .padding(16)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle(source.bookSourceName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                model = SourceDebugViewModel(source: source, container: container)
            }
            refreshTick += 1
        }
    }

    private func infoCard(_ model: SourceDebugViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.source.bookSourceUrl)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                badge(model.source.sourceType.label)
                badge("CookieJar: \(model.source.enabledCookieJar == true ? "开" : "关")")
                badge(model.source.enabled ? "已启用" : "已停用")
            }
            if let group = model.source.bookSourceGroup, !group.isEmpty {
                Text("分组：\(group)").font(.caption2).foregroundStyle(.secondary)
            }
            if let comment = model.source.bookSourceComment, !comment.isEmpty {
                Text(comment.prefix(200)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard()
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
    }

    private func debugCard(_ model: SourceDebugViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: Binding(get: { model.state.section },
                                          set: { model.update { s in s.section = $0 } })) {
                Text("搜索").tag(0)
                Text("详情").tag(1)
                Text("目录").tag(2)
                Text("正文").tag(3)
            }
            .pickerStyle(.segmented)

            switch model.state.section {
            case 0:
                field("关键字", text: Binding(get: { model.state.keyword },
                                            set: { model.update { s in s.keyword = $0 } }))
                runButton("搜索", running: model.state.running) { model.runSearch() }
            case 1, 2:
                field("书籍 / 目录页地址", text: Binding(get: { model.state.bookUrl },
                                                   set: { model.update { s in s.bookUrl = $0 } }))
                runButton(model.state.section == 1 ? "解析详情" : "解析目录",
                          running: model.state.running) {
                    model.state.section == 1 ? model.runInfo() : model.runToc()
                }
            default:
                field("章节地址", text: Binding(get: { model.state.chapterUrl },
                                             set: { model.update { s in s.chapterUrl = $0 } }))
                runButton("解析正文", running: model.state.running) { model.runContent() }
            }

            if !model.state.output.isEmpty {
                Text(model.state.output)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !model.state.content.isEmpty {
                Text(model.state.content.prefix(800))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .glassCard(cornerRadius: 12)
            }
        }
        .padding(14)
        .glassCard()
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.subheadline)
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func runButton(_ title: String, running: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if running { ProgressView().controlSize(.small) }
                Text(title)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.glassProminent)
        .disabled(running)
    }

    private func logCard(_ model: SourceDebugViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("解析日志").font(.subheadline.weight(.semibold))
                Spacer()
                Button("刷新") { refreshTick += 1 }.font(.caption)
            }
            let logs = DebugLog.shared.snapshot()
                .filter { $0.tag == model.source.bookSourceUrl || $0.tag == model.source.bookSourceName }
                .suffix(80)
            if logs.isEmpty {
                Text("暂无日志").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(logs)) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text(entry.timeText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(entry.message)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard()
        .id(refreshTick)
    }
}
