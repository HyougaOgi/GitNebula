import XCTest
import AppKit
@testable import GitNebula

final class ApplicationTests: LocalizedTestCase {
    @MainActor
    func testCloseReopenAndFinderUseOneWindowAndShowHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resident 星 " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try GitRepository.initialize(root.path)
        try repo.setIdentity(name: "Test", email: "test@example.invalid")
        try "base\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try repo.commit(["file.txt"], "base")
        try "working\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        NSApplication.shared.setActivationPolicy(.regular)
        let delegate = ApplicationDelegate()
        delegate.residentPreference = { true }
        delegate.ensureWindow()
        let window = try XCTUnwrap(delegate.window)
        defer { window.delegate = nil; window.close() }
        delegate.showHome(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(delegate.navigation.current?.model?.action, .open)
        delegate.application(NSApplication.shared, open: [try LaunchRequest(action: .diff, paths: [root.path]).url()])
        let deadline = Date().addingTimeInterval(20)
        while (delegate.navigation.current?.model?.action != .diff || delegate.navigation.busy) && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(delegate.window === window)
        XCTAssertEqual(delegate.navigation.current?.model?.action, .diff)
        XCTAssertEqual(delegate.navigation.current?.model?.visibleChanges.count, 1)
        let gate = DispatchSemaphore(value: 0)
        let working = try XCTUnwrap(delegate.navigation.current?.model)
        working.perform({ gate.wait(); return true }) { _ in }
        delegate.showHome(nil)
        XCTAssertEqual(delegate.navigation.current?.model?.action, .diff, "A tray click must wait for a running operation")
        gate.signal()
        let homeDeadline = Date().addingTimeInterval(20)
        while (delegate.navigation.current?.model?.action != .open || delegate.navigation.busy) && Date() < homeDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(delegate.navigation.current?.model?.action, .open)
        XCTAssertFalse(delegate.navigation.busy)
        XCTAssertTrue(delegate.window === window)
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(delegate.window === window, "Closing must retain the resident window")
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertFalse(window.isVisible, "Reopen must leave the menu-only app in the background")
        delegate.showHome(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(delegate.navigation.current?.model?.action, .open)
        XCTAssertTrue(delegate.window === window, "Reopen must not create another window")
        // Wait for queued navigation before releasing the repository.
        let refreshDeadline = Date().addingTimeInterval(20)
        while delegate.navigation.busy && Date() < refreshDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(delegate.navigation.busy)
        XCTAssertEqual(delegate.navigation.request(for: .commit).paths, [repo.path], "Home must adopt the Finder repository, including its request context")
    }
}
