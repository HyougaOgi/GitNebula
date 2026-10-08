import XCTest
@testable import GitNebula

@MainActor final class BranchSwitchTests: LocalizedTestCase {
    private func fixture() throws -> (URL, GitRepository, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("branch-switch-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let source = try GitRepository.initialize(sourceURL.path)
        try source.setIdentity(name: "Branch Tester", email: "branch@example.invalid")
        try "base\n".write(to: sourceURL.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try source.commit(["file.txt"], "base")
        try source.createBranch("feature/nested")
        try "feature\n".write(to: sourceURL.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try source.commit(["file.txt"], "feature")
        try source.switchBranch("main")
        let clone = try GitRepository.clone(source.path, root.appendingPathComponent("clone").path)
        return (root, source, clone)
    }
    func testCloneListsRemoteBranchAndSwitchCreatesTrackingBranch() throws {
        let (_, source, clone) = try fixture()
        XCTAssertEqual(try clone.branches(), ["main"])
        let choices = try clone.branchRecords(includeRemote: true)
        XCTAssertEqual(choices.map(\.name), ["main", "origin/feature/nested"])
        let feature = try XCTUnwrap(choices.first { $0.remote })
        XCTAssertEqual(feature.localName, "feature/nested")
        try clone.switchBranch(feature.id)
        XCTAssertEqual(try clone.currentBranch(), "feature/nested")
        XCTAssertEqual(try clone.revision("HEAD"), try source.revision("feature/nested"))
        XCTAssertEqual(try clone.configuration("branch.feature/nested.remote"), "origin")
        XCTAssertEqual(try clone.configuration("branch.feature/nested.merge"), "refs/heads/feature/nested")
        XCTAssertEqual(try clone.readFile("file.txt"), "feature\n")
        XCTAssertFalse(try clone.branchRecords(includeRemote: true).contains { $0.remote && $0.name == feature.name })
        try clone.switchBranch("main"); try clone.switchBranch("feature/nested")
        XCTAssertEqual(try clone.currentBranch(), "feature/nested")
    }
    func testDirtyWorkAndNameCollisionPreserveFilesAndBranches() throws {
        let (_, _, clone) = try fixture()
        try "keep work\n".write(to: URL(fileURLWithPath: clone.path).appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let head = try clone.revision("HEAD")
        XCTAssertThrowsError(try clone.switchBranch("refs/remotes/origin/feature/nested"))
        XCTAssertEqual(try clone.readFile("file.txt"), "keep work\n")
        XCTAssertEqual(try clone.revision("HEAD"), head)
        _ = try clone.run(["restore", "--", "file.txt"])
        _ = try clone.run(["branch", "feature/nested", "main"])
        XCTAssertThrowsError(try clone.switchBranch("refs/remotes/origin/feature/nested"))
        XCTAssertEqual(try clone.revision("feature/nested"), head)
        XCTAssertEqual(try clone.currentBranch(), "main")
    }
    func testRefreshDiscoversNewRemoteBranchWithoutChangingScreen() async throws {
        let (_, source, clone) = try fixture()
        try source.createBranch("new-remote")
        _ = try clone.run(["config", "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/main"])
        let model = Workspace(); model.launch(LaunchRequest(action: .switchBranch, paths: [clone.path]))
        try await wait { !model.busy }
        model.chosenBranch = "refs/remotes/origin/feature/nested"
        XCTAssertFalse(try clone.branchRecords(includeRemote: true).contains { $0.name == "origin/new-remote" })
        model.fetchRemoteBranches(); try await wait { !model.busy }
        XCTAssertFalse(model.failed, model.status); XCTAssertEqual(model.action, .switchBranch)
        XCTAssertEqual(model.transferProgress, .completed)
        XCTAssertEqual(model.chosenBranch, "refs/remotes/origin/feature/nested")
        XCTAssertTrue(try clone.branchRecords(includeRemote: true).contains { $0.name == "origin/new-remote" })
        try clone.switchBranch("refs/remotes/origin/new-remote")
        XCTAssertEqual(try clone.currentBranch(), "new-remote")
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate())
    }
}
