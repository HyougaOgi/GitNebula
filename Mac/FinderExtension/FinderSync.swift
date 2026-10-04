import Cocoa
import FinderSync

@objc(GitNebulaFinderSync)
final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/Users"), URL(fileURLWithPath: "/Volumes")]
    }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let controller = FIFinderSyncController.default()
        guard controller.targetedURL() != nil || controller.selectedItemURLs()?.isEmpty == false else { return nil }
        let menu = NSMenu(title: "GitNebula")
        let item = NSMenuItem(title: "Open in GitNebula", action: #selector(openRepository), keyEquivalent: "")
        item.target = self; menu.addItem(item); return menu
    }
    @objc private func openRepository() {
        let controller = FIFinderSyncController.default()
        guard var folder = controller.selectedItemURLs()?.first ?? controller.targetedURL() else { return }
        if (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true { folder.deleteLastPathComponent() }
        var components = URLComponents(); components.scheme = "gitnebula"; components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: folder.path)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
