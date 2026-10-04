import SwiftUI
import AppKit

private enum RepositoryTool: String, CaseIterable {
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
    @State private var userName = ""
    @State private var userEmail = ""
    @State private var tool = RepositoryTool.show
    @State private var first = "HEAD"
    @State private var second = "HEAD"
    @State private var output = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.action == .stash { stashForm }
                if model.action == .tags { tagForm }
                if model.action == .remotes { remoteForm }
                if model.action == .tools { toolsForm }
                if !output.isEmpty {
                    ScrollView(.horizontal) {
                        Text(output).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                    }.background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(2)
        }.frame(maxHeight: .infinity).onAppear { refresh() }
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
            return (try Snapshot(repo), try repo.stashes(), try repo.tags(), result)
        }, success: "完了しました。") { snapshot, stashes, tags, result in
            model.apply(snapshot); self.stashes = stashes; self.tags = tags; output = result
            if !stashes.contains(where: { $0.id == stashID }) { stashID = stashes.first?.id ?? "" }
            if !tags.contains(tag) { tag = tags.first ?? "" }
        }
    }
    private func refresh() {
        let action = model.action
        execute { repo in
            if action == .remotes { return try repo.remoteDetails() + "\nコミット作成者: " + repo.identity() }
            return ""
        }
    }
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
                Picker("退避データ", selection: $stashID) { ForEach(stashes) { Text("\($0.reference)  \($0.title)").tag($0.id) } }
                HStack {
                    Button("差分") { let id = stashID; execute { try $0.showStash(id) } }
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
                Picker("タグ", selection: $tag) { ForEach(tags, id: \.self) { Text($0).tag($0) } }
                HStack {
                    Button("内容を確認") { let name = tag; execute { try $0.showCommit("refs/tags/" + name) } }
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
                    execute { try $0.setRemote(name, url: url); return try $0.remoteDetails() }
                }.disabled(remoteName.isEmpty || remoteURL.isEmpty).buttonStyle(.borderedProminent)
                Button("登録を削除") {
                    let name = remoteName
                    confirm("リモート「\(name)」の登録と追跡参照を削除します。サーバー上のリポジトリは残ります。") { execute { try $0.removeRemote(name); return try $0.remoteDetails() } }
                }.disabled(!model.remotes.contains(remoteName))
                Button("一覧を更新", action: refresh)
            }
            Divider()
            Text("このリポジトリのコミット作成者").font(.headline)
            HStack { field("名前", $userName); field("メールアドレス", $userEmail) }
            Button("作成者を保存") {
                let name = userName, email = userEmail
                execute { try $0.setIdentity(name: name, email: email); return try $0.remoteDetails() + "\nコミット作成者: " + $0.identity() }
            }.disabled(userName.isEmpty || userEmail.isEmpty)
        }
    }
    private var toolsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("操作", selection: $tool) { ForEach(RepositoryTool.allCases, id: \.self) { Text($0.title).tag($0) } }
                .onChange(of: tool) { value in
                    output = ""; first = [.show, .cherryPick, .revert, .rebase, .resetSoft, .resetMixed, .resetHard].contains(value) ? "HEAD" : ""; second = value == .blame || value == .compare ? "HEAD" : ""
                }
            Text(tool.hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let title = tool.fields.first { field(title, $first) }
            if tool.fields.count > 1 { field(tool.fields[1], $second) }
            Button(tool.title) {
                let selectedTool = tool, a = first, b = second
                let run = { execute { try selectedTool.execute($0, a, b) } }
                if let message = selectedTool.confirmation { confirm(message + "\n対象: " + a, run: run) } else { run() }
            }.buttonStyle(.borderedProminent).disabled(!tool.fields.isEmpty && first.isEmpty || tool.fields.count > 1 && second.isEmpty)
        }
    }
}
