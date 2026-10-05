import SwiftUI
import AppKit

enum RepositoryTool: String, CaseIterable {
    case show, compare, blame, fileLog, reflog, cherryPick, revert, rebase, resetSoft, resetMixed, resetHard
    case exportPatch, checkPatch, applyPatch, listWorktrees, addWorktree, listSubmodules, addSubmodule, updateSubmodules
    var title: String {
        switch self {
        case .show: return "コミットの内容"
        case .compare: return "2 つのコミットを比較"
        case .blame: return "行ごとの変更者（Blame）"
        case .fileLog: return "ファイルの履歴"
        case .reflog: return "参照の操作履歴（Reflog）"
        case .cherryPick: return "コミットを取り込む（Cherry-pick）"
        case .revert: return "打ち消しコミットを作る（Revert）"
        case .rebase: return "ブランチの起点を移す（Rebase）"
        case .resetSoft: return "Reset — 変更をステージに残す"
        case .resetMixed: return "Reset — 変更を作業ツリーに残す"
        case .resetHard: return "Reset — 対象コミットの内容に戻す"
        case .exportPatch: return "変更をパッチに保存"
        case .checkPatch: return "パッチの適用を確認"
        case .applyPatch: return "パッチを適用"
        case .listWorktrees: return "作業ツリーの一覧（Worktree）"
        case .addWorktree: return "別の作業ツリーを作成"
        case .listSubmodules: return "サブモジュールの一覧"
        case .addSubmodule: return "サブモジュールを追加"
        case .updateSubmodules: return "サブモジュールを取得・更新"
        }
    }
    var fields: [String] {
        switch self {
        case .show, .cherryPick, .revert, .rebase, .resetSoft, .resetMixed, .resetHard: return ["コミット / ブランチ / タグ"]
        case .compare: return ["比較元のコミット", "比較先のコミット"]
        case .blame: return ["リポジトリ内のファイルパス", "コミット / ブランチ / タグ"]
        case .fileLog: return ["リポジトリ内のファイルパス"]
        case .exportPatch: return ["パッチの保存先（絶対パス）"]
        case .checkPatch, .applyPatch: return ["パッチのファイル（絶対パス）"]
        case .addWorktree: return ["作成先のフォルダ（絶対パス）", "新しいブランチ名"]
        case .addSubmodule: return ["取得元 URL", "リポジトリ内の作成先"]
        default: return []
        }
    }
    var hint: String {
        switch self {
        case .resetSoft, .resetMixed, .resetHard: return "現在のブランチを指定したコミットに移します。先に作業中の変更をコミットまたは退避してください。"
        case .cherryPick, .revert, .rebase: return "作業ツリーがクリーンな場合に実行します。競合が起きたら解決して再開、または中止できます。"
        case .exportPatch: return "HEAD からの追跡済みファイルの差分を、バイナリ差分も含めて保存します。新規ファイルは先にステージしてください。"
        case .updateSubmodules: return "親リポジトリに記録されたコミットを取得します。サブモジュールのローカル変更は強制破棄しません。"
        default: return "下の欄で対象を指定してください。結果はこの画面に表示されます。"
        }
    }
    var confirmation: String? {
        switch self {
        case .resetHard: return "現在のブランチと追跡ファイルを対象コミットに戻します。ブランチから外れるコミットを確認してください。"
        case .resetSoft, .resetMixed: return "現在のブランチを対象コミットへ移します。ブランチの履歴が変わります。"
        case .rebase: return "現在のブランチのコミットを、新しい起点に付け替えます。コミット ID が変わります。"
        case .cherryPick: return "指定したコミットの変更を現在のブランチに取り込みます。"
        case .revert: return "指定したコミットを打ち消す新しいコミットを作成します。"
        case .applyPatch: return "パッチを現在の作業ツリーに適用します。"
        default: return nil
        }
    }
    func execute(_ repo: GitRepository, _ first: String, _ second: String) throws -> String {
        switch self {
        case .show: return try repo.showCommit(first)
        case .compare: return try repo.compare(first, second)
        case .blame: return try repo.blame(first, at: second)
        case .fileLog: return try repo.fileHistory(first)
        case .reflog: return try repo.reflog()
        case .cherryPick: try repo.cherryPick(first)
        case .revert: try repo.revert(first)
        case .rebase: try repo.rebase(onto: first)
        case .resetSoft: try repo.reset(first, mode: "soft")
        case .resetMixed: try repo.reset(first, mode: "mixed")
        case .resetHard: try repo.reset(first, mode: "hard")
        case .exportPatch: try repo.exportPatch(to: first)
        case .checkPatch: try repo.applyPatch(first, checkOnly: true); return "適用可能なパッチです。作業ファイルは変更していません。"
        case .applyPatch: try repo.applyPatch(first, checkOnly: false)
        case .listWorktrees: return try repo.worktrees()
        case .addWorktree: try repo.addWorktree(at: first, branch: second); return try repo.worktrees()
        case .listSubmodules: return try repo.submodules()
        case .addSubmodule: try repo.addSubmodule(source: first, destination: second); return try repo.submodules()
        case .updateSubmodules: try repo.updateSubmodules(); return try repo.submodules()
        }
        return "完了しました。"
    }
}

