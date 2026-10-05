import SwiftUI
import AppKit

@MainActor
struct HistoryBrowserView: View {
    let repo: GitRepository
    let branches: [String]
    let refreshID: UUID
    var file: String? = nil
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
                TextField("コミット ID・メッセージ・作成者を検索", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("historySearch")
                Picker("履歴", selection: $reference) {
                    Text("すべてのブランチ").tag("")
                    Text("現在の HEAD").tag("HEAD")
                    ForEach(branches, id: \.self) { Text($0).tag("refs/heads/" + $0) }
                }.frame(width: 250)
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            VSplitView {
                VStack(spacing: 0) {
                    Table(filtered, selection: Binding(get: { current?.id }, set: { selection = $0 })) {
                        TableColumn("コミット") { commit in
                            HStack(spacing: 8) {
                                Image(systemName: commit.parents.count > 1 ? "arrow.triangle.merge" : "circle.fill")
                                    .font(.system(size: commit.parents.count > 1 ? 12 : 6)).foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(commit.subject).lineLimit(1)
                                    if !commit.decorations.isEmpty { Text(commit.decorations).font(.caption2).foregroundStyle(.cyan).lineLimit(1) }
                                }
                            }.padding(.vertical, 3).help(commit.message)
                        }.width(min: 250, ideal: 460)
                        TableColumn("作成者", value: \.author).width(min: 100, ideal: 145, max: 210)
                        TableColumn("日時", value: \.displayDate).width(145)
                        TableColumn("ID") { Text($0.shortID).font(.system(.caption, design: .monospaced)) }.width(80)
                    }.accessibilityIdentifier("commitTable")
                    .overlay {
                        if loading && commits.isEmpty { ProgressView("履歴を読み込み中…") }
                        else if filtered.isEmpty { Text(commits.isEmpty ? "まだコミットはありません" : "一致するコミットはありません").foregroundStyle(.secondary) }
                    }
                    HStack {
                        Text("\(filtered.count) 件表示 / \(commits.count) 件読み込み済み").font(.caption).foregroundStyle(.secondary)
                        if !query.isEmpty { Text("読み込み済みの履歴から検索").font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        if loading { ProgressView().controlSize(.small) }
                        Button("さらに 200 件読み込む") { limit += 200 }.disabled(loading || commits.count < limit)
                    }.padding(8)
                }.frame(minHeight: 160, idealHeight: 240, maxHeight: 380)
                if let commit = current {
                    CommitInspector(repo: repo, commit: commit).id(commit.id).frame(minHeight: 330, maxHeight: .infinity)
                } else { BrowserPlaceholder(title: "コミットを選択", detail: "コミットの説明と変更ファイル一覧を表示します。", symbol: "clock.arrow.circlepath").frame(minHeight: 250) }
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
    let repo: GitRepository
    let commit: CommitRecord
    @State private var parent: String?
    private var base: String? { parent ?? commit.parents.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(commit.subject).font(.headline).textSelection(.enabled)
                    Text(commit.author + " <" + commit.email + ">  ·  " + commit.displayDate).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.id, forType: .string) } label: {
                    Label(commit.shortID, systemImage: "doc.on.doc").font(.system(.caption, design: .monospaced))
                }.help("コミット ID をコピー")
            }.padding(.horizontal, 10).padding(.top, 8)
            if commit.message != commit.subject {
                ScrollView { Text(commit.message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 60).padding(.horizontal, 10)
            }
            HStack {
                if commit.parents.count > 1 {
                    Picker("比較する親", selection: Binding(get: { base ?? "" }, set: { parent = $0 })) {
                        ForEach(Array(commit.parents.enumerated()), id: \.element) { index, hash in Text("親 \(index + 1) · \(hash.prefix(8))").tag(hash) }
                    }.frame(maxWidth: 330)
                } else { Text(base.map { "親コミット \($0.prefix(8))  →  \(commit.shortID)" } ?? "最初のコミット · 作成前と比較").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if !commit.decorations.isEmpty { Label(commit.decorations, systemImage: "tag").font(.caption).foregroundStyle(.cyan).lineLimit(1) }
            }.padding(.horizontal, 10)
            RevisionFilesView(repo: repo, base: base, target: commit.id)
        }.accessibilityIdentifier("commitInspector")
    }
}

@MainActor
struct RevisionFilesView: View {
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
                if loading { ProgressView("変更ファイルを読み込み中…") }
                else if let error { BrowserPlaceholder(title: "比較を読み込めませんでした", detail: error, symbol: "exclamationmark.triangle").background(Color(nsColor: .windowBackgroundColor)) }
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
