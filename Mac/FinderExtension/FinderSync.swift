import Cocoa
import FinderSync

@objc(GitNebulaFinderSync)
final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = Set(["/Users", "/Volumes", "/private/tmp", "/opt"].map { URL(fileURLWithPath: $0) })
    }
    override var toolbarItemName: String { "GitNebula" }
    override var toolbarItemToolTip: String { "このフォルダで Git を操作" }
    override var toolbarItemImage: NSImage { NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "GitNebula")! }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let controller = FIFinderSyncController.default()
        // Background menus must use the clicked folder, not a stale selection.
        let urls: [URL]
        if menuKind == .contextualMenuForContainer || menuKind == .contextualMenuForSidebar {
            urls = controller.targetedURL().map { [$0] } ?? []
        } else {
            urls = controller.selectedItemURLs() ?? controller.targetedURL().map { [$0] } ?? []
        }
        guard !urls.isEmpty else { return nil }
        let menu = NSMenu(title: "GitNebula")
        let root = NSMenuItem(title: "GitNebula", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        let actions = NSMenu(title: "GitNebula")
        for action in GitAction.allCases where action != .open {
            if action == .clone || action == .workspace { actions.addItem(.separator()) }
            let item = NSMenuItem(title: action.title + "…", action: #selector(launch(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            item.representedObject = ["action": action.rawValue, "paths": urls.map(\.path)] as [String: Any]
            actions.addItem(item)
        }
        root.submenu = actions; menu.addItem(root); return menu
    }
    @objc private func launch(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? [String: Any],
              let action = request["action"] as? String, let paths = request["paths"] as? [String] else { return }
        var components = URLComponents(); components.scheme = "gitnebula"; components.host = action
        components.queryItems = paths.map { URLQueryItem(name: "path", value: $0) }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
