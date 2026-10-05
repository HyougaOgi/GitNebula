import XCTest
import AppKit
import SwiftUI
@testable import GitNebula

final class LaunchTests: XCTestCase {
    func testArgumentsAndScope() throws {
        let request = try LaunchRequest.parse(["--action", "commit", "--path", "/repo/日本語 file.txt", "--path", "/repo/src"])
        XCTAssertEqual(request.action, .commit)
        XCTAssertTrue(request.includes("日本語 file.txt", root: "/repo"))
        XCTAssertTrue(request.includes("src/nested/file", root: "/repo"))
        XCTAssertFalse(request.includes("src-extra/file", root: "/repo"))
        XCTAssertFalse(request.includes("other", root: "/repo"))
        XCTAssertEqual(try LaunchRequest.parse(["--open", "/repo"]).action, .open)
        XCTAssertThrowsError(try LaunchRequest.parse(["--action", "reset"]))
        XCTAssertThrowsError(try LaunchRequest.parse(["--path"]))
    }
    func testFinderURLPreservesSelection() throws {
        var url = URLComponents(); url.scheme = "gitnebula"; url.host = "diff"
        let paths = ["/repo/a #?&%.txt", "/repo/星雲"]
        url.queryItems = paths.map { URLQueryItem(name: "path", value: $0) }
        let request = try LaunchRequest.parse(url.url!)
        XCTAssertEqual(request.action, .diff); XCTAssertEqual(request.paths, paths)
        XCTAssertThrowsError(try LaunchRequest.parse(URL(string: "gitnebula://reset?path=/repo")!))
        XCTAssertThrowsError(try LaunchRequest.parse(URL(string: "https://commit?path=/repo")!))
    }
    func testTypedPathNormalizationAndNewFinderActions() throws {
        XCTAssertEqual(try LaunchRequest.inputPath(" \"~/Projects/日本語 repo\" "), NSHomeDirectory() + "/Projects/日本語 repo")
        XCTAssertEqual(try LaunchRequest.inputPath("file:///tmp/space%20repo"), "/tmp/space repo")
        XCTAssertThrowsError(try LaunchRequest.inputPath(""))
        XCTAssertThrowsError(try LaunchRequest.inputPath("relative/repo"))
        for action in GitAction.allCases {
            let url = URL(string: "gitnebula://\(action.rawValue)?path=/tmp/repo")!
            XCTAssertEqual(try LaunchRequest.parse(url).action, action)
        }
    }
    @MainActor
    func testFinderCannotReplaceCloneOrInitDraftsInTheLauncher() {
        let model = Workspace(), navigation = ScreenNavigation()
        navigation.installRoot(model, close: nil)
        XCTAssertTrue(navigation.canReuseLauncher(model))
        navigation.openAction(.clone)
        let clone = navigation.current?.model
        clone?.cloneSource = "https://example.invalid/work/repo.git"
        XCTAssertFalse(navigation.canReuseLauncher(model))
        XCTAssertEqual(clone?.cloneSource, "https://example.invalid/work/repo.git")
        navigation.back()
        XCTAssertTrue(navigation.canReuseLauncher(model))
        navigation.openAction(.initialize)
        navigation.current?.model?.repositoryPath = "/tmp/work in progress"
        XCTAssertFalse(navigation.canReuseLauncher(model))
    }

    @MainActor
    func testRepositoryPathFieldAcceptsTypingAndCanRecoverAfterInvalidPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("typed repo 星 " + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try GitRepository.initialize(root.path)
        let model = Workspace()
        model.repositoryPath = root.appendingPathComponent("missing").path
        model.openEnteredPath()
        while model.busy { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(model.failed); XCTAssertNil(model.repository)

        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let frame = NSRect(x: 0, y: 0, width: 960, height: 800)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: ContentView(model: model))
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        view.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let field = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "~/Projects/my-repo" })
        XCTAssertTrue(field.isEditable); XCTAssertTrue(field.isEnabled)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText(root.path, replacementRange: editor.selectedRange())
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(model.repositoryPath, root.path)
        model.openEnteredPath(); try await wait(model)
        XCTAssertEqual(model.repository?.path, try GitRepository.open(root.path).path)
        XCTAssertFalse(model.failed)
    }
    @MainActor
    func testFocusedCommitAndPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(path: root.path)
        _ = try repo.run(["init", "-q"]); _ = try repo.run(["config", "user.name", "Test"]); _ = try repo.run(["config", "user.email", "test@example.invalid"])
        try "initial\n".write(to: root.appendingPathComponent("orbit.txt"), atomically: true, encoding: .utf8)
        try repo.commit(["orbit.txt"], "initial")
        try "new orbit\n".write(to: root.appendingPathComponent("orbit.txt"), atomically: true, encoding: .utf8)
        try "unrelated\n".write(to: root.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        let model = Workspace()
        model.launch(LaunchRequest(action: .commit, paths: [root.appendingPathComponent("orbit.txt").path]))
        try await wait(model)
        XCTAssertEqual(model.action, .commit)
        XCTAssertEqual(model.selected, ["orbit.txt"])
        XCTAssertEqual(model.visibleChanges.map(\.path), ["orbit.txt"])
        XCTAssertEqual(try repo.comparison(XCTUnwrap(model.visibleChanges.first), from: "HEAD").rows.first?.newText, "new orbit")
        model.selectAction(.workspace)
        XCTAssertEqual(Set(model.visibleChanges.map(\.path)), ["orbit.txt", "other.txt"])
        model.selected = Set(model.visibleChanges.map(\.path))
        model.selectAction(.commit)
        XCTAssertEqual(model.selected, ["orbit.txt"])
        XCTAssertEqual(model.visibleChanges.map(\.path), ["orbit.txt"])
        if let output = ProcessInfo.processInfo.environment["GITNEBULA_PREVIEW_DIR"] {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            for action in [GitAction.commit, .open, .pull, .stash, .tags, .remotes, .tools] {
                model.selectAction(action)
                let view = NSHostingView(rootView: ContentView(model: model))
                let frame = NSRect(x: 0, y: 0, width: 960, height: 840)
                let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = view; view.frame = frame
                window.orderFront(nil)
                try await Task.sleep(nanoseconds: 250_000_000)
                try await wait(model)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(action.rawValue + ".png"))
                window.close()
            }
        }
        model.selectAction(.commit); model.message = "focused commit"; model.commit()
        try await wait(model)
        XCTAssertTrue(model.succeeded)
        XCTAssertEqual(try repo.run(["show", "HEAD:orbit.txt"]), "new orbit\n")
        XCTAssertEqual(try repo.changes().map(\.path), ["other.txt"])
        XCTAssertEqual(model.message, "")
    }
    @MainActor
    private func wait(_ model: Workspace) async throws {
        let deadline = Date().addingTimeInterval(15)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(model.busy); XCTAssertFalse(model.failed, model.status)
    }
}
