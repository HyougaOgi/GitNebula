import AppKit

enum SSHAskPass {
    @MainActor static func runIfRequested() -> Int32? {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["GITNEBULA_SSH_KEY"], CommandLine.arguments.count == 2 else { return nil }
        let prompt = CommandLine.arguments[1]
        do {
            if SSHConfiguration.isKeyPassphrasePrompt(prompt, keyPath: key) {
                let store = SSHSystemStore(legacy: SSHKeychain(service: environment["GITNEBULA_SSH_SECRET_SERVICE"] ?? SSHKeychain.service))
                let passphrase: String
                if let saved = try store.read(for: key) { passphrase = saved; try store.save(saved, for: key) }
                else {
                    NSApplication.shared.setActivationPolicy(.accessory)
                    let alert = NSAlert(); alert.messageText = L("SSH 鍵のパスフレーズ")
                    alert.informativeText = URL(fileURLWithPath: key).lastPathComponent + L(" のパスフレーズを入力してください。保存すると、次回から自動で使用します。")
                    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24)); alert.accessoryView = field
                    alert.addButton(withTitle: L("保存して接続")); alert.addButton(withTitle: L("キャンセル"))
                    NSApp.activate(ignoringOtherApps: true)
                    guard alert.runModal() == .alertFirstButtonReturn else { return 1 }
                    passphrase = field.stringValue
                    try store.save(passphrase, for: key)
                }
                FileHandle.standardOutput.write(Data((passphrase + "\n").utf8))
                return 0
            }
            if environment["SSH_ASKPASS_PROMPT"] == "confirm" || prompt.contains("Are you sure you want to continue connecting") {
                NSApplication.shared.setActivationPolicy(.accessory)
                let alert = NSAlert(); alert.messageText = L("SSH 接続先の確認"); alert.informativeText = prompt
                alert.addButton(withTitle: L("接続")); alert.addButton(withTitle: L("キャンセル"))
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return 1 }
                FileHandle.standardOutput.write(Data("yes\n".utf8)); return 0
            }
            // Never send a key's passphrase as a server password or host-key answer.
            return 1
        } catch { return 1 }
    }
}
