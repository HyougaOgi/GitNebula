import XCTest
import SwiftUI
import AppKit
@testable import GitNebula

@MainActor final class NativeCommitTests: LocalizedTestCase {
    private struct Harness: View {
        @ObservedObject var model: Workspace
        var body: some View {
            VStack {
                NativeCommitMessage(text: $model.message).frame(height: 76)
                GitOperationButton(title: "Commit", identifier: "executeCommit", enabled: model.canCommit, action: model.commit, keyEquivalent: "\r").fixedSize()
            }.frame(width: 700, height: 130).disabled(model.busy)
        }
    }
    func testTypingBodyAndClickingNativeButtonCreatesOnlySelectedCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-commit-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = try GitRepository.initialize(root.path)
        try repo.setIdentity(name: "Native Commit Tester", email: "commit@example.invalid")
        for name in ["selected.txt", "keep.txt"] { try "initial\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let model = Workspace(); model.launch(LaunchRequest(action: .commit, paths: [root.path]))
        try await wait { !model.busy }
        model.selected = ["selected.txt"]
        let host = NSHostingView(rootView: Harness(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 170), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func children(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + children($0) } }
        try await wait { children(host).contains { $0 is NSTextView } && children(host).contains { ($0 as? NSButton)?.identifier?.rawValue == "executeCommit" } }
        let editor = try XCTUnwrap(children(host).compactMap { $0 as? NSTextView }.first)
        let button = try XCTUnwrap(children(host).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "executeCommit" })
        XCTAssertFalse(button.isEnabled)
        let message = "subject\n\nfull body\nnext line"
        editor.insertText(message, replacementRange: NSRange(location: 0, length: 0))
        try await wait { model.message == message && button.isEnabled }
        XCTAssertEqual(button.keyEquivalent, "\r"); XCTAssertTrue(button.keyEquivalentModifierMask.contains(.command))
        button.performClick(nil)
        XCTAssertTrue(model.busy)
        try await wait { !model.busy }
        XCTAssertFalse(model.failed, model.status); XCTAssertTrue(model.commitCompleted)
        let record = try XCTUnwrap(repo.history(limit: 1).first)
        XCTAssertEqual(record.message, message + "\n")
        XCTAssertEqual(try repo.run(["ls-tree", "--name-only", "HEAD"]).trimmingCharacters(in: .newlines), "selected.txt")
        XCTAssertEqual(try repo.changes().map(\.path), ["keep.txt"])
        XCTAssertTrue(model.message.isEmpty); XCTAssertFalse(model.canCommit)

    }
    private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard predicate() else { XCTFail("Native commit input or operation did not update", file: file, line: line); throw NSError(domain: "NativeCommitTests", code: 1) }
    }
}
