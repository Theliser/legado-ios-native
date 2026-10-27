import SwiftUI

// MARK: - 状态

enum CheckFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case failed = "失败"
    case passed = "通过"
    case uncheckable = "无法校验"

    var id: String { rawValue }
}

struct SourceCheckViewState {
    var config = SourceCheckConfig.load()
    var candidates: [BookSource] = []
    var selected: Set<String> = []
    var results: [SourceCheckResult] = []
    var running = false
    var finished = 0
    var total = 0
    var filter: CheckFilter = .all
    var expanded: Set<String> = []
    var toast: ToastMessage?

    var progress: Double {
        total == 0 ? 0 : Double(finished) / Double(total)
    }

    var visibleResults: [SourceCheckResult] {
        switch filter {
        case .all: return results
        case .failed: return results.filter { $0.status == .failed || $0.status == .notCompleted }
        case .passed: return results.filter { $0.status == .passed }
        case .uncheckable: return results.filter { $0.status == .uncheckable }
        }
    }

    var counts: (passed: Int, failed: Int, uncheckable: Int) {
        (results.filter { $0.status == .passed }.count,
         results.filter { $0.status == .failed || $0.status == .notCompleted }.count,
         results.filter { $0.status == .uncheckable }.count)
    }
}

enum SourceCheckIntent {
    case toggle(String)
    case selectAll
    case clearSelection
    case start
    case stop
    case setFilter(CheckFilter)
    case toggleExpanded(String)
    case updateConfig((inout SourceCheckConfig) -> Void)
    case toast(String, Bool)
}

// MARK: - ViewModel

@MainActor
@Observable
final class SourceCheckViewModel {
    private(set) var state = SourceCheckViewState()
    private let container: AppContainer
    private let checker: SourceChecker
    private var job: Task<Void, Never>?

    init(container: AppContainer, sources: [BookSource]) {
        self.container = container
        self.checker = SourceChecker(container: container)
        state.candidates = sources
        state.selected = Set(sources.map(\.bookSourceUrl))
    }

    // 巡检允许跨页面继续跑（对齐上游的后台巡检），因此不在消失时取消任务

    func send(_ intent: SourceCheckIntent) {
        switch intent {
        case .toggle(let url):
            if state.selected.contains(url) {
                state.selected.remove(url)
            } else {
                state.selected.insert(url)
            }
        case .selectAll:
            if state.selected.count == state.candidates.count {
                state.selected.removeAll()
            } else {
                state.selected = Set(state.candidates.map(\.bookSourceUrl))
            }
        case .clearSelection:
            state.selected.removeAll()
        case .start:
            start()
        case .stop:
            job?.cancel()
            job = nil
            state.running = false
            state.toast = ToastMessage(text: "已停止巡检")
        case .setFilter(let filter):
            state.filter = filter
        case .toggleExpanded(let url):
            if state.expanded.contains(url) {
                state.expanded.remove(url)
            } else {
                state.expanded.insert(url)
            }
        case .updateConfig(let mutate):
            mutate(&state.config)
            state.config.save()
        case .toast(let text, let isError):
            state.toast = ToastMessage(text: text, isError: isError)
        }
    }

    private func start() {
        guard !state.running else { return }
        let selected = state.candidates.filter { state.selected.contains($0.bookSourceUrl) }
        guard !selected.isEmpty else {
            state.toast = ToastMessage(text: "先选书源", isError: true)
            return
        }
        state.running = true
        state.results = []
        state.expanded = []
        state.finished = 0
        state.total = selected.count
        state.filter = .all

        let config = state.config
        job = Task {
            await checker.check(selected, config: config) { [weak self] result in
                guard let self else { return }
                self.state.results.append(result)
                self.state.finished += 1
                if result.status.isFailure {
                    self.state.expanded.insert(result.sourceUrl)
                }
            }
            if !Task.isCancelled {
                let counts = state.counts
                state.toast = ToastMessage(
                    text: "巡检完成：通过 \(counts.passed) / 失败 \(counts.failed) / 无法校验 \(counts.uncheckable)",
                    isError: counts.failed > 0)
            }
            state.running = false
        }
    }
}

// MARK: - 页面

struct SourceCheckView: View {
    let sources: [BookSource]

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var model: SourceCheckViewModel?

