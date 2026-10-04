import XCTest
@testable import GitNebula

final class GitTests: XCTestCase {
    var root: URL!
    var repo: GitRepository!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = GitRepository(path: root.path)
        _ = try repo.run(["init", "-q"])
        _ = try repo.run(["config", "user.name", "Test"])
        _ = try repo.run(["config", "user.email", "test@example.invalid"])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func write(_ file: String, _ text: String) throws { try text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8) }
    func testSelectionRenameAndStagedDeletion() throws {
        try write("old.txt", "base\n"); try write("other.txt", "unselected\n")
        XCTAssertEqual(try repo.diff("old.txt"), "base\n")
        _ = try repo.run(["add", "other.txt"]); try repo.commit(["old.txt"], "initial")
        XCTAssertEqual(try repo.run(["diff", "--cached", "--name-only"]), "other.txt\n")
        try repo.commit(["other.txt"], "other")
        _ = try repo.run(["mv", "old.txt", "new.txt"]); try write("old.txt", "recreated\n")
        let tree = try repo.run(["write-tree"])
        XCTAssertThrowsError(try repo.commit(["new.txt"], "unsafe"))
        XCTAssertEqual(try repo.run(["write-tree"]), tree)
        try repo.commit(["new.txt", "old.txt"], "explicit selection")
        _ = try repo.run(["rm", "old.txt"]); try repo.commit(["old.txt"], "delete")
        XCTAssertFalse(try repo.run(["ls-tree", "--name-only", "HEAD"]).contains("old.txt"))
    }
    func testBranchesConflictAndGraph() throws {
        try write("orbit.txt", "base\n"); try repo.commit(["orbit.txt"], "initial")
        let branch = try repo.run(["symbolic-ref", "--short", "HEAD"]).trimmingCharacters(in: .newlines)
        try repo.createBranch("feature"); try repo.renameBranch("feature", "incoming")
        try write("orbit.txt", "incoming\n"); try repo.commit(["orbit.txt"], "incoming")
        try repo.switchBranch(branch)
        try write("orbit.txt", "current\n"); try repo.commit(["orbit.txt"], "current")
        XCTAssertThrowsError(try repo.merge("incoming"))
        XCTAssertEqual(try repo.conflicts(), ["orbit.txt"])
        XCTAssertTrue(try repo.conflictText("orbit.txt").contains("<<<<<<<"))
        try repo.saveResolution("orbit.txt", "resolved\n"); try repo.finishMerge("resolved merge")
        XCTAssertFalse(try repo.mergeInProgress())
        XCTAssertEqual(try repo.run(["rev-list", "--parents", "-1", "HEAD"]).split(separator: " ").count, 3)
        try repo.deleteBranch("incoming")
        XCTAssertTrue(try repo.graph().contains("resolved merge"))
    }
    func testLocalRemoteRoundTrip() throws {
        try write("orbit.txt", "base\n"); try repo.commit(["orbit.txt"], "initial")
        let branch = try repo.run(["symbolic-ref", "--short", "HEAD"]).trimmingCharacters(in: .newlines)
        let parent = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let runner = GitRepository(path: parent.path)
        _ = try runner.run(["init", "--bare", "-q", "remote.git"])
        let remote = GitRepository(path: parent.appendingPathComponent("remote.git").path)
        _ = try remote.run(["symbolic-ref", "HEAD", "refs/heads/" + branch])
        _ = try repo.run(["remote", "add", "origin", remote.path]); try repo.push("origin")
        let clone = try GitRepository.clone(remote.path, parent.appendingPathComponent("clone").path)
        _ = try clone.run(["config", "user.name", "Test"]); _ = try clone.run(["config", "user.email", "test@example.invalid"])
        try "remote update\n".write(to: URL(fileURLWithPath: clone.path).appendingPathComponent("orbit.txt"), atomically: true, encoding: .utf8)
        try clone.commit(["orbit.txt"], "remote update"); try clone.push("origin")
        try repo.fetch("origin"); try repo.pull("origin")
        XCTAssertEqual(try repo.readFile("orbit.txt"), "remote update\n")
    }
}
