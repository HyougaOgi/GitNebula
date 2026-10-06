import AppKit
import SwiftUI

@main
struct GitNebulaApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// A single app-owned window prevents URL handling and SwiftUI scenes from both
/// opening a window for the same request. Closing hides it while resident.
@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: ApplicationDelegate?
    let model = Workspace()
    let navigation = ScreenNavigation()
    private(set) var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var pendingRequests: [LaunchRequest] = []
    private var terminating = false
    private var launched = false
    let startupOptions: StartupOptions
    init(startupOptions: StartupOptions? = nil) { self.startupOptions = startupOptions ?? .shared; super.init() }
    var residentPreference: () -> Bool = { UserDefaults.standard.bool(forKey: "keepRunning") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        UserDefaults.standard.register(defaults: ["keepRunning": true, "showWelcomeOnLaunch": false])
        NSApp.setActivationPolicy(.accessory)
        let menu = NSMenu()
        let appItem = NSMenuItem(); appItem.title = "GitNebula"; menu.addItem(appItem)
        let appMenu = NSMenu(title: "GitNebula"); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "ようこそを表示", action: #selector(showHome(_:)), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "設定…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "GitNebula を終了", action: #selector(quit(_:)), keyEquivalent: "q").target = self
        let operations = NSMenuItem(title: "Git 操作", action: nil, keyEquivalent: "")
        operations.submenu = makeFunctionMenu(); menu.addItem(operations)
        let editItem = NSMenuItem(); editItem.title = "編集"; menu.addItem(editItem)
        let edit = NSMenu(title: "編集"); editItem.submenu = edit
        for (title, selector, key) in [("元に戻す", "undo:", "z"), ("切り取り", "cut:", "x"), ("コピー", "copy:", "c"), ("貼り付け", "paste:", "v"), ("すべて選択", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "GitNebula")
            button.target = self; button.action = #selector(statusClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        do {
            let request = try LaunchRequest.parse(Array(CommandLine.arguments.dropFirst()))
            beginLaunch(request)
        } catch { model.status = error.localizedDescription; model.failed = true; showHome(nil) }
        launched = true
        DispatchQueue.main.async { [weak self] in self?.drainRequests() }
    }
    func beginLaunch(_ request: LaunchRequest) {
        launched = true
        model.launch(LaunchRequest(action: .open, paths: request.action == .open ? request.paths : []))
        if request.action != .open {
            pendingRequests.append(request); drainRequests()
        } else if !request.paths.isEmpty || startupOptions.showWelcomeOnLaunch { showHome(nil) }
    }
    func ensureWindow() {
        guard window == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ようこそ — GitNebula"; window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: ContentView(model: model, closeWindow: { [weak window] in window?.performClose(nil) }, navigation: navigation))
        window.center(); self.window = window
        navigation.installRoot(model, close: { [weak window] in window?.performClose(nil) })
    }
    private func showWindow() {
        ensureWindow()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showHome(_ sender: Any?) {
        showWindow()
        if navigation.busy {
            if pendingRequests.last?.action != .open || pendingRequests.last?.paths.isEmpty != true {
                pendingRequests.append(LaunchRequest(action: .open, paths: []))
            }
            drainRequests()
        } else { navigation.home() }
    }
    @objc private func showSettings(_ sender: Any?) {
        showWindow()
        if !navigation.busy { navigation.home() }
        guard !navigation.busy else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.showSettings(nil) }
            return
        }
        navigation.openUtility(.settings)
    }
    func makeFunctionMenu() -> NSMenu {
        let menu = NSMenu(title: "Git 操作")
        menu.addItem(withTitle: "ようこそを表示", action: #selector(showHome(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        for action in GitAction.allCases where action != .open {
            if [.clone, .cherryPick, .tools].contains(action) { menu.addItem(.separator()) }
            let item = menu.addItem(withTitle: action.title + "…", action: #selector(openFunction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = action.rawValue
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        }
        menu.addItem(.separator())
        for (name, page) in [("files", UtilityPage.files), ("branches", .branches), ("conflicts", .conflicts), ("identity", .identity)] {
            let item = menu.addItem(withTitle: page.title + "…", action: #selector(openManagement(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = name
        }
        menu.addItem(withTitle: "設定…", action: #selector(showSettings(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "GitNebula を終了", action: #selector(quit(_:)), keyEquivalent: "").target = self
        return menu
    }
    func makeResidentMenu() -> NSMenu {
        startupOptions.refresh()
        let menu = NSMenu(title: "GitNebula")
        menu.addItem(withTitle: "ようこそを開く", action: #selector(showHome(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "詳細設定…", action: #selector(showSettings(_:)), keyEquivalent: "").target = self
        let options = NSMenuItem(title: "起動オプション", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "起動オプション")
        let login = submenu.addItem(withTitle: "ログイン時に自動起動", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self; login.state = startupOptions.launchAtLogin ? .on : .off
        let welcome = submenu.addItem(withTitle: "起動時にようこそ画面を開く", action: #selector(toggleWelcomeOnLaunch(_:)), keyEquivalent: "")
        welcome.target = self; welcome.state = startupOptions.showWelcomeOnLaunch ? .on : .off
        submenu.addItem(.separator())
        submenu.addItem(withTitle: "ログイン項目の設定を開く…", action: #selector(openLoginSettings(_:)), keyEquivalent: "").target = self
        options.submenu = submenu; menu.addItem(options)
        menu.addItem(.separator())
        menu.addItem(withTitle: "GitNebula を終了", action: #selector(quit(_:)), keyEquivalent: "").target = self
        return menu
    }
    @objc private func toggleWelcomeOnLaunch(_ sender: NSMenuItem) {
        startupOptions.showWelcomeOnLaunch.toggle()
        sender.state = startupOptions.showWelcomeOnLaunch ? .on : .off
    }
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        startupOptions.setLaunchAtLogin(!startupOptions.launchAtLogin)
        sender.state = startupOptions.launchAtLogin ? .on : .off
        if let message = startupOptions.message {
            let alert = NSAlert(); alert.messageText = "ログイン時の自動起動"; alert.informativeText = message
            NSApp.activate(ignoringOtherApps: true); alert.runModal()
        }
    }
    @objc private func openLoginSettings(_ sender: Any?) { startupOptions.openLoginSettings() }
    @objc private func openFunction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let action = GitAction(rawValue: name) else { return }
        pendingRequests.append(navigation.request(for: action))
        drainRequests()
    }
    @objc private func openManagement(_ sender: NSMenuItem) {
        let pages: [String: UtilityPage] = ["files": .files, "branches": .branches, "conflicts": .conflicts, "identity": .identity]
        guard let name = sender.representedObject as? String, let page = pages[name] else { return }
        openManagementWhenReady(page)
    }
    private func openManagementWhenReady(_ page: UtilityPage) {
        showWindow()
        guard !navigation.busy else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.openManagementWhenReady(page) }; return
        }
        navigation.openUtility(page)
    }
    @objc private func statusClick(_ sender: Any?) {
        if let button = statusItem?.button { makeResidentMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button) }
    }
    @objc func quit(_ sender: Any?) { NSApp.terminate(sender) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !navigation.busy else {
            showWindow()
            let alert = NSAlert(); alert.messageText = "Git の処理が完了してから終了してください。"; alert.runModal()
            return .terminateCancel
        }
        terminating = true; return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if terminating { return true }
        if residentPreference() { sender.orderOut(nil); return false }
        quit(nil); return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if startupOptions.showWelcomeOnLaunch { showHome(nil) }
        return false
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do { pendingRequests.append(try LaunchRequest.parse(url)) }
            catch { model.status = error.localizedDescription; model.failed = true }
        }
        if launched || window != nil { drainRequests() }
    }
    private func drainRequests() {
        guard !pendingRequests.isEmpty else { return }
        ensureWindow()
        navigation.installRoot(model, close: { [weak self] in self?.window?.performClose(nil) })
        guard !navigation.busy else {
            // Queue a new Finder request rather than discarding a running operation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.drainRequests() }; return
        }
        let request = pendingRequests.removeFirst()
        if request.action == .open && request.paths.isEmpty { showHome(nil) }
        else { navigation.openRequest(request); showWindow() }
        if !pendingRequests.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.drainRequests() } }
    }
}
