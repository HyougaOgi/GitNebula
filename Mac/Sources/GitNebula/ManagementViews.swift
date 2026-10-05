import SwiftUI

struct FunctionLauncher: View {
    let management: Bool
    @Environment(\.screenActions) private var navigation
    private var groups: [(String, [RepositoryTool])] {
        [
            ("履歴・ファイルの確認", [.show, .compare, .fileLog, .blame, .reflog]),
            ("履歴への操作", [.cherryPick, .revert, .rebase, .resetSoft, .resetMixed, .resetHard]),
            ("パッチ", [.exportPatch, .checkPatch, .applyPatch]),
            ("Worktree", [.listWorktrees, .addWorktree]),
            ("Submodule", [.listSubmodules, .addSubmodule, .updateSubmodules])
        ]
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if management {
                    ForEach([UtilityPage.files, .branches, .conflicts, .identity], id: \.title) { page in
                        Button { navigation.openUtility(page) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(page.title).font(.headline)
                                Text(page.hint).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }.buttonStyle(.bordered)
                    }
                    Button("リモートを設定") { navigation.openAction(.remotes) }
                } else {
                    ForEach(groups, id: \.0) { title, tools in
                        Text(title).font(.headline)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(tools, id: \.self) { tool in
                                Button { navigation.openUtility(.tool(tool)) } label: {
                                    Text(tool.title).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }.accessibilityIdentifier("functionLauncher")
    }
}

struct IdentitySettingsView: View {
    @ObservedObject var model: Workspace
    @State private var name = ""
    @State private var email = ""
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("名前"); TextField("コミット作成者の名前", text: $name).textFieldStyle(.roundedBorder)
            Text("メールアドレス"); TextField("コミット作成者のメールアドレス", text: $email).textFieldStyle(.roundedBorder)
            Button("作成者を保存") {
                let name = name, email = email
                model.operation(success: "コミット作成者を保存しました。") { try $0.setIdentity(name: name, email: email) }
            }.buttonStyle(.borderedProminent).disabled(!loaded || name.isEmpty || email.isEmpty)
            Spacer()
        }.task {
            guard !loaded, let repo = model.repository else { return }
            do {
                let result = try await Task.detached { () -> (String, String) in
                    (try repo.configuration("user.name") ?? "", try repo.configuration("user.email") ?? "")
                }.value
                if !Task.isCancelled { name = result.0; email = result.1; loaded = true }
            } catch { if !Task.isCancelled { model.status = error.localizedDescription; model.failed = true } }

        }.accessibilityIdentifier("identitySettings")
    }
}