@MainActor
struct RepositoryToolsView: View {
    @ObservedObject var model: Workspace
    @Environment(\.screenActions) private var navigation
    let tool: RepositoryTool
    @State private var stashes: [StashEntry] = []
    @State private var stashID = ""
    @State private var stashMessage = ""
    @State private var includeUntracked = true
    @State private var tags: [String] = []
    @State private var tag = ""
    @State private var tagName = ""
    @State private var tagRevision = "HEAD"
    @State private var tagMessage = ""
    @State private var remoteName = "origin"
    @State private var remoteURL = ""
    @State private var first = "HEAD"
    @State private var second = "HEAD"
    @State private var output = ""
    @State private var previewTool: RepositoryTool?
    @State private var previewFirst = "HEAD"
    @State private var previewSecond = "HEAD"
    @State private var selectedRemote: String?

    init(model: Workspace, tool: RepositoryTool = .show) {
        self.model = model; self.tool = tool
        let firstDefault = [.show, .compare, .cherryPick, .revert, .rebase, .resetSoft, .resetMixed, .resetHard].contains(tool) ? "HEAD" : ""
        _first = State(initialValue: firstDefault)
        _second = State(initialValue: [.blame, .compare].contains(tool) ? "HEAD" : "")
        _previewTool = State(initialValue: [.reflog, .listWorktrees, .listSubmodules].contains(tool) ? tool : nil)
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let repo = model.repository {
                if model.action == .stash { stashForm }
                else if model.action == .tags { tagForm }
                else if model.action == .remotes {
                    remoteSettings
                } else {
                    toolsForm
                    Divider()
                    toolPreview(repo)
                }
            }
            if !output.isEmpty {
                ScrollView { Text(output).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 70)
            }
        }.frame(maxHeight: .infinity)
        .task(id: [model.repository?.path ?? "", model.revisionID.uuidString]) {
            guard let repo = model.repository else { return }
            if model.action == .remotes {
                if selectedRemote == nil || !model.remotes.contains(selectedRemote ?? "") { selectedRemote = model.remotes.first }
                return
            }
            guard [.stash, .tags].contains(model.action) else { return }
            do {
                let result = try await Task.detached { (try repo.stashes(), try repo.tags()) }.value
                guard !Task.isCancelled else { return }
                stashes = result.0; tags = result.1
                if !stashes.contains(where: { $0.id == stashID }) { stashID = stashes.first?.id ?? "" }
                if !tags.contains(tag) { tag = tags.first ?? "" }
            } catch { if !Task.isCancelled { model.status = error.localizedDescription; model.failed = true } }
        }
    }
    @ViewBuilder private func toolPreview(_ repo: GitRepository) -> some View {
        if let previewTool {
            switch previewTool {
            case .show: CommitReferenceView(repo: repo, reference: previewFirst, refreshKey: model.revisionID.uuidString)
            case .compare: RevisionFilesView(repo: repo, base: previewFirst, target: previewSecond, refreshKey: model.revisionID.uuidString)
            case .fileLog: HistoryBrowserView(repo: repo, branches: model.branches, refreshID: model.revisionID, file: previewFirst)
            case .blame: RepositoryRecordsView(repo: repo, kind: .blame, first: previewFirst, second: previewSecond, refreshKey: model.revisionID.uuidString)
            case .reflog: RepositoryRecordsView(repo: repo, kind: .reflog, refreshKey: model.revisionID.uuidString)
            case .listWorktrees, .addWorktree: RepositoryRecordsView(repo: repo, kind: .worktrees, refreshKey: model.revisionID.uuidString)
            case .listSubmodules, .addSubmodule, .updateSubmodules: RepositoryRecordsView(repo: repo, kind: .submodules, refreshKey: model.revisionID.uuidString)
            default: BrowserPlaceholder(title: "対象と操作結果を確認", detail: "上のフォームで対象を指定して実行します。", symbol: "wrench.and.screwdriver")
            }
        } else { BrowserPlaceholder(title: "対象を指定してください", detail: "上の入力欄で対象を指定し、実行ボタンを押してください。", symbol: "wrench.and.screwdriver") }
    }
    private var remoteSettings: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Text("登録済みリモート").font(.headline)
                List(model.remotes, id: \.self, selection: $selectedRemote) { name in Label(name, systemImage: "network").tag(name) }
                    .frame(minHeight: 160).accessibilityIdentifier("remoteList")
                Button("新しいリモート") { selectedRemote = nil; remoteName = ""; remoteURL = "" }
            }.frame(minWidth: 160, idealWidth: 190, maxWidth: 240)
            ScrollView { remoteForm.padding(.leading, 12) }.frame(minWidth: 400)
        }
        .task(id: selectedRemote) {
            guard let repo = model.repository, let name = selectedRemote else { return }
            do {
                let url = try await Task.detached { try repo.run(["remote", "get-url", name]).trimmingCharacters(in: .newlines) }.value
                if !Task.isCancelled { remoteName = name; remoteURL = url }
            } catch { if !Task.isCancelled { model.status = error.localizedDescription; model.failed = true } }
        }
    }
    private func field(_ title: String, _ value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: value).textFieldStyle(.roundedBorder)
        }
    }
    private func confirm(_ message: String, run: () -> Void) {
        let alert = NSAlert(); alert.messageText = message; alert.alertStyle = .warning
        alert.informativeText = "リポジトリ: \(model.repository?.path ?? "")\nブランチ: \(model.branch)"
        alert.addButton(withTitle: "実行"); alert.addButton(withTitle: "キャンセル")
        if alert.runModal() == .alertFirstButtonReturn { run() }
    }
    private func execute(_ work: @escaping @Sendable (GitRepository) throws -> String) {
        guard let repo = model.repository else { return }
        model.perform({
            let result = try work(repo)
            return (try Snapshot(repo), result)
        }, success: "完了しました。", notifiesChanges: true) { snapshot, result in
            model.apply(snapshot); output = result
        }
    }
    private func refresh() { model.refresh() }
    private var stashForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("退避メモ", $stashMessage)
            Toggle("未追跡ファイルも退避する（無視ファイルは含めない）", isOn: $includeUntracked)
            Button("現在の変更を退避") {
                let message = stashMessage, include = includeUntracked
                execute { try $0.saveStash(message, includeUntracked: include); return "変更を退避しました。" }
            }.disabled(model.changes.isEmpty || model.sequence != nil).buttonStyle(.borderedProminent)
            Divider()
            if stashes.isEmpty { Text("退避データはありません。") }
            else {
                List(selection: Binding(get: { Optional(stashID) }, set: { stashID = $0 ?? "" })) {
                    ForEach(stashes) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.reference).font(.system(.caption, design: .monospaced)).foregroundStyle(.purple)
                            Text(entry.title).lineLimit(3)
                        }.padding(.vertical, 4).tag(entry.id)
                    }
                }.frame(minHeight: 200, maxHeight: .infinity).accessibilityIdentifier("stashList")
                Text(stashes.first { $0.id == stashID }?.title ?? "").font(.callout).textSelection(.enabled)
                HStack {
                    Button("変更ファイル一覧") {
                        if let repo = model.repository { navigation.openRevision(repo, stashID, true) }
                    }.accessibilityIdentifier("openStashFiles")
                    Button("適用（退避を残す）") { let id = stashID; execute { try $0.applyStash(id); return "適用しました。退避データは残っています。" } }
                    Button("取り出す（Pop）") { let id = stashID; execute { try $0.applyStash(id, pop: true); return "退避を取り出しました。" } }
                    Button("削除") { let id = stashID; confirm("選択した退避データを削除します。") { execute { try $0.dropStash(id); return "削除しました。" } } }
                }.disabled(stashID.isEmpty)
            }
            Button("一覧を更新", action: refresh)
        }
    }
    private var tagForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { field("タグ名", $tagName); field("対象コミット", $tagRevision) }
            field("注釈（空欄なら軽量タグ）", $tagMessage)
            Button("タグを作成") {
                let name = tagName, revision = tagRevision, message = tagMessage
                execute { try $0.createTag(name, at: revision, message: message); return "タグを作成しました。" }
            }.disabled(tagName.isEmpty || tagRevision.isEmpty).buttonStyle(.borderedProminent)
            Divider()
            if tags.isEmpty { Text("タグはありません。") }
            else {
                List(tags, id: \.self, selection: Binding(get: { Optional(tag) }, set: { tag = $0 ?? "" })) { name in Label(name, systemImage: "tag").tag(name) }.frame(minHeight: 200, maxHeight: .infinity).accessibilityIdentifier("tagList")
                HStack {
                    Button("変更ファイル一覧") {
                        if let repo = model.repository { navigation.openRevision(repo, "refs/tags/" + tag, false) }
                    }.disabled(tag.isEmpty).accessibilityIdentifier("openTagFiles")
                    Button("ローカルから削除") { let name = tag; confirm("ローカルのタグ「\(name)」を削除します。") { execute { try $0.deleteTag(name); return "削除しました。" } } }
                }
                if !model.remotes.isEmpty {
                    Picker("送信先", selection: $model.chosenRemote) { ForEach(model.remotes, id: \.self) { Text($0).tag($0) } }
                    Button("このタグを Push") {
                        let name = tag, remote = model.chosenRemote
                        confirm("タグ「\(name)」を \(remote) に送信します。") { execute { try $0.pushTag(name, to: remote); return "タグを送信しました。" } }
                    }
                }
            }
            Button("一覧を更新", action: refresh)
        }
    }
    private var remoteForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("リモート名", $remoteName); field("URL / ローカルのリポジトリパス", $remoteURL)
            HStack {
                Button("登録 / URL を変更") {
                    let name = remoteName, url = remoteURL
                    execute { try $0.setRemote(name, url: url); return "リモート設定を保存しました。" }
                }.disabled(remoteName.isEmpty || remoteURL.isEmpty).buttonStyle(.borderedProminent)
                Button("登録を削除") {
                    let name = remoteName
                    confirm("リモート「\(name)」の登録と追跡参照を削除します。サーバー上のリポジトリは残ります。") { execute { try $0.removeRemote(name); return "リモート登録を削除しました。" } }
                }.disabled(!model.remotes.contains(remoteName))
                Button("一覧を更新", action: refresh)
            }

        }
    }
    private var toolsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = tool.fields.first { field(title, $first) }
            if tool.fields.count > 1 { field(tool.fields[1], $second) }
            Button(tool.title) {
                let selectedTool = tool, a = first, b = second
                if [.show, .compare, .fileLog, .blame, .reflog, .listWorktrees, .listSubmodules].contains(selectedTool) {
                    output = ""; previewFirst = a; previewSecond = b; previewTool = selectedTool
                    model.refresh()
                    return
                }
                let run = {
                    previewFirst = a; previewSecond = b; previewTool = selectedTool
                    execute { repo in
                        let result = try selectedTool.execute(repo, a, b)
                        return [.addWorktree, .addSubmodule, .updateSubmodules].contains(selectedTool) ? "完了しました。" : result
                    }
                }
                if let message = selectedTool.confirmation { confirm(message + "\n対象: " + a, run: run) } else { run() }
            }.buttonStyle(.borderedProminent).disabled(!tool.fields.isEmpty && first.isEmpty || tool.fields.count > 1 && second.isEmpty)
        }
    }
}
