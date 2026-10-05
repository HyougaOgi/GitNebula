import SwiftUI

struct RemoteOverview: Sendable {
    let url: String
    let tracking: String
    let ahead: Int?
    let behind: Int?
}
struct BranchRecord: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let commit: String
    let subject: String
    let upstream: String
}

extension GitRepository {
    func remoteOverview(_ name: String) throws -> RemoteOverview {
        let name = try remote(name)
        let url = try run(["remote", "get-url", name]).trimmingCharacters(in: .newlines)
        let branch = try remoteBranch(name).replacingOccurrences(of: "refs/heads/", with: "")
        let tracking = name + "/" + branch
        guard let head = try? revision("HEAD"), let remoteID = try? revision("refs/remotes/" + tracking) else {
            return RemoteOverview(url: url, tracking: tracking, ahead: nil, behind: nil)
        }
        let counts = try run(["rev-list", "--left-right", "--count", head + "..." + remoteID, "--"]).split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        return RemoteOverview(url: url, tracking: tracking, ahead: counts.first, behind: counts.count > 1 ? counts[1] : nil)
    }
    func branchRecords() throws -> [BranchRecord] {
        try run(["for-each-ref", "--sort=refname", "--format=%(refname:short)%00%(objectname:short)%00%(contents:subject)%00%(upstream:short)", "refs/heads"]).split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\0")
            guard fields.count == 4 else { return nil }
            return BranchRecord(name: fields[0], commit: fields[1], subject: fields[2], upstream: fields[3])
        }
    }
}

@MainActor
struct RemoteOperationView: View {
    @ObservedObject var model: Workspace
    @State private var overview: RemoteOverview?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.remotes.isEmpty {
                BrowserPlaceholder(title: "送受信先を登録してください", detail: "リモートの名前と URL を設定すると、送受信できるようになります。", symbol: "network")
            } else {
                Picker("リモート", selection: $model.chosenRemote) { ForEach(model.remotes, id: \.self) { Text($0).tag($0) } }
                if let overview {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("リモート URL", value: overview.url)
                        LabeledContent("現在のブランチ", value: model.branch)
                        LabeledContent("追跡先", value: overview.tracking)
                    }.textSelection(.enabled)
                    HStack(spacing: 16) {
                        countCard("送信待ち", count: overview.ahead, symbol: "arrow.up.circle", color: .purple)
                        countCard("未取り込み", count: overview.behind, symbol: "arrow.down.circle", color: .cyan)
                    }
                    Text("件数は取得済みの追跡情報を元に表示します。Fetch で最新の状態に更新できます。").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                HStack {
                    Spacer()
                    Button(model.action.title, action: model.runAction).buttonStyle(.borderedProminent).controlSize(.large).disabled(model.succeeded)
                }
            }
            Button("リモートを設定") { model.selectAction(.remotes) }
        }.padding(20).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .task(id: [model.repository?.path ?? "", model.chosenRemote, model.revisionID.uuidString]) {
            overview = nil; error = nil
            guard let repo = model.repository, !model.chosenRemote.isEmpty else { return }
            let remote = model.chosenRemote
            do {
                let result = try await Task.detached { try repo.remoteOverview(remote) }.value
                if !Task.isCancelled { overview = result }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func countCard(_ title: String, count: Int?, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).foregroundStyle(color)
            Text(count.map { "\($0) コミット" } ?? "未取得").font(.title2.bold())
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor
struct BranchSelectionView: View {
    @ObservedObject var model: Workspace
    @State private var branches: [BranchRecord] = []
    @State private var query = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("ブランチを検索", text: $query).textFieldStyle(.roundedBorder)
            Table(branches.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }, selection: Binding(get: { Optional(model.chosenBranch) }, set: { model.chosenBranch = $0 ?? "" })) {
                TableColumn("ブランチ") { branch in
                    HStack { Image(systemName: branch.name == model.branch ? "checkmark.circle.fill" : "arrow.triangle.branch"); Text(branch.name) }
                }.width(min: 150, ideal: 220)
                TableColumn("最新のコミット", value: \.subject)
                TableColumn("追跡先", value: \.upstream).width(min: 100, ideal: 140)
            }.frame(minHeight: 200).accessibilityIdentifier("branchTable")
            if !model.changes.isEmpty { Text("切り替える前に、作業中の変更をコミットまたは Stash してください。").foregroundStyle(.orange) }
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Text("現在: " + model.branch).foregroundStyle(.secondary)
                Spacer()
                Button("\(model.chosenBranch) に切り替え") { let name = model.chosenBranch; model.operation { try $0.switchBranch(name) } }
                    .buttonStyle(.borderedProminent).disabled(model.chosenBranch.isEmpty || model.chosenBranch == model.branch || !model.changes.isEmpty)
            }
        }
        .task(id: model.revisionID) {
            guard let repo = model.repository else { return }
            do { let result = try await Task.detached { try repo.branchRecords() }.value; if !Task.isCancelled { branches = result } }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

@MainActor
struct CommitReferenceView: View {
    let repo: GitRepository
    let reference: String
    @State private var commit: CommitRecord?
    @State private var error: String?
    var body: some View {
        Group {
            if let commit { CommitInspector(repo: repo, commit: commit) }
            else if let error { BrowserPlaceholder(title: "コミットを読み込めませんでした", detail: error) }
            else { ProgressView("コミットを読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: [repo.path, reference]) {
            commit = nil; error = nil
            do {
                let repository = repo, ref = reference
                let result = try await Task.detached { try repository.history(reference: ref, limit: 1).first }.value
                if !Task.isCancelled { commit = result }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

@MainActor
struct StashComparisonView: View {
    let repo: GitRepository
    let reference: String
    @State private var commit: CommitRecord?
    @State private var untracked = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 8) {
            if let commit {
                HStack {
                    Text(commit.subject).font(.headline)
                    Spacer()
                    if commit.parents.count > 2 {
                        Picker("対象", selection: $untracked) { Text("追跡ファイル").tag(false); Text("未追跡ファイル").tag(true) }.pickerStyle(.segmented).frame(width: 230)
                    }
                }.padding(10)
                RevisionDiffBrowser(repo: repo, base: untracked ? nil : commit.parents.first, target: untracked && commit.parents.count > 2 ? commit.parents[2] : commit.id)
            } else if let error { BrowserPlaceholder(title: "退避内容を読み込めませんでした", detail: error) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: reference) {
            commit = nil; error = nil
            do {
                let repository = repo, ref = reference
                let result = try await Task.detached { () -> (CommitRecord?, Bool) in
                    let commit = try repository.history(reference: ref, limit: 1).first
                    let empty = try commit.map { try repository.revisionChanges(from: $0.parents.first, to: $0.id).isEmpty } ?? true
                    return (commit, empty && (commit?.parents.count ?? 0) > 2)
                }.value
                if !Task.isCancelled { commit = result.0; untracked = result.1 }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
