import SwiftUI
import AppKit

@MainActor final class SSHSettings: ObservableObject {
    @Published var keyPath: String
    @Published var passphrase = ""
    @Published var message = ""
    @Published var failed = false
    private let defaults: UserDefaults
    private let store: any SSHSecretStore
    init(defaults: UserDefaults = .standard, store: any SSHSecretStore = SSHKeychain()) {
        self.defaults = defaults; self.store = store; keyPath = defaults.string(forKey: "sshKeyPath") ?? ""
    }
    func save() {
        do {
            let key = keyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : try LaunchRequest.inputPath(keyPath)
            if !key.isEmpty {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: key, isDirectory: &isDirectory), !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: key), !key.lowercased().hasSuffix(".pub") else {
                    throw NSError(domain: "GitNebula", code: 1, userInfo: [NSLocalizedDescriptionKey: "読み込み可能な秘密鍵を選択してください。公開鍵（.pub）は使用できません。"])
                }
                if !passphrase.isEmpty { try store.save(passphrase, for: key) }
            } else if !passphrase.isEmpty {
                throw NSError(domain: "GitNebula", code: 1, userInfo: [NSLocalizedDescriptionKey: "パスフレーズを保存する秘密鍵を選択してください。"])
            }
            defaults.set(key, forKey: "sshKeyPath"); keyPath = key; passphrase = ""; failed = false
            message = "SSH 設定を保存しました。Clone・Fetch・Pull・Push で使用します。"
        } catch { failed = true; message = error.localizedDescription }
    }
    func forgetPassphrase() {
        do {
            try store.remove(for: LaunchRequest.inputPath(keyPath)); passphrase = ""; failed = false
            message = "保存したパスフレーズを削除しました。"
        } catch { failed = true; message = error.localizedDescription }
    }
    func chooseKey() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.showsHiddenFiles = true
        panel.title = "SSH 秘密鍵を選択"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { keyPath = url.path }
    }
}

struct SSHSettingsView: View {
    @StateObject private var settings = SSHSettings()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SSH 認証").font(.headline)
            Text("秘密鍵（空欄なら既存の SSH 設定を使用）")
            HStack {
                TextField("~/.ssh/id_ed25519", text: $settings.keyPath).textFieldStyle(.roundedBorder).accessibilityIdentifier("sshKeyPath")
                Button("選択…", action: settings.chooseKey)
            }
            Text("鍵のパスフレーズ")
            SecureField("空欄なら保存済みの値を使用", text: $settings.passphrase).textFieldStyle(.roundedBorder).accessibilityIdentifier("sshPassphrase")
            Text("パスフレーズはキーチェーンに保存し、接続時に自動で使用します。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("SSH 設定を保存", action: settings.save).accessibilityIdentifier("saveSSHSettings")
                Button("保存したパスフレーズを削除", action: settings.forgetPassphrase).disabled(settings.keyPath.isEmpty)
            }
            if !settings.message.isEmpty { Text(settings.message).foregroundStyle(settings.failed ? .orange : .secondary).textSelection(.enabled) }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("sshSettings")
    }
}
