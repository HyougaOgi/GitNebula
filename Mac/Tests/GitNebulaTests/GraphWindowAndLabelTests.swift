import XCTest
import AppKit
@testable import GitNebula

@MainActor final class GraphWindowAndLabelTests: XCTestCase {
    private func record(_ id: String, _ parents: [String] = [], _ refs: String = "") -> CommitRecord {
        CommitRecord(id: id, parents: parents, author: "Tester", email: "test@example.invalid", date: "2026-10-09", decorations: refs, subject: id, message: id)
    }
    func testBranchLabelsExcludeTagsAndResolveMergedHistory() {
        let commits = [
            record("main-tip", ["merge"], "tag: v2, origin/main, HEAD -> main, origin/HEAD"),
            record("merge", ["main-old", "merged-feature"]), record("main-old", ["base"]), record("base"),
            record("feature", ["base"], "tag: feature-v1, HEAD -> feature/topic, origin/feature/topic"),
            record("merged-feature", ["base"], "tag: old-feature"), record("orphan", [], "tag: orphan")
        ]
        let branches = NebulaBranch.group(GitGraphLayout.rows(commits))
        func branch(_ id: String) -> NebulaBranch { branches.first { $0.rows.contains { $0.id == id } }! }
        XCTAssertEqual(branch("main-tip").title, "main, origin/main")
        XCTAssertEqual(branch("feature").title, "feature/topic, origin/feature/topic")
        XCTAssertEqual(branch("merged-feature").title, "main, origin/main")
        XCTAssertEqual(branch("orphan").title, "orphan")
        XCTAssertEqual(branches.flatMap(\.rows).count, commits.count)
        XCTAssertEqual(NebulaBranch.branchNames("tag: v1, refs/heads/release/HEAD, refs/remotes/origin/release/HEAD, refs/remotes/origin/HEAD"), ["release/HEAD", "origin/release/HEAD"])
        XCTAssertTrue(NebulaBranch.branchNames("HEAD, tag: v1, refs/stash, refs/notes/review").isEmpty)
    }
    func testHistoryAndGraphKeepIndependentWindowSizesAndRoutes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graph-window-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try GitRepository.initialize(root.path)
        try repo.setIdentity(name: "Tester", email: "test@example.invalid")
        try "base".write(to: root.appendingPathComponent("base"), atomically: true, encoding: .utf8)
        try repo.commit(["base"], "base")
        let delegate = ApplicationDelegate()
        defer { for window in delegate.windows { window.delegate = nil; window.close() } }
        func wait(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(20)
            while (!condition() || delegate.hasPendingLaunchRequests) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            let ready = condition() && !delegate.hasPendingLaunchRequests
            XCTAssertTrue(ready, "Timed out routing a window: action=\(String(describing: delegate.navigation.current?.model?.action)), windows=\(delegate.windows.count), busy=\(delegate.navigation.busy)", line: line)
            if !ready { throw NSError(domain: "GraphWindowAndLabelTests", code: 1) }
        }
        delegate.beginLaunch(LaunchRequest(action: .log, paths: [root.appendingPathComponent("base").path]))
        try await wait { delegate.navigation.current?.model?.action == .log && !delegate.navigation.busy }
        let historyWindow = try XCTUnwrap(delegate.window), history = delegate.navigation
        let historyFrame = try XCTUnwrap(history.current)
        history.openAction(.graph)
        try await wait { delegate.windows.count == 2 && delegate.navigation.current?.model?.action == .graph && !delegate.navigation.busy }
        let graphWindow = try XCTUnwrap(delegate.window), graph = delegate.navigation
        let graphFrame = try XCTUnwrap(graph.current), graphSize = graphWindow.frame.size
        let screenSize = NSScreen.main?.visibleFrame.size ?? .zero
        let supportsNativeLayout = screenSize.width >= WorkspaceWindowLayout.minimum.width && screenSize.height >= WorkspaceWindowLayout.minimum.height
        print("Graph window test display: \(screenSize), native layout available: \(supportsNativeLayout)")
        XCTAssertFalse(historyWindow === graphWindow)
        var frame = historyWindow.frame; frame.size.width += 170
        historyWindow.setFrame(frame, display: false)
        XCTAssertEqual(graphWindow.frame.size, graphSize)
        XCTAssertTrue(history.current === historyFrame)
        XCTAssertTrue(graph.current === graphFrame)
        history.openAction(.graph)
        try await wait { delegate.window === graphWindow && !graph.busy }
        XCTAssertEqual(delegate.windows.count, 2)
        XCTAssertTrue(graph.current === graphFrame, "Reopening the graph must retain its view and camera")
        XCTAssertEqual(graphWindow.frame.width, graphSize.width)
        if supportsNativeLayout { XCTAssertEqual(graphWindow.frame.size, graphSize) }
        delegate.application(NSApp, open: [try LaunchRequest(action: .graph, paths: [repo.path]).url()])
        try await wait { delegate.window === graphWindow && !graph.busy }
        XCTAssertTrue(graph.current === graphFrame, "File and repository requests share the retained graph view")
        graph.openAction(.log)
        try await wait { delegate.window === historyWindow && !history.busy }
        XCTAssertTrue(history.current === historyFrame)
        XCTAssertEqual(historyWindow.frame.size.width, frame.width)
    }
    func testGraphUsesActualGitBranchRefsInsteadOfDecorationHeuristics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graph-refs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try GitRepository.initialize(root.path)
        try repo.setIdentity(name: "Tester", email: "test@example.invalid")
        try "base".write(to: root.appendingPathComponent("base"), atomically: true, encoding: .utf8)
        try repo.commit(["base"], "base")
        let main = try repo.currentBranch(), id = try XCTUnwrap(repo.headRevision())
        _ = try repo.run(["branch", "release/HEAD"])
        _ = try repo.run(["tag", "v1"])
        _ = try repo.run(["update-ref", "refs/remotes/team/release/HEAD", id])
        _ = try repo.run(["symbolic-ref", "refs/remotes/team/HEAD", "refs/remotes/team/release/HEAD"])
        _ = try repo.run(["update-ref", "refs/notes/review", id])
        let rows = GitGraphLayout.rows(try repo.history(topological: true))
        XCTAssertEqual(Set(try XCTUnwrap(rows.first?.commit.branchNames)), Set([main, "release/HEAD", "team/release/HEAD"]))
        XCTAssertEqual(NebulaBranch.group(rows).first?.title, [main, "release/HEAD", "team/release/HEAD"].joined(separator: ", "))
    }
}
