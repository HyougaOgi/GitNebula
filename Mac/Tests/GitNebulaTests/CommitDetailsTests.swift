import XCTest
import SwiftUI
import AppKit
@testable import GitNebula

@MainActor private final class CommitPreviewBackground: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); NSBezierPath(rect: dirtyRect).fill()
    }
}

@MainActor final class CommitDetailsTests: LocalizedTestCase {
    private func fixture() throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("commit-details-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = try GitRepository.initialize(root.path)
        try repo.setIdentity(name: "Committer Tester", email: "committer@example.invalid")
        try "base\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try repo.run(["add", "--", "file.txt"])
        _ = try repo.run(["commit", "--author=作者 テスト <author@example.invalid>", "--date=2020-03-04T05:06:07+09:00", "-m", "件名 星雲\n\n本文の一行目\n二行目\n\nReviewed-by: Reviewer <review@example.invalid>"])
        return (root, repo)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard predicate() else { XCTFail("UI did not update"); throw NSError(domain: "CommitDetailsTests", code: 1) }
    }
    private func attribute(_ element: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if element.responds(to: selector), let value = element.perform(selector)?.takeUnretainedValue() { return value }
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        let attribute = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier", "accessibilityValue": "AXValue"][name]
        guard let attribute, element.responds(to: legacy) else { return nil }
        return element.perform(legacy, with: attribute)?.takeUnretainedValue()
    }
    private func elements(_ root: Any) -> [NSObject] {
        guard let element = root as? NSObject else { return [] }
        return [element] + ((attribute(element, "accessibilityChildren") as? [Any]) ?? []).flatMap(elements)
    }
    private func element(_ root: NSView, _ id: String) -> NSObject? {
        elements(root).first { attribute($0, "accessibilityIdentifier") as? String == id }
    }
    private func value(_ root: NSView, _ id: String) -> String? {
        element(root, id).flatMap { attribute($0, "accessibilityValue") as? String }
    }
    private func press(_ element: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard element.responds(to: selector), let method = element.method(for: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method, to: Press.self)(element, selector)
    }
    private func window(_ view: NSView, height: CGFloat = 700) -> NSWindow {
        NSApplication.shared.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: height), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        window.setContentSize(NSSize(width: 1100, height: height))
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: height)
        window.makeKeyAndOrderFront(nil)
        return window
    }
    private func requireSwiftUIDisplay() async throws {
        // Probe an independent control so a missing window server or AX tree
        // cannot be mistaken for a failure in the commit inspector.
        let host = NSHostingView(rootView: Button("Display probe") {}.accessibilityIdentifier("displayProbe").frame(width: 400, height: 200))
        host.sizingOptions = []
        let window = window(host, height: 300); defer { window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        guard host.bounds.width >= 200, host.bounds.height >= 100 else {
            throw XCTSkip("SwiftUI window display unavailable: test window has zero content height")
        }
        let deadline = Date().addingTimeInterval(2)
        while element(host, "displayProbe") == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard element(host, "displayProbe") != nil else { throw XCTSkip("SwiftUI accessibility unavailable") }
    }
    func testFullMetadataAndMessageMatchStoredGitObjects() throws {
        let (_, repo) = try fixture(), record = try XCTUnwrap(repo.history().first)
        let object = try repo.run(["cat-file", "commit", record.id])
        let messageStart = try XCTUnwrap(object.range(of: "\n\n"))
        XCTAssertEqual(record.message, String(object[messageStart.upperBound...]), "Message-only copies must preserve all body lines, trailers and the terminal newline")
        XCTAssertEqual(record.author, "作者 テスト"); XCTAssertEqual(record.email, "author@example.invalid")
        XCTAssertEqual(record.date, "2020-03-04T05:06:07+09:00")
        XCTAssertEqual(record.committer, "Committer Tester"); XCTAssertEqual(record.committerEmail, "committer@example.invalid")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: record.commitDate), "Both UTC Z and numeric time-zone offsets are valid complete timestamps")
        XCTAssertNotEqual(record.commitDate, record.date)
        XCTAssertEqual(record.id.count, 40); XCTAssertTrue(object.hasPrefix("tree " + record.tree + "\n"))
        XCTAssertTrue(record.parents.isEmpty)
        XCTAssertFalse(record.detailFields.contains { $0.id == "parents" })
        for text in [record.id, record.message, record.author, record.email, record.date, record.committer, record.committerEmail, record.commitDate, record.tree] {
            XCTAssertTrue(record.detailsText.contains(text))
        }
        let main = try repo.currentBranch()
        try repo.createBranch("feature")
        try "feature".write(to: URL(fileURLWithPath: repo.path).appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try repo.commit(["feature.txt"], "feature")
        try repo.switchBranch(main)
        try "main".write(to: URL(fileURLWithPath: repo.path).appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
        try repo.commit(["main.txt"], "main")
        try repo.merge("feature")
        try repo.createTag("details-test", at: "HEAD", message: "")
        let merge = try XCTUnwrap(repo.history(limit: 1).first)
        XCTAssertEqual(merge.parents.count, 2)
        XCTAssertEqual(merge.detailFields.first { $0.id == "parents" }?.value, merge.parents.joined(separator: "\n"))
        for parent in merge.parents { XCTAssertTrue(merge.detailsText.contains(parent)); XCTAssertEqual(parent.count, 40) }
        XCTAssertTrue(merge.detailsText.contains("tag: details-test"))
    }
    func testNativePanelShowsFullTextAndEveryButtonCopiesCurrentSelection() throws {
        let (_, repo) = try fixture(), first = try XCTUnwrap(repo.history().first)
        var copied: String?
        let copy: (String) -> Bool = { copied = $0; return true }
        let panel = CommitDetailsPanel(commit: first, copy: copy)
        func children(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + children($0) } }
        func button(_ id: String) throws -> NSButton { try XCTUnwrap(children(panel).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }) }
        XCTAssertEqual(panel.hashField.stringValue, try repo.revision("HEAD"))
        XCTAssertEqual(panel.hashField.maximumNumberOfLines, 0)
        XCTAssertEqual(panel.messageView.string, first.message)
        XCTAssertTrue(panel.messageView.isSelectable); XCTAssertFalse(panel.messageView.isEditable)
        XCTAssertEqual(panel.messageView.font?.pointSize, 15)
        for field in first.detailFields {
            let prefix = ["id", "message"].contains(field.id) ? "copyCommit:" : "copyCommitField:"
            try button(prefix + field.id).performClick(nil)
            XCTAssertEqual(copied, field.value)
        }
        try button("copyCommit:all").performClick(nil); XCTAssertEqual(copied, first.detailsText)
        _ = try repo.run(["commit", "--allow-empty", "-m", "next\n\nnew body"])
        let second = try XCTUnwrap(repo.history(limit: 1).first)
        panel.update(commit: second, copy: copy, enabled: true)
        XCTAssertEqual(panel.hashField.stringValue, second.id); XCTAssertEqual(panel.messageView.string, second.message)
        for (field, expected) in [("id", second.id), ("message", second.message), ("all", second.detailsText)] {
            try button("copyCommit:" + field).performClick(nil); XCTAssertEqual(copied, expected)
        }
        panel.update(commit: second, copy: { _ in false }, enabled: true)
        try button("copyCommit:message").performClick(nil)
        XCTAssertTrue(children(panel).contains { $0.accessibilityIdentifier() == "commitCopyError" })
        if let directory = ProcessInfo.processInfo.environment["GITNEBULA_PREVIEW_DIR"] {
            panel.update(commit: first, copy: copy, enabled: true)
            let preview = CommitPreviewBackground(frame: NSRect(x: 0, y: 0, width: 1000, height: 480))
            preview.appearance = NSAppearance(named: .aqua)
            panel.frame = preview.bounds; preview.addSubview(panel)
            preview.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(panel.hashField.frame.width, 900)
            XCTAssertGreaterThan(panel.messageView.enclosingScrollView?.frame.height ?? 0, 130)
            if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
                preview.cacheDisplay(in: preview.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("commit-details.png"))
                }
            }
        }
    }
    func testEveryFieldRemainsReachableInShortWindowAndAfterResize() throws {
        let message = (1...80).map { "本文 \($0) — 長いコミットメッセージを通常のウィンドウで読む" }.joined(separator: "\n")
        let record = CommitRecord(id: String(repeating: "a", count: 64), parents: [String(repeating: "b", count: 64)], author: "作者", email: "author@example.invalid", date: "2026-10-09T00:00:00+09:00", decorations: "HEAD -> main", subject: "件名", message: message, committer: "Committer", committerEmail: "committer@example.invalid", commitDate: "2026-10-09T00:00:00+09:00", tree: String(repeating: "c", count: 64))
        let panel = CommitDetailsPanel(commit: record, copy: { _ in true })
        let background = CommitPreviewBackground(frame: NSRect(x: 0, y: 0, width: 850, height: 260))
        background.appearance = NSAppearance(named: .aqua); background.addSubview(panel)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let scroll = try XCTUnwrap(descendants(panel).compactMap { $0 as? NSScrollView }.first { $0.accessibilityIdentifier() == "commitDetailsScroll" })
        let tree = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier() == "commitField:tree" })
        for size in [NSSize(width: 850, height: 260), NSSize(width: 1050, height: 480), NSSize(width: 850, height: 210)] {
            background.setFrameSize(size); panel.frame = background.bounds
            for _ in 0..<4 { background.layoutSubtreeIfNeeded() }
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertEqual(panel.hashField.stringValue, record.id)
            XCTAssertEqual(panel.messageView.string, message)
            XCTAssertGreaterThan(scroll.frame.height, 70)
            XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height)
            XCTAssertLessThanOrEqual(document.frame.width, scroll.contentSize.width + 1)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            let frame = tree.convert(tree.bounds, to: scroll.contentView)
            XCTAssertTrue(scroll.contentView.bounds.intersects(frame), "The last field must be reachable by scrolling at \(size)")
            XCTAssertLessThanOrEqual(scroll.frame.maxY, panel.bounds.height)
        }
        if let directory = ProcessInfo.processInfo.environment["GITNEBULA_PREVIEW_DIR"], let bitmap = background.bitmapImageRepForCachingDisplay(in: background.bounds) {
            background.cacheDisplay(in: background.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("commit-details-small.png"))
            }
        }
    }
    func testClipboardKeepsFullIDsAndMultilineMessageSeparateFromLabels() throws {
        let (_, repo) = try fixture(), record = try XCTUnwrap(repo.history().first)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CommitDetailsTests." + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.setString("probe", forType: .string), pasteboard.string(forType: .string) == "probe" else {
            throw XCTSkip("Pasteboard service unavailable")
        }
        for field in record.detailFields {
            XCTAssertTrue(CommitClipboard.copy(field.value, to: pasteboard))
            XCTAssertEqual(pasteboard.string(forType: .string), field.value)
        }
        XCTAssertTrue(CommitClipboard.copy(record.id, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), try repo.revision("HEAD"))
        XCTAssertTrue(CommitClipboard.copy(record.message, to: pasteboard))
        let object = try repo.run(["cat-file", "commit", record.id])
        let body = try XCTUnwrap(object.range(of: "\n\n"))
        XCTAssertEqual(pasteboard.string(forType: .string), String(object[body.upperBound...]))
        XCTAssertTrue(CommitClipboard.copy(record.detailsText, to: pasteboard))
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(copied.contains("コミット ID:\n" + record.id))
        XCTAssertTrue(copied.contains("メッセージ:\n" + record.message))
        XCTAssertTrue(copied.contains("作成者のメール:\nauthor@example.invalid"))
    }
    func testRootLayoutAndRetainedRoutesShrinkToNormalWindow() throws {
        let model = Workspace(), navigation = ScreenNavigation()
        model.launch(LaunchRequest(action: .open, paths: []))
        let outer = NSHostingView(rootView: ContentView(model: model, navigation: navigation))
        XCTAssertLessThanOrEqual(outer.fittingSize.width, 850, "The outer host must not retain the old 1050 px minimum")
        XCTAssertLessThanOrEqual(outer.fittingSize.height, 600, "The outer host must not retain the old 720 px minimum")
        navigation.installRoot(model, close: nil)
        let host = RetainedScreenHost()
        for size in [NSSize(width: 1100, height: 900), NSSize(width: 850, height: 600), NSSize(width: 1000, height: 700), NSSize(width: 850, height: 600)] {
            host.setFrameSize(size)
            host.display(try XCTUnwrap(navigation.current))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.active?.frame, host.bounds, "The retained route must follow both shrinking and growing")
        }
    }
    func testWholeHistoryAndGraphKeepInspectorInsideNormalWindowAfterResize() async throws {
        try await requireSwiftUIDisplay()
        let (_, repo) = try fixture(), model = Workspace(), navigation = ScreenNavigation()
        model.launch(LaunchRequest(action: .log, paths: [repo.path]))
        let root = NSHostingView(rootView: ContentView(model: model, navigation: navigation))
        root.sizingOptions = []
        let screen = window(root)
        defer { screen.close() }
        navigation.installRoot(model, close: nil)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        for action in [GitAction.log, .graph] {
            if action != .log { navigation.openAction(action) }
            try await wait { descendants(root).contains { $0 is CommitDetailsPanel } }
            for size in [NSSize(width: 1100, height: 900), NSSize(width: 850, height: 600), NSSize(width: 1000, height: 700), NSSize(width: 850, height: 600)] {
                screen.setContentSize(size)
                for _ in 0..<4 { root.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 30_000_000) }
                let panel = try XCTUnwrap(descendants(root).compactMap { $0 as? CommitDetailsPanel }.first)
                let frame = panel.convert(panel.bounds, to: root)
                XCTAssertGreaterThanOrEqual(frame.minX, -1); XCTAssertGreaterThanOrEqual(frame.minY, -1)
                XCTAssertLessThanOrEqual(frame.maxX, root.bounds.width + 1); XCTAssertLessThanOrEqual(frame.maxY, root.bounds.height + 1)
                let scroll = try XCTUnwrap(descendants(panel).compactMap { $0 as? NSScrollView }.first { $0.accessibilityIdentifier() == "commitDetailsScroll" })
                XCTAssertGreaterThan(scroll.contentSize.height, 40, "The window chrome and list must leave room to read the body")
                let document = try XCTUnwrap(scroll.documentView)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                let tree = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier() == "commitField:tree" })
                XCTAssertTrue(scroll.contentView.bounds.intersects(tree.convert(tree.bounds, to: scroll.contentView)))
            }
        }
    }
    func testCopyButtonsCopyOnlyTheirFieldOrAllAndFollowSelection() async throws {
        try await requireSwiftUIDisplay()
        let (_, repo) = try fixture(), first = try XCTUnwrap(repo.history().first)
        _ = try repo.run(["commit", "--allow-empty", "-m", "次のコミット\n\n別の本文"])
        let second = try XCTUnwrap(repo.history(limit: 1).first)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CommitDetailsTests." + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let copy: (String) -> Bool = { CommitClipboard.copy($0, to: pasteboard) }
        let host = NSHostingView(rootView: AnyView(CommitDetailsView(commit: first, copy: copy).frame(width: 1100, height: 700).background(Color(nsColor: .windowBackgroundColor))))
        host.sizingOptions = []
        let window = window(host); defer { window.close() }
        try await wait { self.value(host, "commitField:id") == first.id }
        for field in first.detailFields {
            let prefix = ["id", "message"].contains(field.id) ? "copyCommit:" : "copyCommitField:"
            let button = try XCTUnwrap(element(host, prefix + field.id))
            XCTAssertTrue(press(button))
            try await wait { pasteboard.string(forType: .string) == field.value }
        }
        XCTAssertTrue(press(try XCTUnwrap(element(host, "copyCommit:all"))))
        try await wait { pasteboard.string(forType: .string) == first.detailsText }
        host.rootView = AnyView(CommitDetailsView(commit: second, copy: copy).frame(width: 1100, height: 700).background(Color(nsColor: .windowBackgroundColor)))
        try await wait { self.value(host, "commitField:id") == second.id }
        try await wait { self.element(host, "commitCopyResult") == nil }
        for fieldID in ["id", "message", "all"] {
            XCTAssertTrue(press(try XCTUnwrap(element(host, "copyCommit:" + fieldID))))
            let expected = fieldID == "all" ? second.detailsText : fieldID == "id" ? second.id : second.message
            try await wait { pasteboard.string(forType: .string) == expected }
        }
        XCTAssertEqual(try repo.revision("HEAD"), second.id)
        XCTAssertTrue(try repo.changes().isEmpty)
    }
    func testHistoryAndOperationListSelectionShowFullDetailsAndReferenceUsesSameInspector() async throws {
        try await requireSwiftUIDisplay()
        let (_, repo) = try fixture(), first = try XCTUnwrap(repo.history().first)
        _ = try repo.run(["commit", "--allow-empty", "-m", "新しいコミット"])
        let second = try XCTUnwrap(repo.history(limit: 1).first)
        let host = NSHostingView(rootView: AnyView(HistoryBrowserView(repo: repo, branches: [try repo.currentBranch()], refreshID: UUID()).frame(width: 1100, height: 820)))
        host.sizingOptions = []
        let window = window(host, height: 820); defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func table() -> NSTableView? { descendants(host).compactMap { $0 as? NSTableView }.first { $0.tableColumns.count == 4 } }
        try await wait { self.value(host, "commitField:id") == second.id }
        let historyTable = try XCTUnwrap(table())
        historyTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await wait { self.value(host, "commitField:id") == first.id }
        XCTAssertEqual(value(host, "commitField:message"), first.message)
        XCTAssertNotNil(element(host, "copyCommit:message")); XCTAssertNotNil(element(host, "copyCommit:all"))
        for action in [GitAction.cherryPick, .revert] {
            let model = Workspace(); model.launch(LaunchRequest(action: action, paths: [repo.path]))
            try await wait { !model.busy }
            host.rootView = AnyView(CommitOperationView(model: model).frame(width: 1100, height: 820))
            try await wait { table()?.numberOfRows == 2 }
            try XCTUnwrap(table()).selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            try await wait { self.value(host, "commitField:id") == first.id }
            XCTAssertEqual(value(host, "commitField:message"), first.message)
            XCTAssertNotNil(element(host, "copyCommit:all"))
        }
        host.rootView = AnyView(CommitReferenceView(repo: repo, reference: first.id).frame(width: 1100, height: 820))
        try await wait { self.value(host, "commitField:id") == first.id }
        XCTAssertEqual(value(host, "commitField:message"), first.message)
        XCTAssertEqual(try repo.revision("HEAD"), second.id)
        XCTAssertTrue(try repo.changes().isEmpty)
    }
    func testGraphSelectionUpdatesFullDetailsWithoutLeavingGraph() async throws {
        try await requireSwiftUIDisplay()
        let (_, repo) = try fixture(), first = try XCTUnwrap(repo.history().first)
        _ = try repo.run(["commit", "--allow-empty", "-m", "グラフの新しいコミット"])
        let second = try XCTUnwrap(repo.history(limit: 1).first)
        let previousMode = UserDefaults.standard.object(forKey: "graphSpatialDisplay")
        UserDefaults.standard.set(false, forKey: "graphSpatialDisplay")
        defer {
            if let previousMode { UserDefaults.standard.set(previousMode, forKey: "graphSpatialDisplay") }
            else { UserDefaults.standard.removeObject(forKey: "graphSpatialDisplay") }
        }
        let host = NSHostingView(rootView: GitGraphView(repo: repo, refreshID: UUID()).frame(width: 1100, height: 700))
        host.sizingOptions = []
        let window = window(host); defer { window.close() }
        try await wait { self.value(host, "commitField:id") == second.id }
        XCTAssertTrue(press(try XCTUnwrap(element(host, "graphCommit:" + first.id))))
        try await wait { self.value(host, "commitField:id") == first.id }
        XCTAssertEqual(value(host, "commitField:message"), first.message)
        XCTAssertNotNil(element(host, "gitGraph"))
        XCTAssertNotNil(element(host, "copyCommit:id")); XCTAssertNotNil(element(host, "copyCommit:message"))
        XCTAssertNotNil(element(host, "copyCommit:all"))
        XCTAssertEqual(try repo.revision("HEAD"), second.id)
    }
}
