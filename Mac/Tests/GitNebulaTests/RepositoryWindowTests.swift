import XCTest
import AppKit
import SwiftUI
import SceneKit
@testable import GitNebula

@MainActor
final class RepositoryWindowTests: LocalizedTestCase {
    private func fixture() throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repository-window-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = try GitRepository.initialize(root.path)
        try repo.setIdentity(name: "Window Tester", email: "window@example.invalid")
        try "base\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try repo.commit(["file.txt"], "base")
        return (root, repo)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertTrue(condition(), "Timed out waiting for the repository window")
        if !condition() { throw NSError(domain: "RepositoryWindowTests", code: 1) }
    }
    func testOtherRepositoryOpensWhileFirstWindowIsBusyAndPreservesDraft() async throws {
        let (firstRoot, firstRepo) = try fixture(), (_, secondRepo) = try fixture()
        try "working\n".write(to: firstRoot.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let delegate = ApplicationDelegate()
        delegate.beginLaunch(LaunchRequest(action: .open, paths: []))
        defer { for window in delegate.windows { window.delegate = nil; window.close() } }
        let firstRequest = LaunchRequest(action: .commit, paths: [firstRepo.path])
        delegate.application(NSApp, open: [try firstRequest.url()])
        try await wait { delegate.navigation.current?.model?.repository?.path == firstRepo.path && !delegate.navigation.busy }
        let firstWindow = try XCTUnwrap(delegate.window), navigation = delegate.navigation
        let draft = try XCTUnwrap(navigation.current?.model)
        draft.message = "keep this draft"; draft.selected = ["file.txt"]
        let frame = try XCTUnwrap(navigation.current)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        draft.perform({ gate.wait(); return true }) { _ in }
        delegate.application(NSApp, open: [try LaunchRequest(action: .graph, paths: [secondRepo.path]).url()])
        try await wait { delegate.windows.count == 2 && delegate.navigation.current?.model?.repository?.path == secondRepo.path && !delegate.navigation.busy }
        let secondWindow = try XCTUnwrap(delegate.window)
        XCTAssertFalse(firstWindow === secondWindow)
        XCTAssertTrue(firstWindow.isVisible && secondWindow.isVisible)
        XCTAssertTrue(navigation.current === frame)
        XCTAssertEqual(draft.message, "keep this draft"); XCTAssertEqual(draft.selected, ["file.txt"])
        XCTAssertEqual(firstWindow.title, "Commit — GitNebula")
        XCTAssertEqual(secondWindow.title, "Git グラフ — GitNebula")
        XCTAssertTrue(draft.busy, "The second repository must not wait for the first")
        delegate.application(NSApp, open: [try LaunchRequest(action: .pull, paths: [secondRepo.path]).url()])
        try await wait { delegate.navigation.current?.model?.action == .pull && !delegate.navigation.busy }
        XCTAssertFalse(delegate.window === secondWindow, "Repository work must preserve the graph window")
        XCTAssertEqual(secondWindow.title, "Git グラフ — GitNebula")
        XCTAssertTrue(navigation.current === frame)
        gate.signal(); try await wait { !draft.busy }
        delegate.application(NSApp, open: [try firstRequest.url()])
        try await wait { delegate.window === firstWindow && !delegate.navigation.busy }
        XCTAssertEqual(delegate.windows.count, 3)
        XCTAssertTrue(delegate.navigation.current === frame)
        XCTAssertEqual(draft.message, "keep this draft"); XCTAssertEqual(draft.selected, ["file.txt"])
        XCTAssertEqual(try firstRepo.readFile("file.txt"), "working\n")
    }
    func testMissingGitHistoryIsExplainedWithoutCreatingARepository() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("no-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try GitRepository.open(root.path)) { XCTAssertTrue($0 is MissingGitRepository) }
        let model = Workspace(); model.launch(LaunchRequest(action: .graph, paths: [root.path]))
        try await wait { !model.busy }
        XCTAssertTrue(model.failed && model.missingRepository)
        XCTAssertTrue(model.status.contains("Clone"))
        XCTAssertNil(model.repository)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
    }
    func testNebulaSceneKeepsRealMergeEdgesAndTimelineVisibility() async throws {
        let (root, repo) = try fixture(), main = try repo.currentBranch()
        for index in 0..<3 {
            try repo.createBranch("feature-\(index)")
            let feature = "feature-\(index).txt", mainFile = "main-\(index).txt"
            try "feature\n".write(to: root.appendingPathComponent(feature), atomically: true, encoding: .utf8)
            try repo.commit([feature], "feature \(index)")
            try repo.switchBranch(main)
            try "main\n".write(to: root.appendingPathComponent(mainFile), atomically: true, encoding: .utf8)
            try repo.commit([mainFile], "main \(index)"); try repo.merge("feature-\(index)")
        }
        let records = try repo.history(topological: true), rows = GitGraphLayout.rows(records)
        var selected: String?
        let binding = Binding<String?>(get: { selected }, set: { selected = $0 })
        let host = NSHostingView(rootView: NebulaGraphScene(rows: rows, visibleCount: rows.count, selection: binding, cameraReset: 0))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 550), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        try await wait { descendants(host).contains { $0 is NebulaGraphScene.GraphView } }
        let view = try XCTUnwrap(descendants(host).compactMap { $0 as? NebulaGraphScene.GraphView }.first)
        try await wait { view.scene?.rootNode.childNodes.filter { $0.name?.hasPrefix("branch:") == true }.count == NebulaBranch.group(rows).count }
        let nodes = try XCTUnwrap(view.scene).rootNode.childNodes
        let branches = NebulaBranch.group(rows), links = NebulaBranchLink.links(branches)
        let stars = nodes.filter { $0.name?.hasPrefix("branch:") == true }
        XCTAssertEqual(stars.count, 4, "Branch logs are collected into four stars")
        XCTAssertEqual(Set(branches.flatMap { $0.rows.map(\.id) }), Set(records.map(\.id)), "Grouping must preserve every real log entry")
        XCTAssertEqual(Set(stars.compactMap(\.name)), Set(branches.map { "branch:" + $0.id }))
        let membership = Dictionary(uniqueKeysWithValues: branches.flatMap { b in b.rows.map { ($0.id, b.id) } })
        let expected = Set(records.flatMap { child in child.parents.filter { membership[$0] != membership[child.id] }.map { child.id + ":" + $0 } })
        XCTAssertEqual(Set(links.flatMap { $0.commits.map { $0.child + ":" + $0.parent } }), expected, "Connections must come from actual fork and merge parents")
        XCTAssertEqual(nodes.filter { $0.geometry is SCNCylinder }.count, links.count)
        XCTAssertTrue(nodes.filter { $0.geometry is SCNCylinder }.allSatisfy { !$0.isHidden }, "All branch connections remain visible")
        let mainStar = try XCTUnwrap(stars.first { $0.name == "branch:0" }?.childNode(withName: "star", recursively: false))
        let mainSize = mainStar.simdScale.x
        XCTAssertGreaterThan(mainSize, try XCTUnwrap(stars.first { $0.name != "branch:0" }?.childNode(withName: "star", recursively: false)).simdScale.x, "More commits make a larger star")
        XCTAssertNotNil(NebulaVolume.shared, "The actual GPU volume shader must compile: \(String(describing: NebulaVolume.initializationError))")
        XCTAssertTrue(nodes.first { $0.name == "nebula-volume" }?.geometry is SCNBox)
        let a = stars[1].simdPosition - stars[0].simdPosition
        let b = stars[2].simdPosition - stars[0].simdPosition
        let c = stars[3].simdPosition - stars[0].simdPosition
        XCTAssertGreaterThan(abs(simd_dot(a, simd_cross(b, c))), 0.1, "Commit stars must occupy a volume, not a plane")
        let camera = try XCTUnwrap(view.pointOfView), before = camera.simdPosition
        let source = CGEventSource(stateID: .hidSystemState)
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: 35, wheel2: 0, wheel3: 0))
        // A native wheel event must physically move the camera closer.
        let screenPoint = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        scroll.location = NSPoint(x: screenPoint.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screenPoint.y)
        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: scroll)))
        XCTAssertGreaterThan(simd_distance(before, camera.simdPosition), 0.1)
        XCTAssertLessThan(simd_distance(camera.simdPosition, view.orbitTarget), simd_length(before))
        let reverse = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: -35, wheel2: 0, wheel3: 0))
        reverse.location = scroll.location
        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: reverse)))
        XCTAssertEqual(before, camera.simdPosition, "Reverse scrolling must return to the same position exactly")
        let restored = camera.simdPosition
        view.dolly(delta: 500); view.dolly(delta: -500)
        XCTAssertEqual(restored, camera.simdPosition, "A distance limit must not discard the reversible zoom state")
        view.focusStar(try XCTUnwrap(stars.first as? NebulaGraphScene.BranchStar))
        let focused = camera.simdPosition, orientation = camera.simdOrientation.vector
        view.dolly(delta: 28); view.dolly(delta: -28)
        XCTAssertEqual(focused, camera.simdPosition, "The same invariant applies to a focused branch away from the origin")
        XCTAssertLessThan(simd_distance(orientation, camera.simdOrientation.vector), 0.000001)
        _ = view.snapshot()
        XCTAssertNil(NebulaVolume.shared?.renderError)
        view.selectCommit?(records[1].id); XCTAssertEqual(selected, records[1].id)
        host.rootView = NebulaGraphScene(rows: rows, visibleCount: 1, selection: binding, cameraReset: 0)
        try await wait { nodes.filter { $0.name?.hasPrefix("branch:") == true && !$0.isHidden }.count == 1 }
        XCTAssertEqual((nodes.first { $0.name?.hasPrefix("branch:") == true && !$0.isHidden } as? NebulaGraphScene.BranchStar)?.commitID, records.last!.id)
        XCTAssertTrue(nodes.filter { $0.geometry is SCNCylinder }.allSatisfy(\.isHidden))
        XCTAssertLessThan(mainStar.simdScale.x, mainSize, "The time axis updates a branch star's actual log count")
    }
}
