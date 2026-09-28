import SwiftUI

struct StorageSpaceView: View {
    @EnvironmentObject private var store: CompanionStore

    var body: some View {
        StorageSpaceDashboard(store: store)
    }
}

private struct StorageSpaceDashboard: View {
    private let store: CompanionStore
    @StateObject private var inventory: LocalStorageInventory
    @State private var sortBySize = true
    @State private var sessionSearch = ""
    @State private var sessionLimit = 20
    @State private var otherLimit = 15
    @State private var pendingAction: StorageCleanupAction?
    @State private var working = false
    @State private var resultMessage: String?
    @State private var resultError: String?

    init(store: CompanionStore) {
        self.store = store
        _inventory = StateObject(wrappedValue: LocalStorageInventory(store: store))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summary
                if let error = inventory.error {
                    feedback(error, icon: "exclamationmark.triangle", tint: Palette.amber)
                }
                if let error = resultError {
                    feedback(error, icon: "exclamationmark.triangle", tint: Palette.amber)
                }
                if let resultMessage {
                    feedback(resultMessage, icon: "checkmark.circle", tint: Palette.green)
                }
                if inventory.lastScannedAt != nil {
                    cacheSection
                    breakdown
                    sessionsSection
                    otherDataSection
                }
            }
            .padding(20)
            .padding(.bottom, 80)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("存储空间")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await inventory.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(inventory.scanning || working)
                .accessibilityLabel("重新扫描存储空间")
                .accessibilityIdentifier("storage-refresh")
            }
        }
        .preference(key: CompanionTabBarHiddenPreference.self, value: true)
        .task { await inventory.refresh() }
        .alert(pendingAction?.title ?? "确认清理", isPresented: Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        )) {
            if let pendingAction {
                Button(pendingAction.buttonTitle, role: .destructive) {
                    let action = pendingAction
                    self.pendingAction = nil
                    Task { await run(action) }
                }
            }
            Button("取消", role: .cancel) { pendingAction = nil }
        } message: {
            Text(pendingAction?.message ?? "")
        }
    }

    private var summary: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 28))
                    .foregroundStyle(Palette.green)
                    .frame(width: 44, height: 44)
                    .background(Palette.mint.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text("本 App 已知文件")
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                    Text(inventory.lastScannedAt == nil ? "等待扫描" : size(inventory.totalBytes))
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .accessibilityIdentifier("storage-total")
                }
                Spacer(minLength: 0)
            }
            if inventory.scanning || working {
                ProgressView(working ? "正在清理并更新占用…" : "正在统计本机文件…")
                    .accessibilityIdentifier("storage-progress")
            } else {
                HStack {
                    Label("可清理缓存约 " + size(inventory.reclaimableCacheBytes),
                          systemImage: "sparkles")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.green)
                    Spacer()
                }
                if let scannedAt = inventory.lastScannedAt {
                    Text("上次扫描：" + scannedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                }
            }
            Text("仅统计 Turbo IO 在本机的已知目录。iOS 管理的语音模型、翻译语言包及系统空间不计入；占用会随录音和导出变化。")
                .font(.caption)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = inventory.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Palette.amber)
            }
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            let occupied = inventory.categories.filter { $0.bytes > 0 }
                .sorted { $0.bytes > $1.bytes }
            SectionLabel(title: "占用明细", trailing: "\(occupied.count) 类有文件")
            Card {
                if occupied.isEmpty {
                    Text("已知目录暂时没有可统计的文件。")
                        .font(.subheadline).foregroundStyle(Palette.muted)
                }
                ForEach(occupied, id: \.kind) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: category.isCache ? "doc.zipper" : "folder")
                                .foregroundStyle(Palette.green)
                                .frame(width: 22)
                            Text(category.title)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(size(category.bytes))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Palette.ink)
                        }
                        ProgressView(value: Double(category.bytes),
                                     total: Double(max(1, inventory.totalBytes)))
                            .tint(category.isCache ? Palette.mint : Palette.green)
                        Text("\(category.fileCount) 个文件 · \(category.description)")
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    if category.kind != occupied.last?.kind {
                        Divider().overlay(Palette.line)
                    }
                }
                if occupied.count < inventory.categories.count {
                    Text("其余 \(inventory.categories.count - occupied.count) 类当前为 0 字节。")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "可清理副本与缓存", trailing: size(inventory.categories.filter { $0.canClear }.reduce(0) { $0 + $1.clearableBytes }))
            Card {
                Text("缓存清理只移除较早生成的分享文件；ZIP 暂存箱中的副本可单独永久清理。原始归档不受影响。")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                NavigationLink("查看和整理 ZIP 导出副本") { PortableExportCopiesView() }
                    .font(.subheadline.weight(.medium))
                let clearable = inventory.categories.filter { $0.canClear }
                if clearable.isEmpty {
                    Text("目前没有可清理的导出副本或缓存。")
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                }
                ForEach(clearable, id: \.kind) { category in
                    Divider().overlay(Palette.line)
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(category.title).font(.subheadline.weight(.medium))
                            Text("当前占用 \(size(category.bytes)) · 可清理 \(size(category.clearableBytes))")
                                .font(.caption).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button(category.isCache ? "清理缓存" : "清空暂存箱") { pendingAction = .cache(category) }
                            .buttonStyle(.bordered)
                            .disabled(working || inventory.scanning || category.clearableBytes == 0)
                            .accessibilityIdentifier("storage-clear-cache-\(String(describing: category.kind))")
                    }
                }
            }
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(title: "字幕会话", trailing: "\(subtitleRecords.count) 条")
                Spacer()
                Picker("排序", selection: $sortBySize) {
                    Text("占用最大").tag(true)
                    Text("最近创建").tag(false)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("storage-session-sort")
            }
            TextField("搜索会话名称", text: $sessionSearch)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("storage-session-search")
            if filteredSubtitleRecords.isEmpty {
                Card {
                    Text(subtitleRecords.isEmpty ? "本机还没有可查看的字幕会话。" : "没有符合搜索条件的会话。")
                        .foregroundStyle(Palette.muted)
                }
            } else {
                ForEach(Array(sortedSubtitleRecords.prefix(sessionLimit))) { record in
                    recordCard(record)
                }
                if sortedSubtitleRecords.count > sessionLimit {
                    Button("再显示 \(min(20, sortedSubtitleRecords.count - sessionLimit)) 条会话") {
                        sessionLimit += 20
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var otherDataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "其他个人资料", trailing: "\(otherRecords.count) 条记录")
            Card {
                Text("眼镜接收录音、已核验归档和恢复暂存文件会分别计入上面的占用明细。目前只对已有安全删除流程的资料提供清理；未知文件和归档内部事务文件会保留。")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if otherRecords.isEmpty {
                    Text("没有逐条可管理的其他记录。")
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                }
            }
            ForEach(Array(otherRecords.prefix(otherLimit))) { record in
                recordCard(record)
            }
            if otherRecords.count > otherLimit {
                Button("再显示 \(min(15, otherRecords.count - otherLimit)) 条资料") {
                    otherLimit += 15
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func recordCard(_ record: StorageRecord) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: (record.audioBytes ?? 0) > 0 ? "waveform" : "doc.text")
                    .foregroundStyle(Palette.green)
                    .frame(width: 25)
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.title).font(.subheadline.weight(.semibold)).privacySensitive()
                        .lineLimit(2)
                    Text(record.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(Palette.muted)
                    if case .other = record.id {
                        Text(record.category.title)
                            .font(.caption2).foregroundStyle(Palette.muted)
                    }
                }
                Spacer()
                Text(size(record.bytes))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Palette.ink)
            }
            if case .subtitle = record.id {
                HStack {
                    Label("录音 " + size(record.audioBytes ?? 0), systemImage: "waveform")
                    Spacer()
                    Text("其他 " + size(max(0, record.bytes - (record.audioBytes ?? 0))))
                }
                .font(.caption)
                .foregroundStyle(Palette.muted)
            }
            HStack(spacing: 16) {
                recordDestination(record)
                Spacer()
                if case .subtitle = record.id, (record.audioBytes ?? 0) > 0 {
                    Button("只清录音") { pendingAction = .audio(record) }
                        .disabled(working || inventory.scanning || !record.canDelete)
                }
                if record.canDelete {
                    Button("删除", role: .destructive) { pendingAction = .record(record) }
                        .disabled(working || inventory.scanning)
                }
            }
            .font(.caption.weight(.medium))
            .accessibilityIdentifier("storage-record-actions-\(String(describing: record.id))")
        }
    }

    @ViewBuilder private func recordDestination(_ record: StorageRecord) -> some View {
        switch record.id {
        case .subtitle(let id):
            NavigationLink("查看与导出") { SubtitleSessionDetailView(id: id) }
        case .alwaysOnDay:
            EmptyView()
        case .other(let kind, let value):
            switch kind {
            case .verifiedRecordings:
                if let id = UUID(uuidString: value),
                   let recording = store.archive.recordings.first(where: { $0.id == id }) {
                    NavigationLink("查看归档与导出") { ArchiveDetailView(original: recording) }
                }
            case .importedRecordings:
                NavigationLink("查看旧版录音") { LegacyRecordingsView() }
            case .recordingInbox:
                NavigationLink("查看接收与恢复") { RecordingRecoveryView() }
            case .portableExports, .portableTrash:
                NavigationLink("管理导出副本") { PortableExportCopiesView() }
            default:
                EmptyView()
            }
        }
    }

    private var subtitleRecords: [StorageRecord] {
        inventory.records.filter {
            if case .subtitle = $0.id { return true }
            return false
        }
    }

    private var sortedSubtitleRecords: [StorageRecord] {
        filteredSubtitleRecords.sorted {
            sortBySize ? ($0.bytes == $1.bytes ? $0.date > $1.date : $0.bytes > $1.bytes)
                       : $0.date > $1.date
        }
    }

    private var filteredSubtitleRecords: [StorageRecord] {
        let term = sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return subtitleRecords }
        return subtitleRecords.filter { $0.title.localizedCaseInsensitiveContains(term) }
    }

    private var otherRecords: [StorageRecord] {
        inventory.records.filter {
            if case .subtitle = $0.id { return false }
            return true
        }
        .sorted { $0.date > $1.date }
    }

    private func feedback(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(tint)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private func run(_ action: StorageCleanupAction) async {
        working = true
        resultMessage = nil
        resultError = nil
        defer { working = false }
        do {
            switch action {
            case .cache(let category):
                let before = inventory.totalBytes
                try await inventory.clearCache(category.kind)
                resultMessage = "已清理 \(category.title)，本次释放约 \(size(max(0, before - inventory.totalBytes)))。"
            case .audio(let record):
                guard case .subtitle(let id) = record.id else { return }
                let freed = try await inventory.purgeSubtitleAudio(id)
                resultMessage = "已清理 \(record.title) 的录音约 \(size(freed))；字幕仍保留。"
            case .record(let record):
                try await inventory.delete(record)
                resultMessage = "已删除 \(record.title) 的本机资料。"
            }
        } catch {
            resultError = "清理未完成：\(error.localizedDescription)。请刷新占用后查看哪些文件仍保留。"
        }
    }
}

