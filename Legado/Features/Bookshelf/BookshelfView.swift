import SwiftUI

// MARK: - State / Intent

struct BookshelfState {
    var books: [Book] = []
    var groups: [BookGroup] = []
    var selectedGroup: Int64 = BookGroup.allGroupId
    var isLoading = false
    var toast: ToastMessage?
    var showImport = false
}

enum BookshelfIntent {
    case reload
    case selectGroup(Int64)
    case delete(Book)
    case showImport(Bool)
    case toast(String, Bool)
}

// MARK: - ViewModel

@MainActor
@Observable
final class BookshelfViewModel: MVIViewModel {
    private(set) var state = BookshelfState()
    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
    }

    func send(_ intent: BookshelfIntent) {
        switch intent {
        case .reload:
            reload()
        case .selectGroup(let id):
            state.selectedGroup = id
            reload()
        case .delete(let book):
            container.bookRepository.delete(book)
            toast("已移出书架：\(book.name)", error: false)
            reload()
        case .showImport(let show):
            state.showImport = show
        case .toast(let text, let isError):
            state.toast = ToastMessage(text: text, isError: isError)
        }
    }

    func reload() {
        state.groups = container.bookGroupRepository.groups
        state.isLoading = true
        state.books = container.bookRepository.books(inGroup: state.selectedGroup)
        state.isLoading = false
    }

    func toast(_ text: String, error: Bool) {
        state.toast = ToastMessage(text: text, isError: error)
    }
}

// MARK: - View

struct BookshelfView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: BookshelfViewModel?
    @State private var reading: Book?
    @State private var detail: Book?

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 18)]

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                content
            }
            .navigationTitle("书架")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model?.send(.showImport(true))
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("导入书源")
                }
            }
            .navigationDestination(item: $detail) { book in
                BookDetailView(book: book) { index in
                    reading = book
                    pendingChapter = index
                }
            }
            .fullScreenCover(item: $reading) { book in
                ReaderView(book: book, startIndex: pendingChapter ?? book.durChapterIndex)
            }
            .sheet(isPresented: Binding(
                get: { model?.state.showImport ?? false },
                set: { model?.send(.showImport($0)) }
            )) {
                SourceImportView { result in
                    model?.send(.showImport(false))
                    model?.send(.toast(result.summary, result.failed > 0))
                    model?.send(.reload)
                }
            }
        }
        .task {
            if model == nil {
                model = BookshelfViewModel(container: container)
                model?.send(.reload)
            }
        }
    }

    @State private var pendingChapter: Int?

    @ViewBuilder
    private var content: some View {
        if let model {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    groupChips(model)
                        .padding(.horizontal, 20)

                    if model.state.books.isEmpty {
                        EmptyStateView(icon: "books.vertical",
                                       title: "书架还是空的",
                                       message: "去「发现」搜索一本书，或先在「书源」里导入书源",
                                       actionTitle: nil, action: nil)
                    } else {
                        LazyVGrid(columns: columns, spacing: 22) {
                            ForEach(model.state.books) { book in
                                Button {
                                    detail = book
                                } label: {
                                    BookGridItem(book: book)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("继续阅读") {
                                        pendingChapter = book.durChapterIndex
                                        reading = book
                                    }
                                    Button("书籍详情") { detail = book }
                                    Button("移出书架", role: .destructive) {
                                        model.send(.delete(book))
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                    }
                }
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .refreshable { model.send(.reload) }
            .toast(Binding(get: { model.state.toast },
                           set: { _ in }))
        }
    }

    private func groupChips(_ model: BookshelfViewModel) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                chip(title: "全部", selected: model.state.selectedGroup == BookGroup.allGroupId) {
                    model.send(.selectGroup(BookGroup.allGroupId))
                }
                ForEach(model.state.groups.filter { $0.groupId != 0 }) { group in
                    chip(title: group.groupName,
                         selected: model.state.selectedGroup == group.groupId) {
                        model.send(.selectGroup(group.groupId))
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassEffect(selected ? .regular.tint(Theme.accent.opacity(0.28)) : .clear,
                             in: .capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Theme.accent : .primary)
    }
}

// MARK: - 网格项

struct BookGridItem: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BookCoverView(book: book)
                .frame(height: 152)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if book.unreadChapterNum > 0 {
                        Text("+\(book.unreadChapterNum)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .glassEffect(.regular.tint(Color.red.opacity(0.5)), in: .capsule)
                            .padding(6)
                    }
                }
                .shadow(color: .black.opacity(0.18), radius: 10, y: 6)

            Text(book.name)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
            Text(book.author)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct BookCoverView: View {
    let book: Book

    var body: some View {
        ZStack {
            Theme.coverGradient(book.name + book.author)
            if let cover = book.displayCover, let url = URL(string: cover) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Text(String(book.name.prefix(1)))
                .font(.system(size: 34, weight: .semibold, design: .serif))
                .foregroundStyle(.white.opacity(0.95))
            Text(book.name)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }
}
