import XCTest
import AppKit
import ServiceManagement
@testable import GitNebula

@MainActor
final class StartupTests: LocalizedTestCase {
    final class LoginService: LoginItemService {
        var status: SMAppService.Status = .notRegistered
        var registrations = 0, removals = 0, settingsOpened = 0
        var registrationError: Error?
        var approvalRequired = false
        func register() throws {
            registrations += 1
            if let registrationError { throw registrationError }
            status = approvalRequired ? .requiresApproval : .enabled
        }
        func unregister() throws { removals += 1; status = .notRegistered }
        func openSettings() { settingsOpened += 1 }
    }
    private func options(_ service: LoginService) -> StartupOptions {
        let suite = "GitNebulaStartupTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return StartupOptions(defaults: defaults, loginService: service)
    }
    func testMenuOnlyStartupAndResidentMenuExcludeRepositoryActions() throws {
        let service = LoginService()
        let options = options(service)
        let delegate = ApplicationDelegate(startupOptions: options)
        delegate.beginLaunch(LaunchRequest(action: .open, paths: []))
        XCTAssertNil(delegate.window)
        XCTAssertTrue(delegate.navigation.frames.isEmpty)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertNil(delegate.window)
        let menu = delegate.makeResidentMenu()
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["GitNebula を開く", "詳細設定…", "起動オプション", "GitNebula を終了"])
        let submenu = try XCTUnwrap(menu.items.first { $0.title == "起動オプション" }?.submenu)
        XCTAssertEqual(submenu.items.first?.state, .off)
        XCTAssertEqual(submenu.items[1].state, .off)
        XCTAssertEqual(service.registrations, 0)
        let settings = try XCTUnwrap(menu.items.first { $0.title == "詳細設定…" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(settings.action), to: settings.target, from: settings))
        let window = try XCTUnwrap(delegate.window)
        defer { window.delegate = nil; window.close() }
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(delegate.navigation.current?.title, "アプリの設定")
    }
    func testWelcomeStartupOptionPersistsAndControlsStartupAndReopen() throws {
        let suite = "GitNebulaStartupTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let options = StartupOptions(defaults: defaults, loginService: LoginService())
        let delegate = ApplicationDelegate(startupOptions: options)
        let submenu = try XCTUnwrap(delegate.makeResidentMenu().items.first { $0.title == "起動オプション" }?.submenu)
        let welcome = submenu.items[1]
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(welcome.action), to: welcome.target, from: welcome))
        XCTAssertTrue(options.showWelcomeOnLaunch)
        XCTAssertTrue(StartupOptions(defaults: defaults, loginService: LoginService()).showWelcomeOnLaunch)
        XCTAssertEqual(welcome.state, .on)
        delegate.beginLaunch(LaunchRequest(action: .open, paths: []))
        let window = try XCTUnwrap(delegate.window)
        defer { window.delegate = nil; window.close() }
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(delegate.navigation.current?.model?.action, .open)
        window.orderOut(nil)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(welcome.action), to: welcome.target, from: welcome))
        XCTAssertFalse(options.showWelcomeOnLaunch)
        XCTAssertFalse(StartupOptions(defaults: defaults, loginService: LoginService()).showWelcomeOnLaunch)
        XCTAssertEqual(welcome.state, .off)
    }
    func testLoginOptionRegistersUnregistersAndReportsFailureOrApproval() {
        let service = LoginService()
        let controlled = self.options(service)
        XCTAssertFalse(controlled.launchAtLogin)
        controlled.setLaunchAtLogin(true)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertTrue(controlled.launchAtLogin)
        controlled.setLaunchAtLogin(true)
        XCTAssertEqual(service.registrations, 1, "Already enabled login items must not be re-registered")
        controlled.setLaunchAtLogin(false)
        XCTAssertEqual(service.removals, 1)
        XCTAssertFalse(controlled.launchAtLogin)
        service.registrationError = NSError(domain: "StartupTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "registration failed"])
        controlled.setLaunchAtLogin(true)
        XCTAssertFalse(controlled.launchAtLogin)
        XCTAssertTrue(controlled.message?.contains("registration failed") == true)
        service.registrationError = nil; service.approvalRequired = true
        controlled.setLaunchAtLogin(true)
        XCTAssertTrue(controlled.launchAtLogin)
        XCTAssertTrue(controlled.message?.contains("許可してください") == true)
        controlled.openLoginSettings()
        XCTAssertEqual(service.settingsOpened, 1)
    }
}
