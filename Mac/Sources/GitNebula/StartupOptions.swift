import Foundation
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

@MainActor
struct SystemLoginItemService: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class StartupOptions: ObservableObject {
    static let shared = StartupOptions()
    private let defaults: UserDefaults
    private let loginService: any LoginItemService
    @Published var showWelcomeOnLaunch: Bool {
        didSet { defaults.set(showWelcomeOnLaunch, forKey: "showWelcomeOnLaunch") }
    }
    @Published private(set) var loginStatus: SMAppService.Status
    @Published private(set) var message: String?
    var launchAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    init(defaults: UserDefaults = .standard, loginService: (any LoginItemService)? = nil) {
        let loginService = loginService ?? SystemLoginItemService()
        self.defaults = defaults; self.loginService = loginService
        showWelcomeOnLaunch = defaults.bool(forKey: "showWelcomeOnLaunch")
        loginStatus = loginService.status
    }
    func refresh() { loginStatus = loginService.status }
    func setLaunchAtLogin(_ enabled: Bool) {
        message = nil; refresh()
        do {
            if enabled && !launchAtLogin { try loginService.register() }
            else if !enabled && launchAtLogin { try loginService.unregister() }
            refresh()
            if loginStatus == .requiresApproval { message = "システム設定の「ログイン項目」で GitNebula を許可してください。" }
        } catch {
            refresh(); message = "ログイン時の自動起動を変更できませんでした。\n" + error.localizedDescription
        }
    }
    func openLoginSettings() { loginService.openSettings() }
}
