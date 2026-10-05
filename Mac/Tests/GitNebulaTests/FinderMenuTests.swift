import XCTest
import AppKit
import FinderSync
@testable import GitNebula

@MainActor
final class FinderMenuTests: XCTestCase {
    @objc private func launch(_ sender: NSMenuItem) {}

    private func items(_ menu: FinderMenu, paths: [String]) throws -> [NSMenuItem] {
        let root = try XCTUnwrap(menu.makeMenu(paths: paths, target: self, selector: #selector(launch(_:))))
        return try XCTUnwrap(root.items.first?.submenu).items.filter { !$0.isSeparatorItem }
    }

    private func finderCopy(_ item: NSMenuItem) -> NSMenuItem {
        // Only the properties Finder returns, deliberately no representedObject.
        let sender = NSMenuItem(title: item.title, action: item.action, keyEquivalent: "")
        sender.tag = item.tag
        return sender
    }

    func testEveryActionSurvivesCopiedMenuSenderAndURLTransport() throws {
        let menu = FinderMenu()
        let paths = ["/repo/星雲 #?&%.txt", "/repo/space folder"]
        let items = try items(menu, paths: paths)
        let actions = GitAction.allCases.filter { $0 != .open }
        XCTAssertEqual(items.count, actions.count)
        XCTAssertEqual(Set(items.map(\.tag)).count, actions.count)
        for (item, action) in zip(items, actions) {
            let sender = finderCopy(item)
            XCTAssertNil(sender.representedObject)
            let request = try LaunchRequest.parse(menu.request(for: sender).url())
            XCTAssertEqual(request.action, action)
            XCTAssertEqual(request.paths, paths)
        }
        XCTAssertThrowsError(try menu.request(for: NSMenuItem()))
    }

    func testAnotherMenuCannotReplaceEarlierSelection() throws {
        let menu = FinderMenu()
        let first = try items(menu, paths: ["/first repo/file"])
        let second = try items(menu, paths: ["/second repo"])
        XCTAssertEqual(try menu.request(for: finderCopy(first[0])).paths, ["/first repo/file"])
        XCTAssertEqual(try menu.request(for: finderCopy(second[0])).paths, ["/second repo"])
        for index in 0..<16 { _ = try items(menu, paths: ["/repo/\(index)"]) }
        XCTAssertThrowsError(try menu.request(for: finderCopy(first[0])))
    }

    func testBackgroundSidebarAndEmptySelectionUseTarget() {
        let folder = URL(fileURLWithPath: "/repo")
        let selection = [folder.appendingPathComponent("one"), folder.appendingPathComponent("two")]
        for kind in [FIMenuKind.contextualMenuForContainer, .contextualMenuForSidebar] {
            XCTAssertEqual(FinderMenu.paths(for: kind, selected: selection, targeted: folder), [folder.path])
        }
        for kind in [FIMenuKind.contextualMenuForItems, .toolbarItemMenu] {
            XCTAssertEqual(FinderMenu.paths(for: kind, selected: selection, targeted: folder), selection.map(\.path))
            XCTAssertEqual(FinderMenu.paths(for: kind, selected: [], targeted: folder), [folder.path])
            XCTAssertEqual(FinderMenu.paths(for: kind, selected: nil, targeted: folder), [folder.path])
        }
        XCTAssertNil(FinderMenu().makeMenu(paths: [], target: self, selector: #selector(launch(_:))))
    }

    func testFinderActionsLoadTheirRepositoryAndContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Finder 星 #& " + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try GitRepository.initialize(root.path)
        try repo.setIdentity(name: "Test", email: "test@example.invalid")
        let file = root.appendingPathComponent("orbit #&.txt")
        try "initial orbit\n".write(to: file, atomically: true, encoding: .utf8)
        try repo.commit([file.lastPathComponent], "Finder history is visible")
        try "changed orbit\n".write(to: file, atomically: true, encoding: .utf8)
        let menu = FinderMenu()
        for item in try items(menu, paths: [file.path]) {
            let request = try LaunchRequest.parse(menu.request(for: finderCopy(item)).url())
            let model = Workspace()
            model.launch(request)
            let deadline = Date().addingTimeInterval(15)
            while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertFalse(model.busy, request.action.rawValue)
            XCTAssertFalse(model.failed, model.status)
            XCTAssertEqual(model.action, request.action)
            switch request.action {
            case .clone:
                XCTAssertEqual(model.cloneDestination, root.appendingPathComponent("new-repository").path)
            case .initialize:
                XCTAssertEqual(model.repositoryPath, root.path)
            default:
                XCTAssertEqual(model.repository?.path, repo.path)
                XCTAssertTrue(model.graph.contains("Finder history is visible"))
                if [.diff, .commit].contains(request.action) {
                    XCTAssertEqual(model.visibleChanges.map(\.path), [file.lastPathComponent])
                    XCTAssertEqual(try repo.comparison(XCTUnwrap(model.visibleChanges.first), from: "HEAD").rows.first?.newText, "changed orbit")
                }
            }
        }
        // Opening action dialogs must not execute mutating operations.
        XCTAssertEqual(try repo.changes().map(\.path), [file.lastPathComponent])
        XCTAssertTrue(try repo.graph().contains("Finder history is visible"))
    }
}
