import XCTest
import AppKit
@testable import GitNebula

@MainActor
final class MenuOperationTests: LocalizedTestCase {
    func testEveryMenuItemShowsItsOwnScreenAndReopenShowsWelcome() async throws {
        NSApplication.shared.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("menu-routes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try GitRepository.initialize(root.path)
        try repo.setIdentity(name: "Test", email: "test@example.invalid")
        try "base\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try repo.commit(["file.txt"], "base")
        try "working\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let delegate = ApplicationDelegate()
        delegate.model.launch(LaunchRequest(action: .open, paths: [root.path]))
        try await eventually { !delegate.model.busy }
        delegate.ensureWindow(); delegate.showHome(nil)
        let window = try XCTUnwrap(delegate.window)
        defer { window.delegate = nil; window.close() }
        try await eventually { window.title == "GitNebula" }
        try await eventually { self.descendants(window.contentView!).contains { ($0 as? RetainedScreenHost)?.subviews.count == 1 } }
        let homeViews = descendants(try XCTUnwrap(window.contentView))
        XCTAssertFalse(homeViews.contains { $0 is FileTableView || $0 is NSTextField && ($0 as? NSTextField)?.isEditable == true })
        XCTAssertFalse(homeViews.compactMap { $0 as? NSButton }.contains { $0.title.contains("Clone") || $0.title.contains("リポジトリを選択") })
        let menu = delegate.makeFunctionMenu()
        for action in GitAction.allCases where action != .open {
            let item = try XCTUnwrap(menu.items.first { $0.representedObject as? String == action.rawValue })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            try await eventually { delegate.navigation.current?.model?.action == action && delegate.navigation.current?.model?.busy == false }
            try await eventually { window.title == action.title + " — GitNebula" }
            let views = descendants(try XCTUnwrap(window.contentView))
            XCTAssertEqual(views.compactMap { $0 as? RetainedScreenHost }.first?.subviews.count, 1, action.rawValue)
            if ![GitAction.commit, .diff, .log].contains(action) {
                XCTAssertFalse(views.contains { $0 is FileTableView }, "\(action.rawValue) must not open the working diff list")
            }
            if [.cherryPick, .revert].contains(action) {
                let identifier = action == .cherryPick ? "executeCherryPick" : "executeRevert"
                try await eventually { self.descendants(window.contentView!).compactMap { $0 as? NSButton }.contains { $0.identifier?.rawValue == identifier } }
            }
            delegate.showHome(nil)
            try await eventually { !delegate.navigation.busy && delegate.navigation.current?.model?.action == .open }
        }
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        try await eventually { window.title == "GitNebula" }
        XCTAssertFalse(descendants(try XCTUnwrap(window.contentView)).contains { $0 is FileTableView })
        XCTAssertEqual(try repo.readFile("file.txt"), "working\n", "Opening menus must never execute a Git operation")
    }

    func testMenuCherryPickAndRevertExecuteFromTheirOwnScreens() async throws {
        NSApplication.shared.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("menu-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try GitRepository.initialize(root.path)
        try repo.setIdentity(name: "Test", email: "test@example.invalid")
        try "base\n".write(to: root.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try repo.commit(["base.txt"], "base")
        try repo.createBranch("feature")
        try "picked\n".write(to: root.appendingPathComponent("picked.txt"), atomically: true, encoding: .utf8)
        try repo.commit(["picked.txt"], "take this change")
        let sourceID = try repo.revision("HEAD")
        try repo.switchBranch("main")
        let delegate = ApplicationDelegate()
        delegate.model.launch(LaunchRequest(action: .open, paths: [root.path]))
        try await eventually { !delegate.model.busy }
        delegate.ensureWindow(); delegate.showHome(nil)
        let window = try XCTUnwrap(delegate.window)
        defer { window.delegate = nil; window.close() }
        for (action, id) in [(GitAction.cherryPick, sourceID), (.revert, sourceID)] {
            let menu = delegate.makeFunctionMenu()
            let item = try XCTUnwrap(menu.items.first { $0.representedObject as? String == action.rawValue })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            try await eventually { delegate.navigation.current?.model?.action == action && delegate.navigation.current?.model?.busy == false }
            let records = try repo.history()
            try await eventually {
                self.descendants(window.contentView!).compactMap { $0 as? NSTableView }.contains { $0.numberOfRows == records.count }
            }
            let table = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSTableView }.first { $0.numberOfRows == records.count })
            let row = try XCTUnwrap(records.firstIndex { $0.id == id })
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let identifier = action == .cherryPick ? "executeCherryPick" : "executeRevert"
            try await eventually { self.descendants(window.contentView!).compactMap { $0 as? NSButton }.contains { $0.identifier?.rawValue == identifier && $0.isEnabled } }
            let button = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == identifier })
            var confirmed = false
            let confirmationDeadline = Date().addingTimeInterval(10)
            let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if Date() > confirmationDeadline { NSApp.abortModal(); return }
                    func children(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + children($0) } }
                    guard let content = NSApp.modalWindow?.contentView,
                          let accept = children(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "実行" }) else { return }
                    confirmed = true; accept.performClick(nil)
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            RunLoop.main.add(timer, forMode: .common)
            button.performClick(nil)
            timer.invalidate()
            XCTAssertTrue(confirmed, "The operation must go through its confirmation button")
            let model = try XCTUnwrap(delegate.navigation.current?.model)
            try await eventually { !model.busy }
            XCTAssertFalse(model.failed, model.status)
            XCTAssertTrue(model.status.contains(action == .cherryPick ? "Cherry-pick が完了" : "Revert が完了"))
            XCTAssertEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent("picked.txt").path), action == .cherryPick)
            XCTAssertFalse(descendants(window.contentView!).contains { $0 is FileTableView }, "Executing history operations must keep their own screen")
            delegate.showHome(nil)
            try await eventually { !delegate.navigation.busy }
        }
        XCTAssertTrue(try repo.history().contains { $0.subject.hasPrefix("Revert") })
        XCTAssertTrue(try repo.changes().isEmpty)
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(condition(), "Timed out waiting for the menu's requested screen", file: file, line: line)
        if !condition() { throw NSError(domain: "MenuOperationTests", code: 1) }
    }
}