private enum StorageCleanupAction {
    case cache(StorageCategory)
    case audio(StorageRecord)
    case record(StorageRecord)

    var title: String {
        switch self {
        case .cache(let category): return category.isCache ? "清理\(category.title)？" : "永久清空\(category.title)？"
        case .audio: return "只清理这段录音？"
        case .record: return "永久删除这条记录？"
        }
    }
    var buttonTitle: String {
        switch self {
        case .cache(let category): return category.isCache ? "清理缓存" : "永久清理副本"
        case .audio: return "删除录音，保留字幕"
        case .record: return "永久删除"
        }
    }
    var message: String {
        switch self {
        case .cache(let category):
            return category.isCache
                ? "预计清理约 \(format(category.clearableBytes)) 的已生成副本；原始录音和字幕保留。最近生成的副本不会清理。"
                : "将永久删除暂存箱中已识别的导出副本约 \(format(category.clearableBytes))。清理后无法从暂存箱恢复，但原始归档仍保留；未知文件不会删除。"
        case .audio(let record):
            return "将删除“\(record.title)”的本机录音约 \(format(record.audioBytes ?? 0))。字幕、译文和会话信息保留，但此会话将无法回听，不能撤销；请先导出需要保留的录音。不会删除眼镜上的文件。"
        case .record(let record):
            return "将删除“\(record.title)”的本机资料约 \(format(record.bytes))，包括此记录的文字和录音。不能撤销；请先导出需要保留的内容。不会删除眼镜上的文件。"
        }
    }
    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
