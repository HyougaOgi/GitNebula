import SwiftUI

struct RepositoryActionLauncher: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @Environment(\.screenActions) private var navigation
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(GitAction.menuGroups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title).font(.headline)
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(group.actions, id: \.self) { action in
                                Button { navigation.openAction(action) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: action.symbol).frame(width: 20)
                                        Text(action.title).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                }.buttonStyle(.bordered).help(action.hint)
                                    .accessibilityIdentifier("repositoryAction:" + action.rawValue)
                            }
                        }
                    }
                }
            }.padding(.vertical, 4)
        }.accessibilityIdentifier("repositoryActions")
    }
}

struct FunctionLauncher: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let management: Bool
    @Environment(\.screenActions) private var navigation
    private var groups: [(String, [RepositoryTool])] {
        [
            (L("履歴・ファイルの確認"), [.show, .compare, .fileLog, .blame, .reflog]),
            (L("履歴への操作"), [.cherryPick, .revert, .rebase, .resetSoft, .resetMixed, .resetHard]),
            (L("パッチ"), [.exportPatch, .checkPatch, .applyPatch]),
            ("Worktree", [.listWorktrees, .addWorktree]),
            ("Submodule", [.listSubmodules, .addSubmodule, .updateSubmodules])
        ]
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if management {
                    ForEach([UtilityPage.files, .branches, .conflicts], id: \.title) { page in
                        Button { navigation.openUtility(page) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(page.title).font(.headline)
                                Text(page.hint).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }.buttonStyle(.bordered)
                    }
                    Button(L("リモートを設定")) { navigation.openAction(.remotes) }
                    Button(UtilityPage.identity.title) { navigation.openUtility(.identity) }
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
    @ObservedObject private var appearance = AppearanceSettings.shared
    @ObservedObject var model: Workspace
    @State private var name = ""
    @State private var email = ""
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("名前")); TextField(L("コミット作成者の名前"), text: $name).textFieldStyle(.roundedBorder)
            Text(L("メールアドレス")); TextField(L("コミット作成者のメールアドレス"), text: $email).textFieldStyle(.roundedBorder)
            Button(L("作成者を保存")) {
                let name = name, email = email
                model.operation(success: L("コミット作成者を保存しました。")) { try $0.setIdentity(name: name, email: email) }
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
