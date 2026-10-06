import XCTest
import AppKit
import FinderSync
@testable import GitNebula

@MainActor
final class FinderMenuTests: XCTestCase {
    @objc private func launch(_ sender: NSMenuItem) {}

    func testMenuGroupsContainEveryActionOnceAndMatchApplicationMenu() throws {
        XCTAssertEqual(GitAction.menuGroups.map(\.title), ["変更", "履歴", "ブランチ", "リモート", "リポジトリ"])
        XCTAssertEqual(Set(GitAction.menuActions), Set(GitAction.allCases.filter { $0 != .open }))
        XCTAssertEqual(Set(GitAction.menuActions).count, GitAction.menuActions.count)
        let finder = try XCTUnwrap(FinderMenu().makeMenu(paths: ["/repo"], target: self, selector: #selector(launch(_:)))?.items.first?.submenu)
        XCTAssertEqual(finder.items.filter(\.isSeparatorItem).count, 4)
        let application = ApplicationDelegate().makeFunctionMenu()
        XCTAssertEqual(application.items.compactMap { ($0.representedObject as? String).flatMap(GitAction.init(rawValue:)) }, GitAction.menuActions)
    }

    private func items(_ menu: FinderMenu, paths: [String], cloneParent: String? = nil, cloneIntoSelection: String? = nil) throws -> [NSMenuItem] {
        let root = try XCTUnwrap(menu.makeMenu(paths: paths, cloneParent: cloneParent, cloneIntoSelection: cloneIntoSelection, target: self, selector: #selector(launch(_:))))
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
        let actions = GitAction.menuActions
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

    func testCloneUsesContainingDirectoryAndPreservesExistingParentContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clone 星 #& " + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let source = try GitRepository.initialize(sourceFolder.path)
        try source.setIdentity(name: "Test", email: "test@example.invalid")
        try "cloned\n".write(to: URL(fileURLWithPath: source.path).appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try source.commit(["file.txt"], "clone source")
        let first = root.appendingPathComponent("first target"), second = root.appendingPathComponent("second target")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("unrelated folder"), withIntermediateDirectories: true)
            try "keep\n".write(to: folder.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        }
        let menu = FinderMenu(), model = Workspace()
        for (kind, folder) in [(FIMenuKind.contextualMenuForItems, first), (.contextualMenuForContainer, second)] {
            let selected = [folder.appendingPathComponent("unrelated folder")]
            let targeted = kind == .contextualMenuForItems ? selected[0] : folder
            let paths = FinderMenu.paths(for: kind, selected: selected, targeted: targeted)
            let parent = FinderMenu.cloneParent(for: kind, selected: selected, targeted: targeted)
            let item = try XCTUnwrap(try items(menu, paths: paths, cloneParent: parent).first { $0.title == FinderMenu.cloneHereTitle })
            model.launch(try LaunchRequest.parse(menu.request(for: finderCopy(item)).url()))
            XCTAssertEqual(model.cloneParent, folder.path)
            model.cloneParent = root.appendingPathComponent("edited draft").path
        }
        model.launch(LaunchRequest(action: .clone, paths: [second.path]))
        model.cloneSource = source.path
        let destination = second.appendingPathComponent("source")
        XCTAssertEqual(model.cloneDestination, destination.path)
        model.runAction()
        let deadline = Date().addingTimeInterval(20)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.failed, model.status)
        XCTAssertTrue(model.succeeded)
        XCTAssertEqual(model.repository?.path, try GitRepository.open(destination.path).path)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("file.txt")), "cloned\n")
        XCTAssertEqual(try String(contentsOf: second.appendingPathComponent("keep.txt")), "keep\n")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: second.appendingPathComponent("unrelated folder").path).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.appendingPathComponent(".git").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.appendingPathComponent("new-repository").path))
        model.runAction()
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(model.failed)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("file.txt")), "cloned\n")
    }

    func testCloneChoicesDoNotRedirectOtherActionsOrOlderMenus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let row = root.appendingPathComponent("other folder")
        try FileManager.default.createDirectory(at: row, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let menu = FinderMenu()
        let selected = [row]
        let parent = FinderMenu.cloneParent(for: .contextualMenuForItems, selected: selected, targeted: row)
        let selection = FinderMenu.selectedCloneFolder(for: .contextualMenuForItems, selected: selected)
        let first = try items(menu, paths: [row.path], cloneParent: parent, cloneIntoSelection: selection)
        _ = try items(menu, paths: ["/another selection"])
        for item in first {
            let request = try LaunchRequest.parse(menu.request(for: finderCopy(item)).url())
            XCTAssertEqual(request.paths, item.title == FinderMenu.cloneHereTitle ? [root.path] : [row.path])
        }
        XCTAssertTrue(first.contains { $0.title == FinderMenu.cloneInSelectionTitle })
        XCTAssertEqual(FinderMenu.cloneParent(for: .toolbarItemMenu, selected: selected, targeted: root), root.path)
        for kind in [FIMenuKind.contextualMenuForContainer, .contextualMenuForSidebar] {
            XCTAssertEqual(FinderMenu.cloneParent(for: kind, selected: selected, targeted: root), root.path)
            XCTAssertNil(FinderMenu.selectedCloneFolder(for: kind, selected: selected))
        }
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
                XCTAssertEqual(model.cloneParent, root.path)
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
