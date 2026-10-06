import SwiftUI
import AppKit

struct HomeScreen: View {
    @ObservedObject var model: Workspace
    @Environment(\.screenActions) private var navigation
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("GitNebula").font(.system(size: 20, weight: .semibold)).accessibilityIdentifier("appHomeTitle")
            Button("詳細設定") { navigation.openUtility(.settings) }.font(.system(size: 14)).controlSize(.regular).buttonStyle(.borderedProminent).accessibilityIdentifier("openAppSettings")
            Spacer()
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .contain).accessibilityIdentifier("homeScreen")
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
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Toggle("ウィンドウを閉じてもメニューバーに常駐する", isOn: $keepRunning)
            Text("通常起動はメニューバーに常駐し、Dock とウィンドウは表示しません。必要な画面はメニューから開けます。").foregroundStyle(.secondary)
            Toggle("起動時にアプリ画面を開く", isOn: $startupOptions.showWelcomeOnLaunch)
            Toggle("ログイン時に自動起動", isOn: Binding(get: { startupOptions.launchAtLogin }, set: { startupOptions.setLaunchAtLogin($0) }))
            if let message = startupOptions.message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
            Button("ログイン項目の設定を開く…", action: startupOptions.openLoginSettings)
            Text("Git の実行ファイル（空欄なら自動検出）").font(.headline)
            TextField("/usr/bin/git", text: $gitExecutable).textFieldStyle(.roundedBorder)
            Text("使用する Git: \(GitProcess.executable)").font(.caption).textSelection(.enabled)
            Divider()
            SSHSettingsView()
            Divider()
            Text("HTTPS の認証には Git の credential helper を使用します。").foregroundStyle(.secondary)
            FinderIntegrationView()
            Spacer()
        }}.accessibilityIdentifier("appSettings").onAppear { startupOptions.refresh() }
    }
}
