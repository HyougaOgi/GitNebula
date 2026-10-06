import Foundation
import Security

protocol SSHSecretStore {
    func read(for key: String) throws -> String?
    func save(_ passphrase: String, for key: String) throws
    func remove(for key: String) throws
    func contains(key: String) throws -> Bool
}

struct SSHKeychain: SSHSecretStore {
    static let service = "dev.gitnebula.desktop.ssh"
    var service = Self.service
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: "GitNebula", code: Int(status), userInfo: [NSLocalizedDescriptionKey: L("SSH パスフレーズのキーチェーン操作に失敗しました（\(status)）。")])
        }
    }
    func read(for key: String) throws -> String? {
        var query = query(key); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw NSError(domain: "GitNebula", code: 1) }
        return value
    }
    func contains(key: String) throws -> Bool {
        var query = query(key); query[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        try check(status); return true
    }
    func save(_ passphrase: String, for key: String) throws {
        let data = Data(passphrase.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = query(key); query[kSecValueData as String] = data
            query[kSecAttrLabel as String] = "GitNebula SSH: " + URL(fileURLWithPath: key).lastPathComponent
            try check(SecItemAdd(query as CFDictionary, nil))
        } else { try check(status) }
    }
    func remove(for key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}

struct SSHConfiguration: Sendable {
    let keyPath: String
    var helperPath = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    var sshExecutable = "/usr/bin/ssh"
    var keychainService = SSHKeychain.service
    static var current: SSHConfiguration { SSHConfiguration(keyPath: UserDefaults.standard.string(forKey: "sshKeyPath") ?? "") }

    func configure(_ environment: inout [String: String], directory: URL) throws -> [String] {
        guard !keyPath.isEmpty else { return [] }
        let wrapper = directory.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        exec "$GITNEBULA_SSH_EXECUTABLE" -i "$GITNEBULA_SSH_KEY" -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o NumberOfPasswordPrompts=1 "$@"

        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        environment.removeValue(forKey: "GIT_SSH_COMMAND")
        environment["GIT_SSH"] = wrapper.path
        environment["GIT_SSH_VARIANT"] = "ssh"
        environment["GITNEBULA_SSH_KEY"] = keyPath
        environment["GITNEBULA_SSH_EXECUTABLE"] = sshExecutable
        environment["GITNEBULA_SSH_SECRET_SERVICE"] = keychainService
        environment["SSH_ASKPASS"] = helperPath
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = environment["DISPLAY"] ?? "gitnebula"
        environment["LC_ALL"] = "C"
        // Only the executable path is shell-quoted; key paths and secrets never
        // become command text. Override repository SSH commands when a key is selected.
        return ["-c", "core.sshCommand='" + wrapper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"]
    }

    static func isKeyPassphrasePrompt(_ prompt: String, keyPath: String) -> Bool {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["Enter passphrase for key '\(keyPath)':", "Enter passphrase for '\(keyPath)':", "Enter passphrase for \(keyPath):"].contains(prompt)
    }
}
