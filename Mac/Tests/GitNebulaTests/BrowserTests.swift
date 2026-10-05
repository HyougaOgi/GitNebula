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
    func testListsNavigateToComparisonAndRestoreTheirNativeViews() async throws {
        let original = "struct Orbit {\n    let title = \"Earth\"\n    let speed = 12\n}\n"
        try write("Orbit.swift", original); try repo.commit(["Orbit.swift"], "軌道モデルを追加")
        try write("Orbit.swift", original.replacingOccurrences(of: "12", with: "24")); try repo.commit(["Orbit.swift"], "飛行速度を調整")
        try repo.createTag("v1.0", at: "HEAD", message: "")
        try write("Orbit.swift", original.replacingOccurrences(of: "Earth", with: "Mars").replacingOccurrences(of: "12", with: "24"))
        try write("Launch.txt", "Ready for launch\n")
        NSApplication.shared.setActivationPolicy(.regular)
        let model = Workspace(), navigation = ScreenNavigation()
        model.launch(LaunchRequest(action: .diff, paths: [root.path]))
        try await eventually { !model.busy }
        let view = NSHostingView(rootView: ContentView(model: model, navigation: navigation))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
        func panes() -> DiffPanesView? { descendants(view).compactMap { $0 as? DiffPanesView }.first }
        func filesTable() -> FileTableView? { descendants(view).compactMap { $0 as? FileTableView }.first }
        func openRow(_ table: FileTableView, _ row: Int) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            _ = table.target?.perform(table.doubleAction, with: table)
        }
        try await eventually { filesTable()?.numberOfRows == 2 }
        let originalTable = try XCTUnwrap(filesTable())
        XCTAssertNil(panes(), "A changed-files list must not embed file contents")
        try capture(view, name: "changes-list")
        openRow(originalTable, 1)
        try await eventually { panes()?.newText.string.contains("Mars") == true }
        XCTAssertEqual(navigation.frames.count, 2)
        XCTAssertNil(filesTable(), "The comparison must contain only a single file")
        XCTAssertTrue(panes()?.oldText.string.contains("Earth") == true)
        XCTAssertFalse(panes()?.newText.isEditable ?? true)
        try capture(view, name: "file-comparison")
        navigation.back()
        try await eventually { filesTable() === originalTable }
        XCTAssertEqual(originalTable.selectedRow, 1)
        XCTAssertNil(panes())

        navigation.openAction(.commit)
        try await eventually { navigation.current?.model?.busy == false && filesTable()?.numberOfRows == 2 }
        let commitModel = try XCTUnwrap(navigation.current?.model)
        commitModel.selected = ["Orbit.swift"]; commitModel.message = "作業途中のメッセージ"
        let commitTable = try XCTUnwrap(filesTable())
        func checks() -> [NSControl.StateValue] {
            (0..<commitTable.numberOfRows).compactMap { (commitTable.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSButton)?.state }
        }
        try await eventually { checks() == [.off, .on] }
        commitModel.selected = Set(commitModel.visibleChanges.map(\.path))
        try await eventually { checks() == [.on, .on] }
        commitModel.selected = []
        try await eventually { checks() == [.off, .off] }
        let checkbox = try XCTUnwrap(commitTable.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSButton)
        checkbox.performClick(nil)
        try await eventually { commitModel.selected == ["Orbit.swift"] && checks() == [.off, .on] }
        openRow(commitTable, 1)
        try await eventually { panes() != nil }
        navigation.back()
        try await eventually { filesTable() === commitTable }
        XCTAssertEqual(commitModel.message, "作業途中のメッセージ")
        XCTAssertEqual(commitModel.selected, ["Orbit.swift"])
        try capture(view, name: "commit-list")
        navigation.back()

        navigation.openAction(.log)
        try await eventually { filesTable()?.numberOfRows == 1 }
        XCTAssertNil(panes())
        let historyFrame = try XCTUnwrap(navigation.current)
        let historyTable = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTableView }.first { $0.tableColumns.count == 4 })
        XCTAssertEqual(historyTable.numberOfRows, 2)
        try capture(view, name: "history-list")
        let historyFiles = try XCTUnwrap(filesTable())
        openRow(historyFiles, 0)
        try await eventually { panes()?.oldText.string.contains("speed = 12") == true && panes()?.newText.string.contains("speed = 24") == true }
        navigation.back()
        try await eventually { filesTable() === historyFiles }
        XCTAssertTrue(navigation.current === historyFrame)
        XCTAssertTrue(descendants(view).contains { $0 === historyTable })
        historyTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        try await eventually { filesTable()?.numberOfRows == 1 }
        openRow(try XCTUnwrap(filesTable()), 0)
        try await eventually { panes()?.newText.string.contains("speed = 12") == true }
        XCTAssertFalse(panes()?.oldText.string.contains("struct Orbit") == true)
        navigation.back(); navigation.back()

        try repo.saveStash("打ち上げ準備の途中", includeUntracked: true)
        let stash = try XCTUnwrap(repo.stashes().first)
        model.refresh(); try await eventually { !model.busy }
        for (reference, isStash) in [("refs/tags/v1.0", false), (stash.id, true)] {
            navigation.openRevision(repo, reference: reference, stash: isStash)
            try await eventually { filesTable()?.numberOfRows == 1 }
            XCTAssertNil(panes())
            openRow(try XCTUnwrap(filesTable()), 0)
            try await eventually { panes() != nil }
            XCTAssertTrue(panes()?.newText.string.contains(isStash ? "Mars" : "speed = 24") == true)
            navigation.back(); navigation.back()
        }
        // Opening management screens never auto-executes an operation or displays comparisons.
        for action in [GitAction.stash, .tags, .remotes, .tools, .workspace, .pull, .switchBranch] {
            navigation.openAction(action)
            try await eventually { navigation.current?.model?.busy == false }
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertNil(panes(), action.rawValue)
            try capture(view, name: action.rawValue)
            navigation.back()
        }
        for page in [UtilityPage.files, .branches, .conflicts, .identity, .tool(.reflog), .tool(.listWorktrees)] {
            navigation.openUtility(page)
            try await eventually { navigation.current?.model?.busy == false }
            XCTAssertNil(panes(), page.title)
            navigation.back()
        }
        XCTAssertTrue(try repo.changes().isEmpty)
    }

    @MainActor
    func testSearchScrollDraftAndRefreshSurviveNavigation() async throws {
        try write("tracked.txt", "before\n"); try repo.commit(["tracked.txt"], "base")
        try write("tracked.txt", "after\n")
        for i in 0..<100 { try write(String(format: "file-%03d.txt", i), "new \(i)\n") }
        let model = Workspace(), navigation = ScreenNavigation()
        model.launch(LaunchRequest(action: .commit, paths: [root.path]))
        try await eventually { !model.busy }
        let view = NSHostingView(rootView: ContentView(model: model, navigation: navigation))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
        func table() -> FileTableView? { descendants(view).compactMap { $0 as? FileTableView }.first }
        try await eventually { table()?.numberOfRows == 101 }
        let list = try XCTUnwrap(table())
        let search = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "ファイルを絞り込み" })
        XCTAssertTrue(window.makeFirstResponder(search))
        let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
        editor.insertText("file-", replacementRange: editor.selectedRange())
        try await eventually { list.numberOfRows == 100 }
        list.selectRowIndexes(IndexSet(integer: 70), byExtendingSelection: false)
        list.scrollRowToVisible(70)
        let offset = try XCTUnwrap(list.enclosingScrollView).contentView.bounds.origin
        XCTAssertGreaterThan(offset.y, 0)
        model.selected = ["tracked.txt"]; model.message = "preserved draft"
        _ = list.target?.perform(list.doubleAction, with: list)
        try await eventually { descendants(view).contains { $0 is DiffPanesView } }
        navigation.back()
        try await eventually { table() === list }
        XCTAssertEqual(list.selectedRow, 70)
        XCTAssertEqual(search.stringValue, "file-")
        XCTAssertEqual(list.enclosingScrollView?.contentView.bounds.origin, offset)
        XCTAssertEqual(model.selected, ["tracked.txt"]); XCTAssertEqual(model.message, "preserved draft")
        navigation.openUtility(.files)
        try await eventually { navigation.current?.model?.busy == false }
        let manager = try XCTUnwrap(navigation.current?.model)
        manager.operation { try $0.stage(["tracked.txt"]) }
        try await eventually { !manager.busy }
        navigation.back()
        try await eventually { !model.busy && model.changes.contains { $0.path == "tracked.txt" && $0.code == "M " } }
        XCTAssertTrue(table() === list)
        XCTAssertEqual(search.stringValue, "file-"); XCTAssertEqual(model.message, "preserved draft")
        XCTAssertEqual(list.selectedRow, 70)
        model.commit(); try await eventually { !model.busy }
        XCTAssertFalse(model.failed, model.status)
        XCTAssertEqual(try repo.history(limit: 1).first?.subject, "preserved draft")
        XCTAssertEqual(try repo.changes().count, 100, "Only the checked file must be committed")
    }

    @MainActor
    func testComparisonFailureAndRapidBackNeverReplaceTheParentOrAnotherFile() async throws {
        try write("one.txt", "one before\n"); try write("two.txt", "two before\n")
        try repo.commit(["one.txt", "two.txt"], "base")
        try write("one.txt", "one after\n"); try write("two.txt", "two after\n")
        let model = Workspace(), navigation = ScreenNavigation()
        model.launch(LaunchRequest(action: .diff, paths: [root.path]))
        try await eventually { !model.busy }
        let view = NSHostingView(rootView: ContentView(model: model, navigation: navigation))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
        func panes() -> DiffPanesView? { descendants(view).compactMap { $0 as? DiffPanesView }.first }
        try await eventually { navigation.frames.count == 1 }
        let original = try XCTUnwrap(navigation.current)
        navigation.openComparison(FileComparisonRequest(repo: repo, change: try change("one.txt"), base: "missing-reference", target: nil))
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(panes())
        navigation.back()
        try await eventually { navigation.current === original }
        navigation.openComparison(FileComparisonRequest(repo: repo, change: try change("one.txt"), base: "HEAD", target: nil))
        try await Task.sleep(nanoseconds: 30_000_000)
        navigation.back()
        navigation.openComparison(FileComparisonRequest(repo: repo, change: try change("two.txt"), base: "HEAD", target: nil))
        try await eventually { panes()?.newText.string.contains("two after") == true }
        XCTAssertFalse(panes()?.newText.string.contains("one after") == true)
        XCTAssertEqual(navigation.frames.count, 2)
        navigation.back()
        try await eventually { navigation.current === original && panes() == nil }
        XCTAssertEqual(Set(try repo.changes().map(\.path)), ["one.txt", "two.txt"])
    }

    @MainActor
    func testHomeDisplaysOnlySelectedRouteAndResumesDraft() async throws {
        try write("home.txt", "base\n"); try repo.commit(["home.txt"], "base")
        try write("home.txt", "working\n")
        let model = Workspace(), navigation = ScreenNavigation()
        model.launch(LaunchRequest(action: .open, paths: []))
        let view = NSHostingView(rootView: ContentView(model: model, navigation: navigation))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
        func fileTables() -> [FileTableView] { descendants(view).compactMap { $0 as? FileTableView } }
        func hosts() -> [RetainedScreenHost] { descendants(view).compactMap { $0 as? RetainedScreenHost } }
        try await eventually { navigation.frames.count == 1 && hosts().count == 1 }
        XCTAssertTrue(fileTables().isEmpty, "Home must never display a diff list")
        try capture(view, name: "home-no-repository")
        navigation.openUtility(.settings)
        try await eventually { descendants(view).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "/usr/bin/git" } }
        XCTAssertTrue(fileTables().isEmpty, "Settings works without a repository")
        XCTAssertEqual(hosts().first?.subviews.count, 1)
        navigation.back()
        model.repositoryPath = root.path; model.openEnteredPath()
        try await eventually { !model.busy && model.repository != nil }
        XCTAssertEqual(model.action, .open); XCTAssertTrue(fileTables().isEmpty)
        try capture(view, name: "home-repository")
        navigation.openAction(.commit)
        try await eventually { navigation.current?.model?.busy == false && fileTables().count == 1 }
        let commitModel = try XCTUnwrap(navigation.current?.model), table = try XCTUnwrap(fileTables().first)
        commitModel.message = "retained draft"; commitModel.selected = ["home.txt"]
        navigation.home()
        try await eventually { navigation.current?.model?.action == .open && fileTables().isEmpty && !model.busy }
        XCTAssertEqual(hosts().first?.subviews.count, 1)
        navigation.resume()
        try await eventually { fileTables().first === table }
        XCTAssertEqual(commitModel.message, "retained draft"); XCTAssertEqual(commitModel.selected, ["home.txt"])
        navigation.home(); try await eventually { !model.busy }
        for action in GitAction.allCases.filter({ $0 != .open }) {
            navigation.openAction(action)
            try await eventually { navigation.current?.model?.busy == false }
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(hosts().first?.subviews.count, 1, action.rawValue)
            if ![GitAction.commit, .diff, .log].contains(action) { XCTAssertTrue(fileTables().isEmpty, action.rawValue) }
            navigation.back()
            try await eventually { fileTables().isEmpty }
        }
        // A context-menu request is another route in the same hosting container.
        navigation.openRequest(LaunchRequest(action: .diff, paths: [root.path]))
        try await eventually { navigation.current?.model?.busy == false && fileTables().count == 1 }
        XCTAssertEqual(hosts().first?.subviews.count, 1)
        XCTAssertFalse(descendants(view).contains { $0 is DiffPanesView })
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
