import XCTest
@testable import GitNebula

final class TransferProgressTests: LocalizedTestCase {
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(GitTransferProgress, Date)] = []
        func record(_ progress: GitTransferProgress) { lock.lock(); defer { lock.unlock() }; values.append((progress, Date())) }
        var snapshots: [(GitTransferProgress, Date)] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-progress-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testChunkedCarriageReturnsRemoteProgressAndUTF8() {
        var parser = GitProgressParser()
        let text = "remote: Counting objects: 25% (1/4)\rremote: Counting objects: 100% (4/4), done.\r\nReceiving objects: 47% (47/100), 2 MiB | 1 MiB/s\rファイルを展開中: 80% (8/10)\nResolving deltas: 100% (3/3), done."
        var events: [GitTransferProgress] = []
        for byte in text.utf8 { events += parser.consume(Data([byte])) }
        events += parser.consume(Data(), finish: true)
        XCTAssertEqual(events.map(\.percent), [25, 100, 47, 80, 100])
        XCTAssertEqual(events.map(\.stage), ["Counting objects", "Counting objects", "Receiving objects", "ファイルを展開中", "Resolving deltas"])
        XCTAssertTrue(events[2].detail.contains("2 MiB | 1 MiB/s"))
        XCTAssertTrue(parser.consume(Data("fatal: not a repository\nReceiving objects: 120% (12/10)\n".utf8)).isEmpty)
        XCTAssertNil(GitTransferProgress.connecting.percent); XCTAssertNil(GitTransferProgress.checking.percent)
        XCTAssertEqual(GitTransferProgress.completed.percent, 100); XCTAssertNil(GitTransferProgress.failed.percent)
    }
    func testProgressArrivesBeforeProcessExitAndOutputIsPreserved() throws {
        let root = try temporary(), script = root.appendingPathComponent("git-progress-fixture")
        try """
        #!/bin/sh
        printf '%s\\r' 'Receiving objects: 25% (1/4)'
        printf '%s\\r' 'Receiving objects: 25% (1/4)' >&2
        sleep 0.3
        printf '%s\\r' 'Receiving objects: 75% (3/4)' >&2
        sleep 0.3
        printf '%s\\n' 'Receiving objects: 100% (4/4), done.' >&2
        printf '%s\\n' 'complete output'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let previous = UserDefaults.standard.object(forKey: "gitExecutable")
        UserDefaults.standard.set(script.path, forKey: "gitExecutable")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "gitExecutable") }
            else { UserDefaults.standard.removeObject(forKey: "gitExecutable") }
        }
        let events = Events()
        let output = try GitProcess.runWithOutput(in: root.path, arguments: ["fetch", "--progress"], progress: { events.record($0) })
        let ended = Date(), recorded = events.snapshots
        XCTAssertTrue(recorded.contains { $0.0.percent == 25 && ended.timeIntervalSince($0.1) >= 0.2 }, "Percentage must reach the observer while Git is still running")
        XCTAssertTrue(recorded.contains { $0.0.percent == 75 })
        XCTAssertEqual(recorded.last?.0.percent, 100)
        XCTAssertTrue(String(decoding: output.data, as: UTF8.self).contains("complete output"))
        XCTAssertTrue(output.diagnostics.contains("25%")); XCTAssertTrue(output.diagnostics.contains("75%")); XCTAssertTrue(output.diagnostics.contains("100%"))
    }
    @MainActor
    func testClonePushFetchPullProgressAndCompletionFollowActualGitResults() async throws {
        let root = try temporary(), sourceURL = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let source = try GitRepository.initialize(sourceURL.path)
        try source.setIdentity(name: "Progress Tester", email: "progress@example.invalid")
        let payload = (0..<6000).map { "row \($0) : \(($0 * 751) % 100000)" }.joined(separator: "\n")
        let file = URL(fileURLWithPath: source.path).appendingPathComponent("payload.txt")
        try payload.write(to: file, atomically: true, encoding: .utf8); try source.commit(["payload.txt"], "initial")
        let bareURL = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: bareURL, withIntermediateDirectories: true)
        let bare = GitRepository(path: bareURL.path)
        _ = try bare.run(["init", "--bare", "--initial-branch=main"])
        _ = try source.run(["remote", "add", "origin", bareURL.absoluteString])
        let push = Events(); _ = try source.transfer(.push, remote: "origin", progress: { push.record($0) })
        XCTAssertTrue(push.snapshots.contains { $0.0.stage == "Writing objects" && $0.0.percent != nil })
        XCTAssertEqual(try bare.revision("main"), try source.revision("HEAD"))
        let clone = Events(), target = root.appendingPathComponent("clone")
        let repo = try GitRepository.clone(bareURL.absoluteString, target.path, progress: { clone.record($0) })
        XCTAssertTrue(clone.snapshots.contains { $0.0.stage == "Receiving objects" && $0.0.percent != nil })
        XCTAssertEqual(try repo.revision("HEAD"), try source.revision("HEAD"))
        try (payload + "\nupdated\n").write(to: file, atomically: true, encoding: .utf8); try source.commit(["payload.txt"], "update")
        _ = try source.transfer(.push, remote: "origin")
        let fetch = Events(), fetchReport = try repo.transfer(.fetch, remote: "origin", progress: { fetch.record($0) })
        XCTAssertTrue(fetch.snapshots.contains { $0.0.percent != nil }, fetchReport.output)
        let model = Workspace(); model.launch(LaunchRequest(action: .pull, paths: [repo.path]))
        try await wait { !model.busy }
        model.runAction()
        XCTAssertTrue(model.busy); XCTAssertEqual(model.transferProgress, .connecting)
        try await wait { !model.busy }
        XCTAssertFalse(model.failed, model.status); XCTAssertEqual(model.transferProgress, .completed)
        XCTAssertEqual(model.transferReport?.commits, 1)
        XCTAssertEqual(try repo.revision("HEAD"), try source.revision("HEAD"))
        model.runAction(); try await wait { !model.busy }
        XCTAssertEqual(model.transferProgress, .completed); XCTAssertEqual(model.transferReport?.commits, 0)
        _ = try repo.run(["remote", "add", "missing", root.appendingPathComponent("does-not-exist.git").path])
        model.selectAction(.fetch); model.chosenRemote = "missing"; model.runAction()
        try await wait { !model.busy }
        XCTAssertTrue(model.failed); XCTAssertEqual(model.transferProgress, .failed)
        XCTAssertNil(model.transferProgress?.percent, "Failed operations must not display successful 100% completion")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.transferProgress, .failed, "Late progress must not overwrite the failure result")
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard condition() else { XCTFail("Git operation did not finish"); throw NSError(domain: "TransferProgressTests", code: 1) }
    }
}
