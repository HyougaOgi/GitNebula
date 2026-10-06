import Foundation

/// Apple's signed SSH tools own the persistent secret. GitNebula never reads their
/// protected access group, so replacing an ad-hoc app cannot invalidate its access.
struct SSHSystemStore: SSHSecretStore {
    var legacy = SSHKeychain()

    func read(for key: String) throws -> String? {
        // Older versions owned their Keychain entries. Migration is allowed only
        // when the OS authorizes it without UI; never request the login password.
        try? legacy.read(for: key)
    }
    func contains(key: String) throws -> Bool {
        if try isStoredBySSH(key) { return true }
        return (try? legacy.contains(key: key)) == true
    }
    func needsMigration(for key: String) -> Bool {
        ((try? legacy.contains(key: key)) == true) && ((try? isStoredBySSH(key)) != true)
    }
    func save(_ passphrase: String, for key: String) throws {
        guard !passphrase.contains("\n"), !passphrase.contains("\r"), !passphrase.contains("\0") else {
            throw failure(L("パスフレーズに改行は使用できません。"))
        }
        try withAgent { agent in
            let validation = try agent.run(["-q", "--", key], input: passphrase)
            guard validation.status == 0 else { throw failure(L("鍵またはパスフレーズを確認してください。\n") + validation.message) }
            let result = try agent.run(["--apple-use-keychain", "-q", "--", key], input: passphrase)
            guard result.status == 0 else { throw failure(L("鍵またはパスフレーズを確認してください。\n") + result.message) }
        }
        // ssh-add can load an identity even if persistent storage failed. Check
        // with a fresh, empty agent so a cached key cannot hide that failure.
        guard try isStoredBySSH(key) else { throw failure(L("パスフレーズを保存できませんでした。SSH の設定を確認してください。")) }
    }
    func remove(for key: String) throws {
        try withAgent { agent in _ = try agent.run(["--apple-use-keychain", "-d", "-q", "--", key]) }
        guard try !isStoredBySSH(key) else { throw failure(L("保存したパスフレーズを削除できませんでした。")) }
        // Do not let a legacy value silently restore the deleted credential.
        try legacy.remove(for: key)
    }
    private func isStoredBySSH(_ key: String) throws -> Bool {
        guard FileManager.default.isReadableFile(atPath: key) else { return false }
        return try withAgent { agent in
            // An unencrypted key succeeds without any secret; don't call it saved.
            if try agent.run(["-q", "--", key]).status == 0 { return false }
            return try agent.run(["--apple-use-keychain", "-q", "--", key]).status == 0
        }
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "GitNebula.SSH", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func withAgent<T>(_ body: (IsolatedSSHAgent) throws -> T) throws -> T {
        let agent = try IsolatedSSHAgent()
        defer { agent.close() }
        return try body(agent)
    }
}

/// Saving/probing must not modify the user's agent or mistake its cached keys for
/// persistent credentials. The socket is private and the agent dies on every exit.
private final class IsolatedSSHAgent {
    let directory: URL
    let process = Process()
    init() throws {
        // Darwin's UNIX socket path limit is shorter than many per-user tmp paths.
        directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("GitNebula-agent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
            process.arguments = ["-D", "-a", directory.appendingPathComponent("socket").path]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("socket").path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            guard process.isRunning, FileManager.default.fileExists(atPath: directory.appendingPathComponent("socket").path) else {
                throw NSError(domain: "GitNebula.SSH", code: 2, userInfo: [NSLocalizedDescriptionKey: L("SSH の認証処理を起動できませんでした。")])
            }
        } catch { close(); throw error }
    }
    func run(_ arguments: [String], input: String? = nil) throws -> (status: Int32, message: String) {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add"); child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_AUTH_SOCK"] = directory.appendingPathComponent("socket").path
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        // The supplied value goes only through stdin, never argv, env or a file.
        environment["SSH_ASKPASS_REQUIRE"] = input == nil ? "force" : "never"
        environment["DISPLAY"] = "gitnebula"; environment["LC_ALL"] = "C"
        child.environment = environment
        let pipe = Pipe(), error = Pipe()
        child.standardInput = input == nil ? FileHandle.nullDevice : pipe.fileHandleForReading
        child.standardOutput = FileHandle.nullDevice; child.standardError = error
        try child.run()
        if let input { pipe.fileHandleForWriting.write(Data((input + "\n").utf8)) }
        try pipe.fileHandleForWriting.close()
        let diagnostics = error.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        return (child.terminationStatus, String(decoding: diagnostics, as: UTF8.self))
    }
    func close() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }
}
