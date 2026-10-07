import Foundation

/// All Git commands use argument arrays and a noninteractive process environment.
/// Only executable discovery and process IO are platform specific.
struct GitProcess {
    struct Output: Sendable { let data: Data; let diagnostics: String; let status: Int32 }
    static var executable: String {
        let configured = UserDefaults.standard.string(forKey: "gitExecutable") ?? ""
        if !configured.isEmpty { return configured }
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/bin/git"
    }
    static func run(in path: String, arguments: [String], accepting statuses: Set<Int32> = [0], ssh: SSHConfiguration = .current) throws -> Data {
        try runWithOutput(in: path, arguments: arguments, accepting: statuses, ssh: ssh).data
    }
    static func runWithOutput(in path: String, arguments: [String], accepting statuses: Set<Int32> = [0], ssh: SSHConfiguration = .current) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_EDITOR"] = "true"
        environment["GIT_SEQUENCE_EDITOR"] = "true"
        process.standardInput = FileHandle.nullDevice
        // Files avoid deadlocks and preserve binary output used for file comparisons.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sshArguments = try ssh.configure(&environment, directory: directory)
        process.arguments = ["--no-pager", "-c", "color.ui=false", "-c", "core.quotepath=false"] + sshArguments + ["-C", path] + arguments
        process.environment = environment
        let output = directory.appendingPathComponent("stdout"), error = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: error.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: output), stderr = try FileHandle(forWritingTo: error)
        defer { try? stdout.close(); try? stderr.close() }
        process.standardOutput = stdout; process.standardError = stderr
        do { try process.run() }
        catch { throw GitRepository(path: path).failure(L("Git を起動できません（\(executable)）。設定で Git の実行ファイルを確認してください。\n\(error.localizedDescription)")) }
        process.waitUntilExit()
        let data = try Data(contentsOf: output)
        let diagnostics = String(decoding: try Data(contentsOf: error), as: UTF8.self)
        guard statuses.contains(process.terminationStatus) else {
            let details = String(decoding: data, as: UTF8.self) + diagnostics
            let sshHint = details.contains("Permission denied (publickey)") || details.contains("Load key") || details.contains("Host key verification failed") ? L("\n詳細設定の「SSH 認証」で秘密鍵とパスフレーズを確認してください。") : ""
            throw GitRepository(path: path).failure(L("git \(arguments.first ?? "") が失敗しました（終了コード \(process.terminationStatus)）。\n\(details)\(sshHint)"))
        }
        return Output(data: data, diagnostics: diagnostics, status: process.terminationStatus)
    }
}
