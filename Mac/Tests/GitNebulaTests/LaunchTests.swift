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
        XCTAssertTrue(model.diff.contains("+new orbit"))
        model.selectAction(.workspace)
        XCTAssertEqual(Set(model.visibleChanges.map(\.path)), ["orbit.txt", "other.txt"])
        model.selected = Set(model.visibleChanges.map(\.path))
        model.selectAction(.commit)
        XCTAssertEqual(model.selected, ["orbit.txt"])
        XCTAssertEqual(model.visibleChanges.map(\.path), ["orbit.txt"])
        if let output = ProcessInfo.processInfo.environment["GITNEBULA_PREVIEW_DIR"] {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            for action in [GitAction.commit, .open, .pull] {
                model.selectAction(action)
                let view = NSHostingView(rootView: ContentView(model: model))
                let frame = NSRect(x: 0, y: 0, width: 900, height: action == .commit ? 700 : 560)
                let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = view; view.frame = frame
                window.orderFront(nil)
                try await Task.sleep(nanoseconds: 250_000_000)
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
