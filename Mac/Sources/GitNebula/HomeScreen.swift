import SwiftUI
import AppKit

struct HomeScreen: View {
    @ObservedObject var model: Workspace
    @Environment(\.screenActions) private var navigation
    private var recent: [String] { UserDefaults.standard.stringArray(forKey: "recentRepositories") ?? [] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("GitNebula へようこそ").font(.largeTitle.bold()).accessibilityIdentifier("welcomeTitle")
                    Spacer()
                    Button("アプリの設定") { navigation.openUtility(.settings) }
                }
                Text("Finder でフォルダを右クリックして Git 操作を選ぶか、この画面でリポジトリを選択してください。")
                    .font(.title3).foregroundStyle(.secondary)
                if navigation.canResume { Button("前の作業画面に戻る", action: navigation.resume) }
                if model.repository == nil {
                    Text("上のパス欄か「参照…」から作業フォルダを開いてください。").foregroundStyle(.secondary)
                } else {
                    Text("変更 \(model.changes.count) ファイル · 現在のブランチ: \(model.branch)").foregroundStyle(.secondary)
                    Menu("このリポジトリで操作する") {
                        ForEach(GitAction.allCases.filter { ![.open, .clone, .initialize].contains($0) }, id: \.self) { action in
                            Button(action.title) { navigation.openAction(action) }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                HStack {
                    Button("リポジトリを選択…", action: model.chooseRepository).buttonStyle(.borderedProminent)
                    Button("リポジトリを複製（Clone）") { navigation.openAction(.clone) }
                    Button("リポジトリを作成（Init）") { navigation.openAction(.initialize) }
                }
                if !recent.isEmpty {
                    Text("最近開いたリポジトリ").font(.headline)
                    ForEach(recent, id: \.self) { path in
                        Button { model.repositoryPath = path; model.openEnteredPath() } label: {
                            Label(path, systemImage: "clock").lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("GitNebula を終了") { ApplicationDelegate.shared?.quit(nil) }
                }
            }
        }.accessibilityIdentifier("homeScreen")
    }
    static func remember(_ path: String) {
        var paths = UserDefaults.standard.stringArray(forKey: "recentRepositories") ?? []
        paths.removeAll { $0 == path }; paths.insert(path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(10)), forKey: "recentRepositories")
    }
}

struct AppSettingsView: View {
    @AppStorage("keepRunning") private var keepRunning = true
    @AppStorage("gitExecutable") private var gitExecutable = ""
    @ObservedObject private var startupOptions = StartupOptions.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("ウィンドウを閉じてもメニューバーに常駐する", isOn: $keepRunning)
            Text("通常起動はメニューバーに常駐し、Dock とウィンドウは表示しません。必要な画面はメニューから開けます。").foregroundStyle(.secondary)
            Toggle("起動時にようこそ画面を開く", isOn: $startupOptions.showWelcomeOnLaunch)
            Toggle("ログイン時に自動起動", isOn: Binding(get: { startupOptions.launchAtLogin }, set: { startupOptions.setLaunchAtLogin($0) }))
            if let message = startupOptions.message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
            Button("ログイン項目の設定を開く…", action: startupOptions.openLoginSettings)
            Text("Git の実行ファイル（空欄なら自動検出）").font(.headline)
            TextField("/usr/bin/git", text: $gitExecutable).textFieldStyle(.roundedBorder)
            Text("使用する Git: \(GitProcess.executable)").font(.caption).textSelection(.enabled)
            Text("認証は Git の credential helper または SSH agent を使用します。Git の操作結果とエラーは各操作画面に表示します。").foregroundStyle(.secondary)
            FinderIntegrationView()
            Spacer()
        }.accessibilityIdentifier("appSettings").onAppear { startupOptions.refresh() }
    }
}
