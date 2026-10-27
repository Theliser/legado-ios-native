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
    @State private var showCheck = false

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
                        showCheck = true
                    } label: {
                        Image(systemName: "stethoscope")
                    }
                    .accessibilityLabel("书源巡检")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model?.send(.showImport(true))
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("导入书源")
                }
            }
            .navigationDestination(item: $detail) { source in
                SourceDetailView(source: source) {
                    model?.send(.reload)
                }
            }
            .navigationDestination(isPresented: $showCheck) {
                SourceCheckView(sources: model?.state.sources ?? [])
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
