import SwiftUI

struct SearchState {
    var keyword: String = ""
    var isSearching = false
    var finished = 0
    var total = 0
    var groups: [SearchResultGroup] = []
    var toast: ToastMessage?
    var error: String?
}

struct SearchResultGroup: Identifiable {
    var id: String { "\(name)|\(author)" }
    var name: String
    var author: String
    var coverUrl: String?
    var intro: String?
    var kind: String?
    var wordCount: String?
    var latestChapter: String?
    var items: [SourceResult]
}

struct SourceResult: Identifiable {
    var id: String { book.bookUrl }
    var book: SearchBook
    var sourceName: String
    var respondTime: Int
}

enum SearchIntent {
    case updateKeyword(String)
    case search
    case addToShelf(SearchBook)
    case toast(String, Bool)
}

@MainActor
@Observable
final class SearchViewModel: MVIViewModel {
    private(set) var state = SearchState()
    private let container: AppContainer
    private var task: Task<Void, Never>?

    init(container: AppContainer) {
        self.container = container
    }

    func send(_ intent: SearchIntent) {
        switch intent {
        case .updateKeyword(let text):
            state.keyword = text
        case .search:
            startSearch()
        case .addToShelf(let book):
            let added = container.bookRepository.addToShelf(book)
            state.toast = ToastMessage(text: "已加入书架：\(added.name)")
        case .toast(let text, let isError):
            state.toast = ToastMessage(text: text, isError: isError)
        }
    }

    private func startSearch() {
        let keyword = state.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        task?.cancel()

        let sources = container.bookSourceRepository.enabledSources
        guard !sources.isEmpty else {
            state.error = "还没有可用书源，请先在「书源」里导入"
            return
        }

        state.isSearching = true
        state.error = nil
        state.groups = []
        state.finished = 0
        state.total = sources.count

        task = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: (BookSource, [SearchBook])?.self) { group in
                var index = 0
                let limit = max(2, min(8, container.settings.threadCount / 2))
                while index < sources.count {
                    if index >= limit, let result = await group.next() {
                        await self.consume(result)
                    }
                    let source = sources[index]
                    group.addTask {
                        do {
                            let books = try await self.container.webBook.searchBook(source, key: keyword)
                            return (source, books)
                        } catch {
                            DebugLog.shared.log(source.bookSourceName, "搜索失败: \(error.localizedDescription)")
                            return nil
                        }
                    }
                    index += 1
                }
                for await result in group {
                    await self.consume(result)
                }
            }
            await MainActor.run {
                self.state.isSearching = false
            }
        }
    }

    private func consume(_ result: (BookSource, [SearchBook])?) {
        state.finished += 1
        guard let (source, books) = result else { return }
        for book in books {
            merge(book, source: source)
        }
    }

    private func merge(_ book: SearchBook, source: BookSource) {
        let key = "\(book.name)|\(book.author)"
        if let index = state.groups.firstIndex(where: { $0.id == key }) {
            if !state.groups[index].items.contains(where: { $0.book.bookUrl == book.bookUrl }) {
                state.groups[index].items.append(SourceResult(book: book,
                                                              sourceName: source.bookSourceName,
                                                              respondTime: Int(source.respondTime)))
            }
        } else {
            state.groups.append(SearchResultGroup(
                name: book.name,
                author: book.author,
                coverUrl: book.coverUrl,
                intro: book.intro,
                kind: book.kind,
                wordCount: book.wordCount,
                latestChapter: book.latestChapterTitle,
                items: [SourceResult(book: book,
                                     sourceName: source.bookSourceName,
                                     respondTime: Int(source.respondTime))]
            ))
        }
        state.groups.sort { $0.items.count > $1.items.count }
    }
}

// MARK: - View

struct SearchView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: SearchViewModel?
    @State private var keyword = ""
    @State private var detail: SearchBook?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if let model {
                    VStack(spacing: 12) {
                        searchField(model)
                        if model.state.isSearching {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("搜索中 \(model.state.finished)/\(model.state.total)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        results(model)
                    }
                }
            }
            .navigationTitle("发现")
            .navigationDestination(item: $detail) { book in
                SearchBookDetailView(searchBook: book)
            }
        }
        .task {
            if model == nil { model = SearchViewModel(container: container) }
        }
    }

    private func searchField(_ model: SearchViewModel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("书名或作者", text: $keyword)
                .submitLabel(.search)
                .onSubmit {
                    model.send(.updateKeyword(keyword))
                    model.send(.search)
                }
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            Button("搜索") {
                model.send(.updateKeyword(keyword))
                model.send(.search)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        }
        .padding(12)
        .glassCard(cornerRadius: 20)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func results(_ model: SearchViewModel) -> some View {
        if let error = model.state.error, model.state.groups.isEmpty {
            EmptyStateView(icon: "books.vertical", title: "无法搜索", message: error)
        } else if model.state.groups.isEmpty && !model.state.isSearching {
            EmptyStateView(icon: "sparkle.magnifyingglass",
                           title: "搜索全网书源",
                           message: "输入书名，多个书源会同时检索并按书名聚合同一本书")
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.state.groups) { group in
                        resultCard(group, model: model)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func resultCard(_ group: SearchResultGroup, model: SearchViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Theme.coverGradient(group.name + group.author)
                    Text(String(group.name.prefix(1)))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 56, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(group.name).font(.headline).lineLimit(2)
                    Text(group.author).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if let kind = group.kind, !kind.isEmpty {
                            Text(kind).lineLimit(1)
                        }
                        if let word = group.wordCount, !word.isEmpty {
                            Text(word)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if let intro = group.intro, !intro.isEmpty {
                Text(intro)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(group.items) { item in
                        Button {
                            detail = item.book
                        } label: {
                            HStack(spacing: 6) {
                                Text(item.sourceName)
                                    .font(.caption)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .glassEffect(.regular.tint(Theme.accent.opacity(0.18)), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("加入书架") { model.send(.addToShelf(item.book)) }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(14)
        .glassCard()
    }
}

/// 搜索结果里的单本源详情（可直接入架）
struct SearchBookDetailView: View {
    let searchBook: SearchBook
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var added = false

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        ZStack {
                            Theme.coverGradient(searchBook.name + searchBook.author)
                            Text(String(searchBook.name.prefix(1)))
                                .font(.largeTitle.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 100, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(searchBook.name).font(.title3.weight(.semibold))
                            Text(searchBook.author).font(.subheadline).foregroundStyle(.secondary)
                            Text(searchBook.originName).font(.caption).foregroundStyle(.secondary)
                            if let latest = searchBook.latestChapterTitle {
                                Text("最新：\(latest)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .glassCard()

                    Button {
                        _ = container.bookRepository.addToShelf(searchBook)
                        added = true
                    } label: {
                        Label(added ? "已在书架" : "加入书架", systemImage: added ? "checkmark" : "plus")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(added)

                    if let intro = searchBook.intro, !intro.isEmpty {
                        Text(intro)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineSpacing(4)
                            .padding(16)
                            .glassCard()
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("书籍")
        .navigationBarTitleDisplayMode(.inline)
    }
}

