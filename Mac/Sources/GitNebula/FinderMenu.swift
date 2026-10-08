import AppKit
import FinderSync

// Finder transports menu items across a process boundary. The action sender is
// a copy: use its integer tag, not representedObject or object identity.
final class FinderMenu {
    static var cloneHereTitle: String { L("この階層に Clone…") }
    static var cloneInSelectionTitle: String { L("選択フォルダ内に Clone…") }
    private var nextTag = 1
    private var requests: [[Int: LaunchRequest]] = []

    static func paths(for kind: FIMenuKind, selected: [URL]?, targeted: URL?) -> [String] {
        if kind == .contextualMenuForContainer || kind == .contextualMenuForSidebar {
            return targeted.map { [$0.path] } ?? []
        }
        if let selected, !selected.isEmpty { return selected.map(\.path) }
        return targeted.map { [$0.path] } ?? []
    }

    static func cloneParent(for kind: FIMenuKind, selected: [URL]?, targeted: URL?) -> String? {
        if kind == .contextualMenuForContainer || kind == .contextualMenuForSidebar { return targeted?.path }
        // Item menus select the row under the pointer, even when the user only
        // wanted the menu for the directory they are browsing (not that row).
        if let item = selected?.first { return item.deletingLastPathComponent().path }
        if kind == .contextualMenuForItems { return targeted?.deletingLastPathComponent().path }
        return targeted?.path
    }

    static func selectedCloneFolder(for kind: FIMenuKind, selected: [URL]?) -> String? {
        guard kind == .contextualMenuForItems || kind == .toolbarItemMenu,
              let selected, selected.count == 1,
              (try? selected[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return selected[0].path
    }

    func makeMenu(paths: [String], cloneParent: String? = nil, cloneIntoSelection: String? = nil, target: AnyObject, selector: Selector) -> NSMenu? {
        guard !paths.isEmpty else { return nil }
        let menu = NSMenu(title: "GitNebula")
        let root = NSMenuItem(title: "GitNebula", action: selector, keyEquivalent: "")
        root.target = target; root.tag = nextTag; nextTag += 1
        root.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        let actions = NSMenu(title: "GitNebula")
        var context: [Int: LaunchRequest] = [:]
        context[root.tag] = LaunchRequest(action: .workspace, paths: paths, showsActionMenu: true)
        func add(_ action: GitAction, title: String, paths: [String]) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = target
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            item.tag = nextTag
            context[nextTag] = LaunchRequest(action: action, paths: paths)
            nextTag += 1
            actions.addItem(item)
        }
        for (index, group) in GitAction.menuGroups.enumerated() {
            if index > 0 { actions.addItem(.separator()) }
            let heading = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            actions.addItem(heading)
            for action in group.actions {
                if action == .clone, let cloneParent {
                    add(action, title: Self.cloneHereTitle, paths: [cloneParent])
                    if let cloneIntoSelection, cloneIntoSelection != cloneParent {
                        add(action, title: Self.cloneInSelectionTitle, paths: [cloneIntoSelection])
                    }
                } else { add(action, title: action.title + "…", paths: paths) }
            }
        }
        // Keep recent menus separate so a later menu cannot change the paths
        // associated with an earlier click. Bound storage in this long-lived process.
        requests.append(context)
        if requests.count > 16 { requests.removeFirst() }
        menu.addItem(root)
        let direct = NSMenuItem(title: L("GitNebula の機能"), action: nil, keyEquivalent: "")
        direct.submenu = actions; menu.addItem(direct)
        return menu
    }

    func request(for item: NSMenuItem) throws -> LaunchRequest {
        guard let request = requests.reversed().compactMap({ $0[item.tag] }).first else {
            throw NSError(domain: "GitNebula", code: 1, userInfo: [NSLocalizedDescriptionKey:
                L("選択した操作を取得できませんでした。Finder の右クリックメニューを開き直してください。")])
        }
        return request
    }
}
