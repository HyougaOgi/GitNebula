import XCTest
@testable import GitNebula

final class ToolTests: XCTestCase {
    var root: URL!
    var repo: GitRepository!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nebula tools 星 " + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = try GitRepository.initialize(root.path)
        try repo.setIdentity(name: "Test", email: "test@example.invalid")
        try write("orbit.txt", "base\n"); try repo.commit(["orbit.txt"], "initial")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func write(_ name: String, _ text: String) throws { try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }

    func testInitAndRemoteSettings() throws {
        XCTAssertThrowsError(try GitRepository.initialize(root.path))
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertThrowsError(try GitRepository.initialize(nested.path))
        XCTAssertThrowsError(try GitRepository.initialize(root.appendingPathComponent("missing").path))
        try repo.setRemote("origin", url: "https://example.invalid/first.git")
        try repo.setRemote("origin", url: "https://example.invalid/second.git")
        XCTAssertEqual(try repo.remotes(), ["origin"])
        XCTAssertTrue(try repo.remoteDetails().contains("second.git"))
        try repo.removeRemote("origin"); XCTAssertTrue(try repo.remotes().isEmpty)
        XCTAssertThrowsError(try repo.setRemote("--bad", url: "url"))
        XCTAssertTrue(try repo.identity().contains("test@example.invalid"))
    }
    func testStashRestoresIndexAndUntrackedFilesAndUsesStableIDs() throws {
        try write("orbit.txt", "staged\n"); try repo.stage(["orbit.txt"])
        try write("orbit.txt", "working\n"); try write("new file.txt", "untracked\n")
        try repo.saveStash("first", includeUntracked: true)
        let first = try XCTUnwrap(repo.stashes().first)
        XCTAssertTrue(try repo.changes().isEmpty)
        try write("orbit.txt", "second\n"); try repo.saveStash("second", includeUntracked: true)
        XCTAssertEqual(try repo.stashReference(first.id), "stash@{1}")
        XCTAssertTrue(try repo.showStash(first.id).contains("untracked"))
        try repo.applyStash(first.id)
        XCTAssertEqual(try repo.readFile("orbit.txt"), "working\n")
        XCTAssertEqual(try repo.run(["show", ":orbit.txt"]), "staged\n")
        XCTAssertEqual(try repo.readFile("new file.txt"), "untracked\n")
        XCTAssertThrowsError(try repo.applyStash(first.id, pop: true))
        XCTAssertEqual(try repo.stashes().count, 2)
        try repo.commit(["orbit.txt", "new file.txt"], "restored")
        try repo.dropStash(first.id)
        XCTAssertEqual(try repo.stashes().count, 1)
        XCTAssertThrowsError(try repo.dropStash(first.id))
    }
    func testStashPopSuccessAndConflictPreservesEntry() throws {
        try write("orbit.txt", "stashed\n"); try repo.saveStash("pop success", includeUntracked: false)
        let first = try XCTUnwrap(repo.stashes().first)
        try repo.applyStash(first.id, pop: true)
        XCTAssertTrue(try repo.stashes().isEmpty); XCTAssertEqual(try repo.readFile("orbit.txt"), "stashed\n")
        try repo.commit(["orbit.txt"], "restored")
        try write("orbit.txt", "stashed conflict\n"); try repo.saveStash("pop conflict", includeUntracked: true)
        let conflict = try XCTUnwrap(repo.stashes().first)
        try write("orbit.txt", "new base\n"); try repo.commit(["orbit.txt"], "new base")
        XCTAssertThrowsError(try repo.applyStash(conflict.id, pop: true))
        XCTAssertTrue(try repo.stashes().contains { $0.id == conflict.id })
        XCTAssertEqual(try repo.conflicts(), ["orbit.txt"])
        try repo.saveResolution("orbit.txt", "resolved\n"); try repo.commit(["orbit.txt"], "resolved stash")
        try repo.dropStash(conflict.id)
        try write("untracked.txt", "only untracked\n")
        XCTAssertThrowsError(try repo.saveStash("no-op", includeUntracked: false))
        XCTAssertTrue(try repo.stashes().isEmpty)
    }
    func testUnstageBeforeFirstCommitPreservesWorkingContent() throws {
        let folder = root.appendingPathComponent("unborn-repository")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let empty = GitRepository(path: folder.path)
        _ = try empty.run(["init", "--initial-branch=main"])
        try "staged\n".write(to: folder.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try empty.stage(["file.txt"])
        try "working\n".write(to: folder.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "untracked\n".write(to: folder.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try empty.unstage(["file.txt", "new.txt"])
        XCTAssertEqual(try empty.readFile("file.txt"), "working\n")
        XCTAssertTrue(try empty.changes().allSatisfy { $0.code == "??" })
        XCTAssertEqual(try empty.readFile("new.txt"), "untracked\n")
    }
    func testUnstageMixedSelectionPreservesUnstagedChanges() throws {
        try write("orbit.txt", "staged\n"); try repo.stage(["orbit.txt"])
        try write("orbit.txt", "working\n"); try write("new.txt", "untracked\n")
        try repo.unstage(["orbit.txt", "new.txt"])
        XCTAssertEqual(try repo.run(["diff", "--cached", "--name-only"]), "")
        XCTAssertEqual(try repo.readFile("orbit.txt"), "working\n")
        XCTAssertEqual(try repo.readFile("new.txt"), "untracked\n")
        XCTAssertThrowsError(try repo.unstage(["orbit.txt", "new.txt"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("ステージ済みの変更はありません"))
        }
    }
    func testPushExplainsUnbornAndDetachedBranchWithoutContactingRemote() throws {
        let folder = root.appendingPathComponent("unborn")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let empty = GitRepository(path: folder.path)
        _ = try empty.run(["init", "--initial-branch=main"])
        try empty.setRemote("origin", url: folder.appendingPathComponent("missing.git").path)
        XCTAssertThrowsError(try empty.push("origin")) { error in
            XCTAssertTrue(error.localizedDescription.contains("最初のコミット"))
        }
        try repo.setRemote("origin", url: folder.appendingPathComponent("missing.git").path)
        _ = try repo.run(["switch", "--detach", "HEAD"])
        XCTAssertThrowsError(try repo.push("origin")) { error in
            XCTAssertTrue(error.localizedDescription.contains("ブランチを選んでください"))
        }
    }
    func testDiffDoesNotLaunchConfiguredExternalTool() throws {
        try write("orbit.txt", "changed\n")
        _ = try repo.run(["config", "diff.external", "gitnebula-nonexistent-diff-helper"])
        XCTAssertTrue(try repo.diff("orbit.txt").contains("+changed"))
    }
    func testTagsAndRevisionValidation() throws {
        try repo.createTag("v1.0", at: "HEAD", message: "release")
        try repo.createTag("lightweight", at: "HEAD", message: "")
        XCTAssertEqual(Set(try repo.tags()), ["v1.0", "lightweight"])
        XCTAssertTrue(try repo.showCommit("v1.0").contains("initial"))
        XCTAssertThrowsError(try repo.createTag("--bad", at: "HEAD", message: ""))
        XCTAssertThrowsError(try repo.revision("--help"))
        XCTAssertThrowsError(try repo.createTag("v1.0", at: "HEAD", message: "again"))
        try repo.deleteTag("v1.0"); XCTAssertEqual(try repo.tags(), ["lightweight"])
    }
    func testSelectedFileOperationsAndLiteralIgnorePatterns() throws {
        try write("orbit.txt", "change\n"); try write("other.txt", "other\n")
        try repo.stage(["orbit.txt"])
        XCTAssertEqual(try repo.run(["diff", "--cached", "--name-only"]), "orbit.txt\n")
        try repo.unstage(["orbit.txt"])
        XCTAssertEqual(try repo.run(["diff", "--cached", "--name-only"]), "")
        XCTAssertThrowsError(try repo.discard(["other.txt"]))
        try repo.discard(["orbit.txt"])
        XCTAssertEqual(try repo.readFile("orbit.txt"), "base\n")
        XCTAssertEqual(try repo.readFile("other.txt"), "other\n")
        try write("[abc] #!.txt", "ignore\n")
        try write("a #!.txt", "retain\n")
        try repo.ignore(["[abc] #!.txt"])
        XCTAssertFalse(try repo.changes().contains(where: { $0.path == "[abc] #!.txt" }))
        XCTAssertTrue(try repo.changes().contains(where: { $0.path == "a #!.txt" }))
        XCTAssertThrowsError(try repo.ignore(["orbit.txt"]))
    }
    func testBinaryPatchRoundTripAndHistoryReaders() throws {
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("binary"))
        try repo.commit(["binary"], "binary")
        try Data([0, 255, 10, 9, 8]).write(to: root.appendingPathComponent("binary"))
        try write("orbit.txt", "new\n")
        let patch = root.appendingPathComponent("saved.patch")
        try repo.exportPatch(to: patch.path)
        XCTAssertThrowsError(try repo.exportPatch(to: patch.path))
        try repo.discard(["binary", "orbit.txt"])
        try repo.applyPatch(patch.path, checkOnly: true)
        XCTAssertEqual(try repo.readFile("orbit.txt"), "base\n")
        try repo.applyPatch(patch.path, checkOnly: false)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("binary")), Data([0, 255, 10, 9, 8]))
        XCTAssertEqual(try repo.readFile("orbit.txt"), "new\n")
        XCTAssertTrue(try repo.blame("orbit.txt", at: "HEAD").contains("base"))
        XCTAssertTrue(try repo.fileHistory("orbit.txt").contains("initial"))
        XCTAssertTrue(try repo.reflog().contains("binary"))
        XCTAssertThrowsError(try repo.blame("../outside", at: "HEAD"))
    }
    func testCherryPickConflictContinueRevertAndReset() throws {
        let base = try repo.revision("HEAD")
        try repo.createBranch("feature")
        try write("orbit.txt", "feature\n"); try repo.commit(["orbit.txt"], "feature")
        let feature = try repo.revision("HEAD")
        try repo.switchBranch("main")
        try write("orbit.txt", "main\n"); try repo.commit(["orbit.txt"], "main")
        XCTAssertThrowsError(try repo.cherryPick(feature))
        XCTAssertEqual(try repo.sequence(), .cherryPick)
        XCTAssertThrowsError(try repo.createBranch("while-conflicting"))
        XCTAssertThrowsError(try repo.renameBranch("main", "while-conflicting"))
        XCTAssertThrowsError(try repo.deleteBranch("feature"))
        try repo.saveResolution("orbit.txt", "resolved\n")
        XCTAssertThrowsError(try repo.commit(["orbit.txt"], "wrong completion"))
        try repo.continueSequence()
        XCTAssertNil(try repo.sequence())
        let applied = try repo.revision("HEAD")
        try repo.revert(applied)
        XCTAssertEqual(try repo.readFile("orbit.txt"), "main\n")
        XCTAssertTrue(try repo.compare(base, "HEAD").contains("+main"))
        try repo.reset(base, mode: "soft")
        XCTAssertEqual(try repo.revision("HEAD"), base)
        XCTAssertEqual(try repo.readFile("orbit.txt"), "main\n")
        XCTAssertThrowsError(try repo.reset(base, mode: "hard"))
    }
    func testRebaseConflictAbortAndContinue() throws {
        try repo.createBranch("feature")
        try write("orbit.txt", "feature\n"); try repo.commit(["orbit.txt"], "feature")
        let feature = try repo.revision("HEAD")
        try repo.switchBranch("main")
        try write("orbit.txt", "main\n"); try repo.commit(["orbit.txt"], "main")
        try repo.switchBranch("feature")
        XCTAssertThrowsError(try repo.rebase(onto: "main"))
        XCTAssertEqual(try repo.sequence(), .rebase)
        try repo.abortSequence()
        XCTAssertNil(try repo.sequence()); XCTAssertEqual(try repo.revision("HEAD"), feature)
        XCTAssertThrowsError(try repo.rebase(onto: "main"))
        try repo.saveResolution("orbit.txt", "resolved\n")
        try repo.continueSequence()
        XCTAssertNil(try repo.sequence()); XCTAssertEqual(try repo.readFile("orbit.txt"), "resolved\n")
        XCTAssertEqual(try repo.run(["rev-list", "--count", "main..HEAD"]).trimmingCharacters(in: .newlines), "1")
    }
    func testWorktreeAndSubmoduleListing() throws {
        let target = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: target) }
        try repo.addWorktree(at: target.path, branch: "parallel-work")
        XCTAssertTrue(try repo.worktrees().contains(target.path))
        XCTAssertEqual(try GitRepository.open(target.path).readFile("orbit.txt"), "base\n")
        XCTAssertThrowsError(try repo.addWorktree(at: target.path, branch: "duplicate"))
        XCTAssertEqual(try repo.submodules(), "")
        XCTAssertThrowsError(try repo.addSubmodule(source: "--bad", destination: "module"))
    }
}
