import SwiftUI
import AppKit

@MainActor
struct HistoryBrowserView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let repo: GitRepository
    let branches: [String]
    let refreshID: UUID
    var file: String? = nil
    var model: Workspace? = nil
    @State private var commits: [CommitRecord] = []
    @State private var selection: String?
    @State private var query = ""
    @State private var reference = ""
    @State private var loadedReference = ""
    @State private var limit = 200
    @State private var loading = false
    @State private var error: String?
    private var filtered: [CommitRecord] { commits.filter { $0.matches(query) } }
    private var current: CommitRecord? { filtered.first { $0.id == selection } ?? filtered.first }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("コミット ID・メッセージ・作成者を検索"), text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("historySearch")
                Picker(L("履歴"), selection: $reference) {
                    Text(L("すべてのブランチ")).tag("")
                    Text(L("現在の HEAD")).tag("HEAD")
                    ForEach(branches, id: \.self) { Text($0).tag("refs/heads/" + $0) }
                }.frame(width: 250)
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            VSplitView {
                VStack(spacing: 0) {
                    Table(filtered, selection: Binding(get: { current?.id }, set: { selection = $0 })) {
                        TableColumn(L("コミット")) { commit in
                            HStack(spacing: 8) {
                                Image(systemName: commit.parents.count > 1 ? "arrow.triangle.merge" : "circle.fill")
                                    .font(.system(size: commit.parents.count > 1 ? 12 : 6)).foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(commit.subject).lineLimit(1)
                                    if !commit.decorations.isEmpty { Text(commit.decorations).font(.caption2).foregroundStyle(.cyan).lineLimit(1) }
                                }
                            }.padding(.vertical, 3).help(commit.message)
                        }.width(min: 250, ideal: 460)
                        TableColumn(L("作成者"), value: \.author).width(min: 100, ideal: 145, max: 210)
                        TableColumn(L("日時"), value: \.displayDate).width(145)
                        TableColumn("ID") { Text($0.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.width(min: 300, ideal: 340, max: 520)
                    }.accessibilityIdentifier("commitTable")
                    .overlay {
                        if loading && commits.isEmpty { ProgressView(L("履歴を読み込み中…")) }
                        else if filtered.isEmpty { Text(commits.isEmpty ? L("まだコミットはありません") : L("一致するコミットはありません")).foregroundStyle(.secondary) }
                    }
                    HStack {
                        Text(L("\(filtered.count) 件表示 / \(commits.count) 件読み込み済み")).font(.caption).foregroundStyle(.secondary)
                        if !query.isEmpty { Text(L("読み込み済みの履歴から検索")).font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        if loading { ProgressView().controlSize(.small) }
                        Button(L("さらに 200 件読み込む")) { limit += 200 }.disabled(loading || commits.count < limit)
                    }.padding(8)
                }.frame(minHeight: 160, idealHeight: 240, maxHeight: 380)
                if let commit = current {
                    CommitInspector(repo: repo, commit: commit, model: model).id(commit.id).frame(minHeight: 330, maxHeight: .infinity)
                } else { BrowserPlaceholder(title: L("コミットを選択"), detail: L("コミットの説明と変更ファイル一覧を表示します。"), symbol: "clock.arrow.circlepath").frame(minHeight: 250) }
            }
        }
        .task(id: [repo.path, reference, String(limit), refreshID.uuidString, file ?? ""]) {
            loading = true; error = nil
            if loadedReference != reference { commits = []; selection = nil; loadedReference = reference }
            let repository = repo, ref = reference.isEmpty ? nil : reference, count = limit, selectedFile = file
            do {
                let records = try await Task.detached(priority: .userInitiated) { try repository.history(reference: ref, limit: count, file: selectedFile) }.value
                guard !Task.isCancelled else { return }
                commits = records
                if !records.contains(where: { $0.id == selection }) { selection = records.first?.id }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
    }
}

@MainActor
struct CommitInspector: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let repo: GitRepository
    let commit: CommitRecord
    var model: Workspace? = nil
    @State private var parent: String?
    private var base: String? { parent ?? commit.parents.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommitDetailsView(commit: commit).frame(minHeight: 150, idealHeight: 220, maxHeight: 280)
            HStack {
                if commit.parents.count > 1 {
                    Picker(L("比較する親"), selection: Binding(get: { base ?? "" }, set: { parent = $0 })) {
                        ForEach(Array(commit.parents.enumerated()), id: \.element) { index, hash in Text(L("親 \(index + 1) · \(hash)")).tag(hash) }
                    }.frame(maxWidth: 330)
                } else { Text(base.map { L("親コミット \($0)  →  \(commit.id)") } ?? L("最初のコミット · 作成前と比較")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Spacer()
                if !commit.decorations.isEmpty { Label(commit.decorations, systemImage: "tag").font(.caption).foregroundStyle(.cyan).lineLimit(1) }
            }.padding(.horizontal, 10)
            if let model {
                HStack {
                    Button(L("この変更を取り込む（Cherry-pick）")) { run(.cherryPick, model: model) }
                    Button(L("このコミットを取り消す（Revert）")) { run(.revert, model: model) }
                    Text(L("現在: ") + model.branch).font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 10).disabled(model.busy || model.sequence != nil || !model.changes.isEmpty || commit.parents.count > 1)
                if commit.parents.count > 1 { Text(L("マージコミットの履歴操作には親の指定が必要なため、この画面からは実行できません。")).font(.caption).foregroundStyle(.secondary) }
            }
            RevisionFilesView(repo: repo, base: base, target: commit.id)
        }.accessibilityIdentifier("commitInspector")
    }
    private func run(_ tool: RepositoryTool, model: Workspace) {
        let alert = NSAlert(); alert.messageText = tool.title
        alert.informativeText = L("\(tool.confirmation ?? "")\n対象: \(commit.shortID) · \(commit.subject)\n実行先: \(model.branch)\nリポジトリ: \(repo.path)")
        alert.addButton(withTitle: L("実行")); alert.addButton(withTitle: L("キャンセル"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let id = commit.id
        model.operation(success: tool == .revert ? L("Revert が完了しました。履歴を残したまま変更を取り消しました。") : L("Cherry-pick が完了しました。")) {
            if tool == .revert { try $0.revert(id) } else { try $0.cherryPick(id) }
        }
    }

}

@MainActor
struct RevisionFilesView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let repo: GitRepository
    let base: String?
    let target: String
    var refreshKey = ""
    @State private var files: [Change] = []
    @State private var loading = false
    @State private var error: String?
    @State private var resolvedBase: String?
    @State private var resolvedTarget: String?
    var body: some View {
        ChangedFilesView(repo: repo, files: files, base: resolvedBase, target: resolvedTarget, checked: .constant([]))
            .disabled(loading || error != nil)
            .overlay {
                if loading { ProgressView(L("変更ファイルを読み込み中…")) }
                else if let error { BrowserPlaceholder(title: L("比較を読み込めませんでした"), detail: error, symbol: "exclamationmark.triangle").background(Color(nsColor: .windowBackgroundColor)) }
            }
        .task(id: [repo.path, base ?? "", target, refreshKey]) {
            loading = true; error = nil
            let repository = repo, from = base, to = target
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let baseID = try from.map { try repository.revision($0) }, targetID = try repository.revision(to)
                    return (try repository.revisionChanges(from: baseID, to: targetID), baseID, targetID)
                }.value
                guard !Task.isCancelled else { return }
                files = result.0; resolvedBase = result.1; resolvedTarget = result.2
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
    }
}
