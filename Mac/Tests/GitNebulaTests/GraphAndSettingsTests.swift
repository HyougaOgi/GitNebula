import XCTest
import SwiftUI
import AppKit
@testable import GitNebula

@MainActor final class GraphAndSettingsTests: LocalizedTestCase {
    private func fixture() throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Graph " + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = try GitRepository.initialize(root.path)
        try repo.setIdentity(name: "Graph Tester", email: "graph@example.invalid")
        return (root, repo)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate())
    }
    private func capture(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["GITNEBULA_PREVIEW_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
    func testGraphPreservesTwoMergeParentsAndLaneContinuity() async throws {
        let (root, repo) = try fixture()
        try "base".write(to: root.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8); try repo.commit(["base.txt"], "base")
        let main = try repo.currentBranch()
        try repo.createBranch("feature")
        try "feature".write(to: root.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8); try repo.commit(["feature.txt"], "feature")
        try repo.switchBranch(main)
        try "main".write(to: root.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8); try repo.commit(["main.txt"], "main")
        try repo.merge("feature")
        let records = try repo.history(topological: true), rows = GitGraphLayout.rows(records)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.first?.commit.parents.count, 2)
        XCTAssertEqual(rows.first?.outgoing.map(\.to), [0, 1])
        XCTAssertTrue(rows.first?.incoming.isEmpty == true, "A branch tip has no child line above it")
        XCTAssertGreaterThan(rows.map(\.width).max() ?? 0, 1)
        for (index, row) in rows.enumerated() {
            for parent in row.commit.parents { XCTAssertGreaterThan(try XCTUnwrap(records.firstIndex { $0.id == parent }), index) }
            if index + 1 < rows.count {
                XCTAssertEqual(Set(row.outgoing.map(\.to)), Set(rows[index + 1].incoming.map(\.from)), "Lines must connect across adjacent rows")
            }
        }
        XCTAssertTrue(rows.last?.outgoing.isEmpty == true)
        XCTAssertTrue(records.contains { $0.decorations.contains("feature") })
        if ProcessInfo.processInfo.environment["GITNEBULA_PREVIEW_DIR"] != nil {
            let model = Workspace(), navigation = ScreenNavigation()
            model.launch(LaunchRequest(action: .graph, paths: [repo.path])); try await wait { !model.busy }
            let host = NSHostingView(rootView: ContentView(model: model, navigation: navigation))
            let window = NSWindow(contentRect: NSRect(x:0,y:0,width:1220,height:820), styleMask:[.titled,.closable,.resizable], backing:.buffered, defer:false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try capture(host, name: "graph-merge")
        }

    }
    func testAppearancePersistsAndRejectsInvalidStoredValues() throws {
        let suite = "AppearanceTests." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("bad", forKey: "appTheme"); defaults.set(5, forKey: "windowTransparency")
        let settings = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(settings.theme, .system); XCTAssertEqual(settings.transparency, 0.8)
        settings.theme = .light; settings.language = .en; settings.transparency = 0.45
        let saved = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(saved.theme, .light); XCTAssertEqual(saved.language, .en); XCTAssertEqual(saved.transparency, 0.45)
        XCTAssertNil(AppTheme.system.scheme); XCTAssertEqual(AppTheme.dark.scheme, .dark)
    }
    func testEnglishNeverTranslatesUserPathsOrMessages() {
        let old = UserDefaults.standard.object(forKey: "appLanguage")
        defer { if let old { UserDefaults.standard.set(old, forKey: "appLanguage") } else { UserDefaults.standard.removeObject(forKey: "appLanguage") } }
        UserDefaults.standard.set("en", forKey: "appLanguage")
        XCTAssertEqual(L("詳細設定"), "Settings")
        let path = "詳細設定/変更/日本語.txt"
        XCTAssertEqual(L("対象: \(path)"), "Target: " + path)
        XCTAssertEqual(L("\(4) コミット"), "4 commits")
        XCTAssertEqual(GitAction.graph.title, "Git Graph")
        let branch = "変更{1}", remote = "詳細設定"
        XCTAssertEqual(L("Push 完了。\(branch) を \(remote) に送信しました。"), "Push completed. Pushed " + branch + " to " + remote + ".")
    }
    func testSettingsBackReturnsToCommitAndRetainsDraft() async throws {
        let (root, repo) = try fixture()
        try "changed".write(to: root.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
        let delegate = ApplicationDelegate()
        delegate.beginLaunch(LaunchRequest(action: .commit, paths: [repo.path]))
        defer { delegate.window?.close() }
        try await wait { delegate.navigation.current?.model?.busy == false && delegate.navigation.current?.model?.action == .commit }
        let frame = try XCTUnwrap(delegate.navigation.current), model = try XCTUnwrap(frame.model)
        model.message = "keep this draft"; model.selected = ["draft.txt"]
        let originalDepth = delegate.navigation.frames.count
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("showSettings:"), to: delegate, from: nil))
        XCTAssertEqual(delegate.navigation.frames.count, originalDepth + 1)
        delegate.navigation.back()
        XCTAssertTrue(delegate.navigation.current === frame)
        XCTAssertEqual(model.message, "keep this draft"); XCTAssertEqual(model.selected, ["draft.txt"])
        delegate.navigation.home()
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("showSettings:"), to: delegate, from: nil))
        delegate.navigation.back()
        XCTAssertEqual(delegate.navigation.current?.model?.action, .open)
        delegate.navigation.back()
        XCTAssertTrue(delegate.navigation.current === frame)
        XCTAssertEqual(delegate.navigation.frames.count, originalDepth)
    }
    func testLiveLanguageAndThemePreserveCommitDraftAndNativeTable() async throws {
        let settings = AppearanceSettings.shared, defaults = UserDefaults.standard
        let keys = ["appTheme", "appLanguage", "windowTransparency"]
        let original = keys.map { defaults.object(forKey: $0) }
        let oldTheme = settings.theme, oldLanguage = settings.language, oldTransparency = settings.transparency
        defer {
            settings.theme = oldTheme; settings.language = oldLanguage; settings.transparency = oldTransparency
            for (key, value) in zip(keys, original) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
        }
        let (root, repo) = try fixture()
        try "draft".write(to: root.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
        let model = Workspace(), navigation = ScreenNavigation()
        model.launch(LaunchRequest(action: .commit, paths: [repo.path])); try await wait { !model.busy }
        let host = NSHostingView(rootView: ContentView(model: model, navigation: navigation))
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:1220,height:820), styleMask:[.titled,.closable,.resizable], backing:.buffered, defer:false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func children(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + children($0) } }
        try await wait { children(host).contains { $0 is FileTableView } }
        let table = try XCTUnwrap(children(host).compactMap { $0 as? FileTableView }.first)
        model.message = "下書きのまま"; model.selected = ["draft.txt"]
        settings.language = .en; settings.theme = .light; settings.transparency = 0.5
        try await wait { table.tableColumns.first { $0.identifier.rawValue == "status" }?.title == "Status" && window.appearance?.name == .aqua }
        try capture(host, name: "commit-light")
        XCTAssertEqual(model.message, "下書きのまま"); XCTAssertEqual(model.selected, ["draft.txt"])
        settings.theme = .dark; try await wait { window.appearance?.name == .darkAqua }
        try capture(host, name: "commit-dark")
        settings.theme = .system; try await wait { window.appearance == nil }
        settings.language = .ja; try await wait { table.tableColumns.first { $0.identifier.rawValue == "status" }?.title == "状態" }
        XCTAssertTrue(children(host).contains { $0 === table })
        XCTAssertEqual(model.message, "下書きのまま")
        navigation.openUtility(.settings)
        settings.language = .en
        try await wait { children(host).compactMap { $0 as? NSSegmentedControl }.contains { $0.segmentCount == 3 && $0.label(forSegment: 1) == "Light" } }
        navigation.back()
        settings.language = .ja
        navigation.home(); try await Task.sleep(nanoseconds: 400_000_000)
        try capture(host, name: "home-animated-1")
        try await Task.sleep(nanoseconds: 700_000_000)
        try capture(host, name: "home-animated-2")
    }
    func testPullReportsChangedHeadFilesAndNoOpThenFailure() async throws {
        let (root, source) = try fixture()
        try "initial\n".write(to: root.appendingPathComponent("orbit.txt"), atomically: true, encoding: .utf8); try source.commit(["orbit.txt"], "initial")
        let remote = root.appendingPathComponent("origin.git"), clone = root.appendingPathComponent("clone")
        _ = try source.run(["clone", "--bare", source.path, remote.path])
        let repo = try GitRepository.clone(remote.path, clone.path)
        _ = try source.run(["remote", "add", "origin", remote.path])
        try "updated\n".write(to: root.appendingPathComponent("orbit.txt"), atomically: true, encoding: .utf8); try source.commit(["orbit.txt"], "update"); try source.push("origin")
        let model = Workspace(); model.launch(LaunchRequest(action: .pull, paths: [repo.path]))
        try await wait { !model.busy }
        model.runAction(); try await wait { !model.busy }
        XCTAssertFalse(model.failed, model.status); XCTAssertTrue(model.succeeded)
        let report = try XCTUnwrap(model.transferReport)
        XCTAssertNotEqual(report.before, report.after); XCTAssertEqual(report.commits, 1); XCTAssertEqual(report.changedFiles, ["orbit.txt"])
        XCTAssertEqual(try repo.headRevision(), try source.headRevision())
        XCTAssertEqual(try String(contentsOf: clone.appendingPathComponent("orbit.txt")), "updated\n")
        model.runAction(); try await wait { !model.busy }
        XCTAssertEqual(model.transferReport?.before, model.transferReport?.after); XCTAssertEqual(model.transferReport?.commits, 0)
        XCTAssertEqual(model.status, L("Pull 完了。最新のため変更はありません。"))
        try repo.setRemote("origin", url: root.appendingPathComponent("missing.git").path)
        model.runAction(); try await wait { !model.busy }
        XCTAssertTrue(model.failed); XCTAssertFalse(model.succeeded)
        XCTAssertEqual(try repo.headRevision(), report.after)
    }
}
