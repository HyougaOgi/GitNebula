import AppKit
import SwiftUI

@main
struct GitNebulaApp {
    @MainActor static func main() {
        if let status = SSHAskPass.runIfRequested() { exit(status) }
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Each repository retains its own window, navigation and drafts.
@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    @MainActor private final class WindowContext {
        let model = Workspace()
        let navigation = ScreenNavigation()
        var window: NSWindow?
        var requestedDirectory: String?
        var repositoryDirectory: String? {
            let directory = navigation.frames.reversed().compactMap(\.model).compactMap(\.repository).first?.path ?? model.repository?.path ?? requestedDirectory
            return directory.map(LaunchRequest.canonicalDirectory)
        }
        var busy: Bool { model.busy || navigation.busy }
    }
    static weak var shared: ApplicationDelegate?
    private let rootContext = WindowContext()
    private var repositoryContexts: [WindowContext] = []
    private weak var selectedContext: WindowContext?
    private var contexts: [WindowContext] { [rootContext] + repositoryContexts }
    private var currentContext: WindowContext {
        contexts.first { $0.window === NSApplication.shared.keyWindow && $0.window != nil } ?? selectedContext ?? rootContext
    }
    var model: Workspace { currentContext.model }
    var navigation: ScreenNavigation { currentContext.navigation }
    var window: NSWindow? { currentContext.window }
    var windows: [NSWindow] { contexts.compactMap(\.window) }
    private var statusItem: NSStatusItem?
    private var pendingRequests: [LaunchRequest] = []
    private var routingRequest = false
    private var terminating = false
    private var launched = false
    private var appearanceObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    let startupOptions: StartupOptions
    init(startupOptions: StartupOptions? = nil) { self.startupOptions = startupOptions ?? .shared; super.init() }
    var residentPreference: () -> Bool = { UserDefaults.standard.bool(forKey: "keepRunning") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        UserDefaults.standard.register(defaults: ["keepRunning": true, "showWelcomeOnLaunch": false])
        NSApp.setActivationPolicy(.accessory)
        configureMainMenu()
        appearanceObserver = NotificationCenter.default.addObserver(forName: AppearanceSettings.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configureMainMenu(); self?.publishLanguage() }
        }
        languageObserver = DistributedNotificationCenter.default().addObserver(forName: Localization.request, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishLanguage() }
        }
        publishLanguage()
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
    private func publishLanguage() {
        DistributedNotificationCenter.default().postNotificationName(Localization.changed, object: Localization.language, userInfo: nil, deliverImmediately: true)
    }
    private func configureMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); appItem.title = "GitNebula"; menu.addItem(appItem)
        let appMenu = NSMenu(title: "GitNebula"); appItem.submenu = appMenu
        appMenu.addItem(withTitle: L("GitNebula を開く"), action: #selector(showHome(_:)), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: L("詳細設定…"), action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("GitNebula を終了"), action: #selector(quit(_:)), keyEquivalent: "q").target = self
        let operations = NSMenuItem(title: L("Git 操作"), action: nil, keyEquivalent: "")
        operations.submenu = makeFunctionMenu(); menu.addItem(operations)
        let editItem = NSMenuItem(); editItem.title = L("編集"); menu.addItem(editItem)
        let edit = NSMenu(title: L("編集")); editItem.submenu = edit
        for (title, selector, key) in [(L("元に戻す"), "undo:", "z"), (L("切り取り"), "cut:", "x"), (L("コピー"), "copy:", "c"), (L("貼り付け"), "paste:", "v"), (L("すべて選択"), "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        NSApp.mainMenu = menu
    }
    func beginLaunch(_ request: LaunchRequest) {
        launched = true
        model.launch(LaunchRequest(action: .open, paths: request.action == .open ? request.paths : []))
        if request.action != .open {
            pendingRequests.append(request); drainRequests()
        } else if !request.paths.isEmpty || startupOptions.showWelcomeOnLaunch { showHome(nil) }
    }
    func ensureWindow() {
        ensureWindow(for: currentContext)
    }
    private func ensureWindow(for context: WindowContext) {
        guard context.window == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "GitNebula"; window.isOpaque = false; window.backgroundColor = .clear
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = TransparentHostingView(rootView: ContentView(model: context.model, closeWindow: { [weak window] in window?.performClose(nil) }, navigation: context.navigation))
        window.center()
        if let previous = currentContext.window, previous !== window {
            window.setFrameOrigin(NSPoint(x: previous.frame.minX + 28, y: previous.frame.minY - 28))
        }
        context.window = window
        context.navigation.installRoot(context.model, close: { [weak window] in window?.performClose(nil) })
    }
    private func showWindow() {
        showWindow(for: currentContext)
    }
    private func showWindow(for context: WindowContext) {
        ensureWindow(for: context); selectedContext = context
        if context.window?.isMiniaturized == true { context.window?.deminiaturize(nil) }
        context.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow { selectedContext = contexts.first { $0.window === window } }
    }
    @objc func showHome(_ sender: Any?) {
        let context = currentContext
        showWindow(for: context)
        showHomeWhenReady(context)
    }
    private func showHomeWhenReady(_ context: WindowContext) {
        guard !context.busy else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak context] in
                if let context { self?.showHomeWhenReady(context) }
            }
            return
        }
        showWindow(for: context); context.navigation.home()
    }
    @objc private func showSettings(_ sender: Any?) {
        showWindow()
        guard !navigation.busy else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.showSettings(nil) }
            return
        }
        navigation.openUtility(.settings)
    }
    func makeFunctionMenu() -> NSMenu {
        let menu = NSMenu(title: L("Git 操作"))
        menu.addItem(withTitle: L("GitNebula を開く"), action: #selector(showHome(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        for (index, group) in GitAction.menuGroups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            let heading = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            heading.isEnabled = false; menu.addItem(heading)
            func addAction(_ action: GitAction) {
                let item = menu.addItem(withTitle: action.title + "…", action: #selector(openFunction(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = action.rawValue
                item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            }
            for action in group.actions where action != .tags { addAction(action) }
            let pages: [(String, UtilityPage)]
            switch index {
            case 0: pages = [("files", .files)]
            case 2: pages = [("branches", .branches), ("conflicts", .conflicts)]
            case 4: pages = [("identity", .identity)]
            default: pages = []
            }
            for (name, page) in pages {
                let item = menu.addItem(withTitle: page.title + "…", action: #selector(openManagement(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = name
            }
            if group.actions.contains(.tags) { addAction(.tags) }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("詳細設定…"), action: #selector(showSettings(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("GitNebula を終了"), action: #selector(quit(_:)), keyEquivalent: "").target = self
        return menu
    }
    func makeResidentMenu() -> NSMenu {
        startupOptions.refresh()
        let menu = NSMenu(title: "GitNebula")
        menu.addItem(withTitle: L("GitNebula を開く"), action: #selector(showHome(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("詳細設定…"), action: #selector(showSettings(_:)), keyEquivalent: "").target = self
        let options = NSMenuItem(title: L("起動オプション"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: L("起動オプション"))
        let login = submenu.addItem(withTitle: L("ログイン時に自動起動"), action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self; login.state = startupOptions.launchAtLogin ? .on : .off
        let welcome = submenu.addItem(withTitle: L("起動時にアプリ画面を開く"), action: #selector(toggleWelcomeOnLaunch(_:)), keyEquivalent: "")
        welcome.target = self; welcome.state = startupOptions.showWelcomeOnLaunch ? .on : .off
        submenu.addItem(.separator())
        submenu.addItem(withTitle: L("ログイン項目の設定を開く…"), action: #selector(openLoginSettings(_:)), keyEquivalent: "").target = self
        options.submenu = submenu; menu.addItem(options)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("GitNebula を終了"), action: #selector(quit(_:)), keyEquivalent: "").target = self
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
            let alert = NSAlert(); alert.messageText = L("ログイン時の自動起動"); alert.informativeText = message
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
        if let working = contexts.first(where: \.busy) {
            showWindow(for: working)
            let alert = NSAlert(); alert.messageText = L("Git の処理が完了してから終了してください。"); alert.runModal()
            return .terminateCancel
        }
        terminating = true; return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if terminating { return true }
        if residentPreference() { sender.orderOut(nil); return false }
        if windows.contains(where: { $0 !== sender && $0.isVisible }) { sender.orderOut(nil); return false }
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
        guard !routingRequest, !pendingRequests.isEmpty else { return }
        let request = pendingRequests.removeFirst()
        if request.action == .open && request.paths.isEmpty {
            showHome(nil)
            scheduleRequests()
            return
        }
        routingRequest = true
        Task { [weak self] in
            guard let self else { return }
            let directory = request.paths.first.map(LaunchRequest.directory(for:))
            let resolved = await Task.detached { () -> String? in
                guard let directory else { return nil }
                if ![GitAction.clone, .initialize].contains(request.action), let repo = try? GitRepository.open(directory) { return repo.path }
                return LaunchRequest.canonicalDirectory(directory)
            }.value
            let context: WindowContext
            if let resolved, let existing = self.contexts.first(where: { $0.repositoryDirectory == resolved }) {
                context = existing
            } else if resolved == nil || self.currentContext.repositoryDirectory == nil && !self.currentContext.busy {
                context = self.currentContext
            } else {
                context = WindowContext(); self.repositoryContexts.append(context)
            }
            if context.busy {
                self.pendingRequests.append(request)
            } else {
                context.requestedDirectory = resolved
                self.ensureWindow(for: context)
                if let current = context.navigation.current?.model,
                   current.action == request.action && current.request(for: request.action).paths == request.paths {
                    current.refresh()
                } else { context.navigation.openRequest(request) }
                self.showWindow(for: context)
            }
            self.routingRequest = false
            self.scheduleRequests()
        }
    }
    private func scheduleRequests() {
        if !pendingRequests.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.drainRequests() } }
    }
}
