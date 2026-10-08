import XCTest
@testable import GitNebula

@MainActor final class RepositoryMenuTests: LocalizedTestCase {
    private func fixture() throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repository-menu-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = try GitRepository.initialize(root.path)
        try repo.setIdentity(name: "Menu Tester", email: "menu@example.invalid")
        try "base\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try repo.commit(["file.txt"], "base")
        try "working\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "other\n".write(to: root.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        return (root, repo)
    }
    private func wait(_ navigation: ScreenNavigation) async throws {
        let deadline = Date().addingTimeInterval(20)
        while navigation.busy && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(navigation.busy)
        if navigation.busy { throw NSError(domain: "RepositoryMenuTests", code: 1) }
        if let model = navigation.current?.model { XCTAssertFalse(model.failed, model.status) }
    }
    private func launcher() -> ScreenNavigation {
        let navigation = ScreenNavigation(), model = Workspace()
        model.launch(LaunchRequest(action: .open, paths: []))
        navigation.installRoot(model, close: nil)
        return navigation
    }
    func testDirectFinderRootOpensChooserAndCommitsFromWholeRepository() async throws {
        let (root, repo) = try fixture(), navigation = launcher()
        let request = LaunchRequest(action: .workspace, paths: [root.appendingPathComponent("file.txt").path], showsActionMenu: true)
        navigation.openRequest(try LaunchRequest.parse(request.url()))
        try await wait(navigation)
        XCTAssertEqual(navigation.current?.title, L("Git 操作"))
        XCTAssertTrue(navigation.current?.model?.displaysActionMenu == true)
        navigation.openAction(.commit); try await wait(navigation)
        let model = try XCTUnwrap(navigation.current?.model)
        XCTAssertEqual(Set(model.visibleChanges.map(\.path)), ["file.txt", "other.txt"])
        model.selected = ["file.txt"]; model.message = "chooser commit\n\nfull body"
        XCTAssertTrue(model.canCommit); model.commit(); try await wait(navigation)
        XCTAssertTrue(model.commitCompleted)
        XCTAssertEqual(try repo.history(limit: 1).first?.subject, "chooser commit")
        XCTAssertEqual(try repo.changes().map(\.path), ["other.txt"])
    }
    func testFinderBackShowsRepositoryActionsAndUsesWholeRepository() async throws {
        let (root, repo) = try fixture(), head = try repo.headRevision(), changes = try repo.changes()
        let navigation = launcher()
        let request = LaunchRequest(action: .diff, paths: [root.appendingPathComponent("file.txt").path])
        navigation.openRequest(try LaunchRequest.parse(request.url()))
        try await wait(navigation)
        XCTAssertEqual(navigation.current?.model?.visibleChanges.map(\.path), ["file.txt"])
        navigation.back()
        try await wait(navigation)
        let menu = try XCTUnwrap(navigation.current)
        XCTAssertEqual(menu.title, L("Git 操作"))
        XCTAssertEqual(menu.model?.repository?.path, repo.path)
        XCTAssertEqual(navigation.frames.count, 1)
        navigation.back()
        XCTAssertTrue(navigation.current === menu, "Back at the repository menu must not show the startup screen")
        for action in [GitAction.diff, .pull, .commit] {
            navigation.openAction(action)
            try await wait(navigation)
            XCTAssertEqual(navigation.current?.model?.action, action)
            XCTAssertEqual(navigation.current?.model?.repository?.path, repo.path)
            XCTAssertEqual(navigation.request(for: action).paths, [repo.path])
            if action == .diff { XCTAssertEqual(Set(navigation.current?.model?.visibleChanges.map(\.path) ?? []), ["file.txt", "other.txt"]) }
            navigation.back()
            XCTAssertTrue(navigation.current === menu)
        }
        XCTAssertEqual(try repo.headRevision(), head)
        XCTAssertEqual(try repo.changes().map(\.path), changes.map(\.path))
        XCTAssertEqual(try repo.readFile("file.txt"), "working\n")
    }
    func testDetailAndSettingsBackPreserveCommitDraftBeforeRepositoryMenu() async throws {
        let (_, repo) = try fixture(), navigation = launcher()
        navigation.openRequest(LaunchRequest(action: .commit, paths: [repo.path]))
        try await wait(navigation)
        let commit = try XCTUnwrap(navigation.current), model = try XCTUnwrap(commit.model)
        model.message = "keep this draft"; model.selected = ["file.txt"]
        navigation.openRevision(repo, reference: "HEAD", stash: false)
        navigation.back()
        XCTAssertTrue(navigation.current === commit)
        navigation.openUtility(.settings)
        navigation.back()
        XCTAssertTrue(navigation.current === commit)
        navigation.home()
        navigation.openUtility(.settings)
        navigation.back()
        XCTAssertEqual(navigation.current?.title, GitAction.open.title, "Settings must return to the screen it was opened from")
        navigation.back()
        XCTAssertTrue(navigation.current === commit)
        XCTAssertEqual(model.message, "keep this draft")
        XCTAssertEqual(model.selected, ["file.txt"])
        navigation.back()
        try await wait(navigation)
        XCTAssertEqual(navigation.current?.title, L("Git 操作"))
        XCTAssertEqual(navigation.current?.model?.repository?.path, repo.path)
    }
    func testBackKeepsPreviousOperationAndOtherRepositoryDraft() async throws {
        let (_, firstRepo) = try fixture(), (_, secondRepo) = try fixture()
        let first = launcher(), second = launcher()
        first.openRequest(LaunchRequest(action: .commit, paths: [firstRepo.path]))
        second.openRequest(LaunchRequest(action: .commit, paths: [secondRepo.path]))
        try await wait(first); try await wait(second)
        let firstCommit = try XCTUnwrap(first.current), secondCommit = try XCTUnwrap(second.current)
        firstCommit.model?.message = "first draft"; secondCommit.model?.message = "second draft"
        first.openRequest(LaunchRequest(action: .pull, paths: [firstRepo.path]))
        try await wait(first)
        first.back()
        XCTAssertTrue(first.current === firstCommit)
        XCTAssertEqual(first.current?.model?.message, "first draft")
        first.back()
        try await wait(first)
        XCTAssertEqual(first.current?.title, L("Git 操作"))
        XCTAssertEqual(first.current?.model?.repository?.path, firstRepo.path)
        XCTAssertTrue(second.current === secondCommit)
        XCTAssertEqual(second.current?.model?.message, "second draft")
    }
}
