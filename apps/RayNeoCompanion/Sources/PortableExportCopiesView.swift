import SwiftUI

struct PortableExportCopiesView: View {
    @EnvironmentObject private var archive: LocalArchiveController
    @State private var selected: PortableExportCopy?
    @State private var confirmPurge = false
    @State private var purgeError: String?
    var body: some View {
        List {
            Section {
                Text("只管理 ZIP 导出时生成的副本目录（含快照和失败临时包），不触碰录音原归档、接收缓存或文字修订。")
                Text("移入暂存箱可恢复，也会腾出导出次数名额，但不释放磁盘空间。两边各限 20 份；永久清理暂存箱后才会释放其占用。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("目录扫描不是内容校验；需要重新分享时，请回录音详情生成新的校验包。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("刷新副本列表") { Task { await archive.loadExportCopies() } }.disabled(archive.isBusy)
                Button("永久清理暂存箱", role: .destructive) { confirmPurge = true }
                    .disabled(archive.isBusy || !archive.exportCopies.copies.contains(where: { $0.inTrash }))
                if let purgeError { Text(purgeError).foregroundStyle(Palette.amber) }
                if archive.exportCopies.unrecognized > 0 {
                    Text("\(archive.exportCopies.unrecognized) 个异常或未知目录保留原位，不提供移动操作。")
                        .foregroundStyle(Palette.amber)
                }
                if let error = archive.errorMessage { Text(error).foregroundStyle(Palette.amber) }
                if let status = archive.statusMessage { Text(status).font(.caption) }
            }
            ForEach([false, true], id: \.self) { trash in
                Section(trash ? "可恢复暂存箱" : "导出副本") {
                    let rows = archive.exportCopies.copies.filter { $0.inTrash == trash }
                    if rows.isEmpty { Text(trash ? "暂存箱为空" : "没有已生成的导出副本") }
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("导出 " + row.id.uuidString.prefix(8)).font(.headline)
                            Text(row.modifiedAt.formatted(date: .abbreviated, time: .shortened) + " · " + ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file)).font(.caption)
                            Button(trash ? "恢复这份副本" : "移入可恢复暂存箱") { selected = row }
                                .disabled(archive.isBusy).buttonStyle(.borderless)
                                .accessibilityIdentifier("export-copy-move-\(row.id.uuidString)")
                        }
                    }
                }
            }
        }.navigationTitle("ZIP 导出副本").navigationBarTitleDisplayMode(.inline)
            .task { await archive.loadExportCopies() }
            .confirmationDialog(selected.map { "\($0.inTrash ? "恢复" : "暂存")导出副本 \($0.id.uuidString.prefix(8))？只移动派生副本，原归档不变。" } ?? "确认操作",
                isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let row = selected {
                    Button(row.inTrash ? "确认恢复副本" : "确认移入暂存箱") {
                        selected = nil
                        Task { await archive.moveExportCopy(row.id, toTrash: !row.inTrash) }
                    }
                }
            }
            .confirmationDialog("永久清理暂存箱中的已识别副本？", isPresented: $confirmPurge) {
                Button("永久清理", role: .destructive) {
                    Task {
                        do { _ = try await archive.purgeExportTrash(); purgeError = nil }
                        catch { purgeError = error.localizedDescription }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("副本清理后不可恢复；原始录音归档保留。结构异常的未知文件不会删除。")
            }
    }
}
