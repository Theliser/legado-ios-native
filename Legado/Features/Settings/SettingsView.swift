import SwiftUI

struct SettingsView: View {
    @Environment(AppContainer.self) private var container
    @State private var showCookieClearConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                Form {
                    Section("网络") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("User-Agent").font(.caption).foregroundStyle(.secondary)
                            TextField("User-Agent", text: Binding(
                                get: { container.settings.userAgent },
                                set: { container.settings.userAgent = $0 }
                            ), axis: .vertical)
                            .font(.caption.monospaced())
                            .lineLimit(2...4)
                        }
                        Stepper("并发线程：\(container.settings.threadCount)",
                                value: Binding(get: { container.settings.threadCount },
                                               set: { container.settings.threadCount = max(1, min(32, $0)) }),
                                in: 1...32)
                        Toggle("信任自签/过期证书", isOn: Binding(
                            get: { container.settings.allowInsecureTLS },
                            set: { container.settings.allowInsecureTLS = $0 }
                        ))
                        Button("清空所有 Cookie", role: .destructive) {
                            showCookieClearConfirm = true
                        }
                    }

                    Section("调试") {
                        Toggle("记录解析日志", isOn: Binding(
                            get: { container.settings.enableDebugLog },
                            set: { container.settings.enableDebugLog = $0 }
                        ))
                        NavigationLink("解析日志") { DebugLogView() }
                    }

                    Section("数据") {
                        LabeledContent("书源数量", value: "\(container.bookSourceRepository.count)")
                        LabeledContent("书架数量", value: "\(container.bookRepository.books.count)")
                        NavigationLink("书源导入") {
                            SourceImportStandaloneView()
                        }
                    }

                    Section("关于") {
                        LabeledContent("版本", value: "1.0.0 (复刻版)")
                        LabeledContent("架构", value: "MVI + GRDB + JavaScriptCore")
                        Text("规则引擎与数据层对齐 legado-with-MD3，UI 使用 iOS 26 液态玻璃。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("我的")
            .confirmationDialog("清空后需要重新登录各书源站点", isPresented: $showCookieClearConfirm) {
                Button("清空 Cookie", role: .destructive) {
                    container.cookieStore.clear()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}

struct DebugLogView: View {
    @State private var logs: [DebugLogEntry] = []
    @State private var filter = ""

    var body: some View {
        List {
            ForEach(filtered) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.tag).font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                        Spacer()
                        Text(entry.timeText).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    Text(entry.message).font(.caption.monospaced())
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $filter, prompt: "过滤日志")
        .navigationTitle("解析日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("清空") { DebugLog.shared.clear(); refresh() }
        }
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
    }

    private var filtered: [DebugLogEntry] {
        let all = logs
        guard !filter.isEmpty else { return Array(all.suffix(300)) }
        return all.filter { $0.message.contains(filter) || $0.tag.contains(filter) }
    }

    private func refresh() {
        logs = DebugLog.shared.snapshot()
    }
}

struct SourceImportStandaloneView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        ZStack {
            AppBackground()
            SourceImportView { result in
                message = result.summary
                dismiss()
            }
        }
    }
}
