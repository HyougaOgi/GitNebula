import Cocoa
import FinderSync

@objc(GitNebulaFinderSync)
final class FinderSync: FIFinderSync {
    private let actionMenu = FinderMenu()
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = Set(["/Users", "/Volumes", "/private/tmp", "/opt"].map { URL(fileURLWithPath: $0) })
    }
    override var toolbarItemName: String { "GitNebula" }
    override var toolbarItemToolTip: String { "このフォルダで Git を操作" }
    override var toolbarItemImage: NSImage { NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "GitNebula")! }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let controller = FIFinderSyncController.default()
        let selected = controller.selectedItemURLs(), targeted = controller.targetedURL()
        let paths = FinderMenu.paths(for: menuKind, selected: selected, targeted: targeted)
        return actionMenu.makeMenu(paths: paths,
                                  cloneParent: FinderMenu.cloneParent(for: menuKind, selected: selected, targeted: targeted),
                                  cloneIntoSelection: FinderMenu.selectedCloneFolder(for: menuKind, selected: selected),
                                  target: self, selector: #selector(launch(_:)))
    }
    @objc private func launch(_ sender: NSMenuItem) {
        do {
            let url = try actionMenu.request(for: sender).url()
            // Address this extension's containing app explicitly. LaunchServices
            // may also know about old copies retained by the installer.
            let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
                if let error { DispatchQueue.main.async { self.showError(error) } }
            }
        } catch { showError(error) }
    }
    private func showError(_ error: Error) {
        NSLog("GitNebula Finder launch failed: %@", error.localizedDescription)
        let alert = NSAlert()
        alert.messageText = "GitNebula の操作を開けませんでした"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "閉じる")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
