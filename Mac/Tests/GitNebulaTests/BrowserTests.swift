import XCTest
import SwiftUI
import AppKit
@testable import GitNebula

final class BrowserTests: XCTestCase {
    var root: URL!
    var repo: GitRepository!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GUI 星 & " + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = try GitRepository.initialize(root.path)
        try repo.setIdentity(name: "GUI Tester", email: "gui@example.invalid")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func write(_ file: String, _ text: String) throws { try text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8) }
    func change(_ file: String) throws -> Change { try XCTUnwrap(repo.changes().first { $0.path == file }) }
    func assertReconstructs(_ document: DiffDocument, old: String, new: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(document.rows.compactMap(\.oldText), DiffDocument.lines(Data(old.utf8)), file: file, line: line)
        XCTAssertEqual(document.rows.compactMap(\.newText), DiffDocument.lines(Data(new.utf8)), file: file, line: line)
        XCTAssertEqual(document.rows.compactMap(\.oldNumber), (0..<DiffDocument.lines(Data(old.utf8)).count).map { $0 + 1 }, file: file, line: line)
    }
    func testAlignedWorkingDiffAndNewlineChanges() throws {
        let old = "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\n"
        let new = "alpha\nbeta revised\ninserted\ngamma\ndelta\nepsilon\nzeta\ntheta\n"
        try write("orbit 星.txt", old); try repo.commit(["orbit 星.txt"], "initial")
        try write("orbit 星.txt", new)
        _ = try repo.run(["add", "--", "orbit 星.txt"])
        try write("orbit 星.txt", new + "working only\n")
        let diff = try repo.comparison(change("orbit 星.txt"), from: "HEAD")
        assertReconstructs(diff, old: old, new: new + "working only\n")
        XCTAssertEqual(diff.hunks.count, 3)
        XCTAssertEqual(diff.additions, 3); XCTAssertEqual(diff.deletions, 2)
        XCTAssertTrue(diff.rows.contains { $0.kind == .added && $0.oldNumber == nil })
        XCTAssertTrue(diff.rows.contains { $0.kind == .removed && $0.newNumber == nil })
        let newline = try repo.compareFiles(old: FileRevision(Data("same\n".utf8)), new: FileRevision(Data("same".utf8)), path: "test", oldTitle: "before", newTitle: "after")
        XCTAssertTrue(newline.oldEndsInNewline); XCTAssertFalse(newline.newEndsInNewline)
        XCTAssertEqual(newline.hunks.count, 1)
        XCTAssertEqual(newline.rows.first?.kind, .modified)
    }
    func testUnbornDeletedRenamedBinaryAndSymlinkComparisons() throws {
        try write("new #&.txt", "new file\n")
        let untracked = try repo.comparison(change("new #&.txt"), from: "HEAD")
        XCTAssertFalse(untracked.old.exists); XCTAssertEqual(untracked.additions, 1)
        _ = try repo.run(["add", "--", "new #&.txt"])
        let staged = try repo.comparison(change("new #&.txt"), from: "HEAD")
        XCTAssertEqual(staged.rows.first?.newText, "new file")
        try repo.commit(["new #&.txt"], "initial")
        _ = try repo.run(["mv", "new #&.txt", "renamed.txt"])
        let rename = try repo.comparison(change("renamed.txt"), from: "HEAD")
        assertReconstructs(rename, old: "new file\n", new: "new file\n")
        XCTAssertTrue(rename.hunks.isEmpty)
        try repo.commit(["renamed.txt"], "rename")
        try FileManager.default.removeItem(at: root.appendingPathComponent("renamed.txt"))
        let removed = try repo.comparison(change("renamed.txt"), from: "HEAD")
        XCTAssertFalse(removed.new.exists); XCTAssertEqual(removed.deletions, 1)
        try Data([0, 255, 1]).write(to: root.appendingPathComponent("binary"))
        XCTAssertTrue(try repo.comparison(change("binary"), from: "HEAD").notice?.contains("バイナリ") == true)
        try Data(repeating: 65, count: 1024 * 1024 + 1).write(to: root.appendingPathComponent("large"))
        XCTAssertTrue(try repo.comparison(change("large"), from: "HEAD").notice?.contains("1 MiB") == true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/outside/not-read")
        XCTAssertEqual(try repo.comparison(change("link"), from: "HEAD").rows.first?.newText, "/outside/not-read")
    }
    func testHistoryPaginationCommitDetailsAndParentComparisons() throws {
        XCTAssertTrue(try repo.history().isEmpty)
        try write("orbit.txt", "one\n"); try repo.commit(["orbit.txt"], "最初のコミット\n\n本文の一行目\n二行目")
        let initial = try repo.revision("HEAD")
        try write("orbit.txt", "two\n"); try repo.commit(["orbit.txt"], "次のコミット")
        let second = try repo.revision("HEAD")
        try repo.createTag("v1.0", at: "HEAD", message: "release")
        let history = try repo.history()
        XCTAssertEqual(history.count, 2); XCTAssertEqual(history[0].id, second)
        XCTAssertTrue(history[0].decorations.contains("v1.0"))
        XCTAssertEqual(history[0].parents, [initial])
        XCTAssertTrue(history[1].message.contains("本文の一行目\n二行目"))
        XCTAssertTrue(history[1].matches("本文")); XCTAssertTrue(history[1].matches("gui tester"))
        XCTAssertEqual(try repo.history(limit: 1, skip: 1).first?.id, initial)
        XCTAssertEqual(try repo.history(reference: initial).count, 1)
        let files = try repo.revisionChanges(from: initial, to: second)
        XCTAssertEqual(files.map(\.path), ["orbit.txt"])
        let diff = try repo.comparison(files[0], from: initial, to: second)
        assertReconstructs(diff, old: "one\n", new: "two\n")
        let rootFiles = try repo.revisionChanges(from: nil, to: initial)
        XCTAssertEqual(rootFiles.map(\.path), ["orbit.txt"])
        XCTAssertFalse(try repo.comparison(rootFiles[0], from: nil, to: initial).old.exists)
        _ = try repo.run(["mv", "orbit.txt", "renamed 星.txt"]); try repo.commit(["renamed 星.txt"], "rename")
        XCTAssertEqual(try repo.history(file: "renamed 星.txt").count, 3)
        let renamed = try XCTUnwrap(repo.revisionChanges(from: second, to: "HEAD").first)
        XCTAssertEqual(renamed.original, "orbit.txt")
        assertReconstructs(try repo.comparison(renamed, from: second, to: "HEAD"), old: "two\n", new: "two\n")
    }
    func testMergeParentsStashAndStructuredTools() throws {
        try write("main.txt", "base\n"); try repo.commit(["main.txt"], "base")
        try repo.createBranch("feature")
        try write("feature.txt", "feature\n"); try repo.commit(["feature.txt"], "feature")
        try repo.switchBranch("main")
        try write("main.txt", "main updated\n"); try repo.commit(["main.txt"], "main update")
        try repo.merge("feature")
        let merge = try XCTUnwrap(repo.history().first)
        XCTAssertEqual(merge.parents.count, 2)
        XCTAssertEqual(try repo.revisionChanges(from: merge.parents[0], to: merge.id).map(\.path), ["feature.txt"])
        XCTAssertEqual(try repo.revisionChanges(from: merge.parents[1], to: merge.id).map(\.path), ["main.txt"])
        try write("untracked.txt", "stashed file\n"); try repo.saveStash("preview", includeUntracked: true)
        let stash = try XCTUnwrap(repo.stashes().first)
        let stashCommit = try XCTUnwrap(repo.history(reference: stash.id, limit: 1).first)
        XCTAssertEqual(stashCommit.parents.count, 3)
        let untracked = try repo.revisionChanges(from: nil, to: stashCommit.parents[2])
        XCTAssertEqual(untracked.map(\.path), ["untracked.txt"])
        XCTAssertEqual(try repo.comparison(untracked[0], from: nil, to: stashCommit.parents[2]).rows.first?.newText, "stashed file")
        XCTAssertEqual(try repo.branchRecords().count, 2)
        let blame = try repo.records(.blame, first: "main.txt", second: "HEAD")
        XCTAssertEqual(blame.first?.first, "1"); XCTAssertEqual(blame.first?.second, "main updated")
        XCTAssertEqual(blame.first?.third, "GUI Tester")
        XCTAssertFalse(try repo.records(.reflog).isEmpty)
        XCTAssertEqual(try repo.records(.worktrees).first?.first, repo.path)
        XCTAssertTrue(try repo.records(.submodules).isEmpty)
    }

    @MainActor
    func testNativeDiffPanesKeepLinesAlignedAndScrollTogether() throws {
        let old = (1...150).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "line 70\n", with: "changed line 70\ninserted line\n")
        let document = try repo.compareFiles(old: FileRevision(Data(old.utf8)), new: FileRevision(Data(new.utf8)), path: "scroll.txt", oldTitle: "before", newTitle: "after")
        let view = DiffPanesView(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        view.layoutSubtreeIfNeeded()
        view.display(document, row: 0, navigation: 0)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.oldText.isEditable); XCTAssertFalse(view.newText.isEditable)
        XCTAssertTrue(view.newText.string.contains("changed line 70\ninserted line"))
        XCTAssertEqual(view.oldText.string.components(separatedBy: "\n").count, view.newText.string.components(separatedBy: "\n").count)
        view.before.contentView.scroll(to: NSPoint(x: 0, y: 800))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: view.before.contentView)
        XCTAssertEqual(view.before.contentView.bounds.minY, view.after.contentView.bounds.minY, accuracy: 1)
        XCTAssertGreaterThan(view.after.contentView.bounds.minY, 0)
        view.display(document, row: document.hunks[0], navigation: 1)
        XCTAssertGreaterThan(view.before.contentView.bounds.minY, 1000)
        XCTAssertEqual(view.before.contentView.bounds.minY, view.after.contentView.bounds.minY, accuracy: 1)
    }

    @MainActor
    func testDiffAndHistoryScreensRenderSelectableContents() async throws {
        let original = "struct Orbit {\n    let title = \"Earth\"\n    let speed = 12\n\n    func launch() {\n        print(title)\n    }\n}\n"
        try write("Orbit.swift", original); try repo.commit(["Orbit.swift"], "軌道モデルを追加")
        try write("Orbit.swift", original.replacingOccurrences(of: "12", with: "24")); try repo.commit(["Orbit.swift"], "飛行速度を調整")
        try repo.createTag("v1.0", at: "HEAD", message: "")
        try write("Orbit.swift", original.replacingOccurrences(of: "Earth", with: "Mars").replacingOccurrences(of: "12", with: "24"))
        try write("Launch.txt", "Ready for launch\n")
        let application = NSApplication.shared; application.setActivationPolicy(.regular)
        let model = Workspace()
        model.launch(LaunchRequest(action: .diff, paths: [root.path]))
        try await eventually { !model.busy }
        XCTAssertFalse(model.failed, model.status)
        // Select a single tracked file for the initial visual comparison.
        model.launch(LaunchRequest(action: .diff, paths: [root.appendingPathComponent("Orbit.swift").path]))
        try await eventually { !model.busy }
        let view = NSHostingView(rootView: ContentView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 860), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
        func panes() -> DiffPanesView? { descendants(view).compactMap { $0 as? DiffPanesView }.first }
        try await eventually { panes()?.newText.string.contains("Mars") == true }
        XCTAssertTrue(panes()?.oldText.string.contains("Earth") == true)
        try capture(view, name: "diff")
        model.selectAction(.log)
        try await eventually { panes()?.oldText.string.contains("speed = 12") == true && panes()?.newText.string.contains("speed = 24") == true }
        let table = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTableView }.first { $0.tableColumns.count == 4 })
        XCTAssertEqual(table.numberOfRows, 2)
        try capture(view, name: "log")
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await eventually { panes()?.newText.string.contains("speed = 12") == true }
        XCTAssertFalse(panes()?.oldText.string.contains("struct Orbit") == true)
        try repo.setRemote("origin", url: "https://example.invalid/space/orbit.git")
        _ = try repo.run(["update-ref", "refs/remotes/origin/main", "HEAD~1"])
        let remote = try repo.remoteOverview("origin")
        XCTAssertEqual(remote.ahead, 1); XCTAssertEqual(remote.behind, 0)
        try repo.saveStash("打ち上げ準備の途中", includeUntracked: true)
        try repo.applyStash(XCTUnwrap(repo.stashes().first).id)
        model.apply(try Snapshot(repo))
        for action in [GitAction.commit, .pull, .switchBranch, .tags, .stash, .remotes, .tools] {
            model.selectAction(action)
            try await Task.sleep(nanoseconds: 800_000_000)
            try await eventually { !model.busy }
            if [.tags, .tools].contains(action) { try await eventually { panes()?.newText.string.contains("speed = 24") == true } }
            if action == .stash { try await eventually { panes()?.newText.string.contains("Mars") == true } }
            if action == .remotes {
                try await eventually { descendants(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "https://example.invalid/space/orbit.git" } }
            }
            try capture(view, name: action.rawValue)
        }
    }
    @MainActor private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(condition(), "Timed out waiting for GUI content", file: file, line: line)
    }
    @MainActor private func capture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["GITNEBULA_PREVIEW_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
}
