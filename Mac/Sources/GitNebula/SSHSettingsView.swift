import SwiftUI
import AppKit

@MainActor final class SSHSettings: ObservableObject {
    static let savedMask = "••••••••"
    @Published var keyPath: String
    @Published var passphrase = "" { didSet { if !loadingPassphrase { passphraseEdited = true } } }
    @Published private(set) var hasSavedPassphrase = false
    @Published var message = ""
    @Published var failed = false
    private let defaults: UserDefaults
    private let store: any SSHSecretStore
    private var loadingPassphrase = false
    private var passphraseEdited = false
    init(defaults: UserDefaults = .standard, store: any SSHSecretStore = SSHKeychain()) {
        self.defaults = defaults; self.store = store; keyPath = defaults.string(forKey: "sshKeyPath") ?? ""
        refreshSavedPassphrase()
    }
    func refreshSavedPassphrase() {
        loadingPassphrase = true
        // Opening settings must not read a protected secret or request authentication.
        hasSavedPassphrase = !keyPath.isEmpty && ((try? store.contains(key: (try? LaunchRequest.inputPath(keyPath)) ?? keyPath)) == true)
        passphrase = hasSavedPassphrase ? Self.savedMask : ""
        passphraseEdited = false; loadingPassphrase = false
    }
    var showsSavedPassphrase: Bool { hasSavedPassphrase && !passphraseEdited }
    func save() {
        do {
            let key = keyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : try LaunchRequest.inputPath(keyPath)
            if !key.isEmpty {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: key, isDirectory: &isDirectory), !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: key), !key.lowercased().hasSuffix(".pub") else {
                    throw NSError(domain: "GitNebula", code: 1, userInfo: [NSLocalizedDescriptionKey: L("読み込み可能な秘密鍵を選択してください。公開鍵（.pub）は使用できません。")])
                }
                if passphraseEdited && !passphrase.isEmpty { try store.save(passphrase, for: key) }
            } else if passphraseEdited && !passphrase.isEmpty {
                throw NSError(domain: "GitNebula", code: 1, userInfo: [NSLocalizedDescriptionKey: L("パスフレーズを保存する秘密鍵を選択してください。")])
            }
            defaults.set(key, forKey: "sshKeyPath"); keyPath = key; refreshSavedPassphrase(); failed = false
            message = L("SSH 設定を保存しました。Clone・Fetch・Pull・Push で使用します。")
        } catch { failed = true; message = error.localizedDescription }
    }
    func forgetPassphrase() {
        do {
            try store.remove(for: LaunchRequest.inputPath(keyPath)); refreshSavedPassphrase(); failed = false
            message = L("保存したパスフレーズを削除しました。")
        } catch { failed = true; message = error.localizedDescription }
    }
    func chooseKey() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.showsHiddenFiles = true
        panel.title = L("SSH 秘密鍵を選択")
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { keyPath = url.path }
    }
}

struct SSHSettingsView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @StateObject private var settings = SSHSettings()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("SSH 認証")).font(.headline)
            Text(L("秘密鍵（空欄なら既存の SSH 設定を使用）"))
            HStack {
                TextField("~/.ssh/id_ed25519", text: $settings.keyPath).textFieldStyle(.roundedBorder).accessibilityIdentifier("sshKeyPath")
                Button(L("選択…"), action: settings.chooseKey)
            }
            Text(L("鍵のパスフレーズ"))
            NativeSecureField(text: $settings.passphrase, showsSavedValue: settings.showsSavedPassphrase, placeholder: L("パスフレーズ"))
                .frame(height: 28)
                .onChange(of: settings.keyPath) { _ in settings.refreshSavedPassphrase() }
            if settings.hasSavedPassphrase { Label(L("設定済み"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary) }
            Text(L("パスフレーズはキーチェーンに保存し、接続時に自動で使用します。")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("SSH 設定を保存"), action: settings.save).accessibilityIdentifier("saveSSHSettings")
                Button(L("保存したパスフレーズを削除"), action: settings.forgetPassphrase).disabled(settings.keyPath.isEmpty)
            }
            if !settings.message.isEmpty { Text(settings.message).foregroundStyle(settings.failed ? .orange : .secondary).textSelection(.enabled) }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("sshSettings")
    }
}