    var body: some View {
        ZStack {
            AppBackground()
            if let model {
                ScrollView {
                    VStack(spacing: 16) {
                        configCard(model)
                        selectionCard(model)
                        if !model.state.results.isEmpty || model.state.running {
                            resultsCard(model)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle("书源巡检")
        .navigationBarTitleDisplayMode(.inline)
        .toast(Binding(get: { model?.state.toast },
                       set: { value in model?.setToast(value) }))
        .task {
            if model == nil {
                model = SourceCheckViewModel(container: container, sources: sources)
            }
        }
    }

    // MARK: 配置

    private func configCard(_ model: SourceCheckViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("校验项").font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.state.config.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            TextField("校验关键字", text: Binding(
                get: { model.state.config.keyword },
                set: { value in model.send(.updateConfig { $0.keyword = value }) }))
                .font(.subheadline)
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .accessibilityLabel("校验关键字")

            HStack(spacing: 8) {
                toggleChip("搜索", on: model.state.config.checkSearch) {
                    model.send(.updateConfig { $0.checkSearch.toggle() })
                }
                toggleChip("详情", on: model.state.config.checkInfo) {
                    model.send(.updateConfig { $0.checkInfo.toggle() })
                }
                toggleChip("目录", on: model.state.config.checkToc) {
                    model.send(.updateConfig { $0.checkToc.toggle() })
                }
                toggleChip("正文", on: model.state.config.checkContent) {
                    model.send(.updateConfig { $0.checkContent.toggle() })
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("超时 \(Int(model.state.config.timeout))s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { model.state.config.timeout },
                        set: { value in model.send(.updateConfig { $0.timeout = value }) }),
                           in: 30...300, step: 30)
                        .accessibilityLabel("单个书源超时时间")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("并发 \(model.state.config.concurrency)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Stepper("", value: Binding(
                        get: { model.state.config.concurrency },
                        set: { value in model.send(.updateConfig { $0.concurrency = value }) }),
                            in: 1...8)
                        .labelsHidden()
                        .accessibilityLabel("巡检并发数")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    private func toggleChip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.caption2)
                Text(title).font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(on ? Theme.accent.opacity(0.22) : Color.clear), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)校验项，当前\(on ? "开启" : "关闭")")
    }

    // MARK: 选择

    private func selectionCard(_ model: SourceCheckViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("书源（已选 \(model.state.selected.count)/\(model.state.candidates.count)）")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(model.state.selected.count == model.state.candidates.count ? "全不选" : "全选") {
                    model.send(.selectAll)
                }
                .font(.caption)
                .buttonStyle(.glass)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.state.candidates) { source in
                        let on = model.state.selected.contains(source.bookSourceUrl)
                        Button {
                            model.send(.toggle(source.bookSourceUrl))
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: on ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(on ? Theme.accent : Color.secondary)
                                Text(source.bookSourceName)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Text(source.bookSourceUrl)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("书源 \(source.bookSourceName)，\(on ? "已选" : "未选")")
                    }
                }
            }
            .frame(maxHeight: 220)

            Button {
                model.state.running ? model.send(.stop) : model.send(.start)
            } label: {
                HStack(spacing: 8) {
                    if model.state.running {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.state.running ? "停止" : "开始巡检")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel(model.state.running ? "停止巡检" : "开始巡检")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    // MARK: 结果

    private func resultsCard(_ model: SourceCheckViewModel) -> some View {
        let counts = model.state.counts
        return VStack(alignment: .leading, spacing: 10) {
            if model.state.running {
                ProgressView(value: model.state.progress) {
                    Text("\(model.state.finished)/\(model.state.total)")
                        .font(.caption2)
                }
                .tint(Theme.accent)
            }

            HStack(spacing: 8) {
                ForEach(CheckFilter.allCases) { filter in
                    Button {
                        model.send(.setFilter(filter))
                    } label: {
                        Text("\(filter.rawValue) \(countText(filter, counts))")
                            .font(.caption2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .glassEffect(.regular.tint(model.state.filter == filter
                                                       ? Theme.accent.opacity(0.22) : Color.clear),
                                         in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("筛选 \(filter.rawValue)")
                }
            }

            ForEach(model.state.visibleResults) { result in
                resultRow(result, model: model)
            }

            if model.state.visibleResults.isEmpty, !model.state.running {
                Text("该分类下没有结果")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    private func countText(_ filter: CheckFilter,
                           _ counts: (passed: Int, failed: Int, uncheckable: Int)) -> String {
        switch filter {
        case .all: return "\(counts.passed + counts.failed + counts.uncheckable)"
        case .failed: return "\(counts.failed)"
        case .passed: return "\(counts.passed)"
        case .uncheckable: return "\(counts.uncheckable)"
        }
    }

    private func resultRow(_ result: SourceCheckResult, model: SourceCheckViewModel) -> some View {
        let expanded = model.state.expanded.contains(result.sourceUrl)
        let color: Color = result.status == .passed ? .green
            : (result.status == .uncheckable ? .orange : .red)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                model.send(.toggleExpanded(result.sourceUrl))
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: result.status.symbol)
                        .foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(result.sourceName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(result.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Text(result.elapsedText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(result.sourceName)，\(result.status.label)，\(result.detail)")

            if expanded, !result.traces.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.traces, id: \.stage) { trace in
                        HStack(spacing: 6) {
                            Image(systemName: trace.isSuccess ? "checkmark.circle" : "xmark.octagon")
                                .font(.system(size: 9))
                                .foregroundStyle(trace.isSuccess ? Color.green : Color.red)
                            Text(trace.stage.label)
                                .font(.system(size: 10, weight: .medium))
                            Text(trace.summary)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(trace.elapsedMs)ms")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 便捷

extension SourceCheckViewModel {
    /// toast 自动消失时把状态清空；不能走 send(.toast)，否则会再触发一轮显示
    func setToast(_ message: ToastMessage?) {
        state.toast = message
    }
}
