import AppKit
import FinderSync

// Finder transports menu items across a process boundary. The action sender is
// a copy: use its integer tag, not representedObject or object identity.
final class FinderMenu {
    private var nextTag = 1
    private var requests: [[Int: LaunchRequest]] = []

    static func paths(for kind: FIMenuKind, selected: [URL]?, targeted: URL?) -> [String] {
        if kind == .contextualMenuForContainer || kind == .contextualMenuForSidebar {
            return targeted.map { [$0.path] } ?? []
        }
        if let selected, !selected.isEmpty { return selected.map(\.path) }
        return targeted.map { [$0.path] } ?? []
    }

    func makeMenu(paths: [String], target: AnyObject, selector: Selector) -> NSMenu? {
        guard !paths.isEmpty else { return nil }
        let menu = NSMenu(title: "GitNebula")
        let root = NSMenuItem(title: "GitNebula", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        let actions = NSMenu(title: "GitNebula")
        var context: [Int: LaunchRequest] = [:]
        for action in GitAction.allCases where action != .open {
            if action == .clone || action == .workspace { actions.addItem(.separator()) }
            let item = NSMenuItem(title: action.title + "…", action: selector, keyEquivalent: "")
            item.target = target
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            item.tag = nextTag
            context[nextTag] = LaunchRequest(action: action, paths: paths)
            nextTag += 1
            actions.addItem(item)
        }
        // Keep recent menus separate so a later menu cannot change the paths
        // associated with an earlier click. Bound storage in this long-lived process.
        requests.append(context)
        if requests.count > 16 { requests.removeFirst() }
        root.submenu = actions
        menu.addItem(root)
        return menu
    }

    func request(for item: NSMenuItem) throws -> LaunchRequest {
        guard let request = requests.reversed().compactMap({ $0[item.tag] }).first else {
            throw NSError(domain: "GitNebula", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "選択した操作を取得できませんでした。Finder の右クリックメニューを開き直してください。"])
        }
        return request
    }
}
