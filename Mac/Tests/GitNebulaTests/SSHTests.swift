import XCTest
import SwiftUI
import AppKit
@testable import GitNebula

@MainActor
final class SSHTests: LocalizedTestCase {
    final class Secrets: SSHSecretStore {
        var values: [String: String] = [:]
        var failSave = false
        var reads = 0
        var migrationRequired = false
        func needsMigration(for key: String) -> Bool { migrationRequired }
        func read(for key: String) throws -> String? { reads += 1; return values[key] }
        func contains(key: String) throws -> Bool { values[key] != nil }
        func save(_ passphrase: String, for key: String) throws {
            if failSave { throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "store unavailable"]) }
            values[key] = passphrase
        }
        func remove(for key: String) throws { values.removeValue(forKey: key) }
    }
    private func fixture() throws -> (URL, UserDefaults, Secrets) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SSH key 星 ' " + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "GitNebulaSSHTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        return (root, defaults, Secrets())
    }
    func testSaveRetainsMaskedValueAndStoresOnlyInSecretStore() throws {
        let (root, defaults, store) = try fixture(), key = root.appendingPathComponent("id_ed25519")
        try "test private key".write(to: key, atomically: true, encoding: .utf8)
        let settings = SSHSettings(defaults: defaults, store: store)
        settings.keyPath = "\"" + key.path + "\""; settings.passphrase = "test-only passphrase"
        settings.save()
        XCTAssertFalse(settings.failed); XCTAssertEqual(settings.keyPath, key.path); XCTAssertEqual(settings.passphrase, SSHSettings.savedMask); XCTAssertTrue(settings.hasSavedPassphrase)
        XCTAssertEqual(store.values[key.path], "test-only passphrase")
        XCTAssertEqual(defaults.string(forKey: "sshKeyPath"), key.path)
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("test-only passphrase"))
        settings.save(); XCTAssertEqual(store.values[key.path], "test-only passphrase")
        XCTAssertEqual(store.reads, 0, "Opening, saving and refreshing settings never read the protected secret")
        let reopened = SSHSettings(defaults: defaults, store: store)
        XCTAssertEqual(reopened.passphrase, SSHSettings.savedMask); XCTAssertTrue(reopened.showsSavedPassphrase)
        XCTAssertEqual(store.reads, 0)
        settings.forgetPassphrase(); XCTAssertFalse(settings.failed); XCTAssertNil(store.values[key.path])
        settings.keyPath = ""; settings.save(); XCTAssertFalse(settings.failed); XCTAssertEqual(defaults.string(forKey: "sshKeyPath"), "")
    }
    func testNativeSecureFieldShiftInputAndSavedMaskReplacement() async throws {
        let (root, defaults, store) = try fixture(), key = root.appendingPathComponent("id_ed25519")
        try "test private key".write(to: key, atomically: true, encoding: .utf8)
        defaults.set(key.path, forKey: "sshKeyPath"); store.values[key.path] = "previous protected value"
        let settings = SSHSettings(defaults: defaults, store: store)
        let host = NSHostingView(rootView: NativeSecureField(text: Binding(get: { settings.passphrase }, set: { settings.passphrase = $0 }), showsSavedValue: settings.showsSavedPassphrase, placeholder: "Passphrase").frame(width: 300, height: 28).padding())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func children(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + children($0) } }
        for _ in 0..<100 where !children(host).contains(where: { $0 is NSSecureTextField }) { try await Task.sleep(nanoseconds: 20_000_000) }
        let field = try XCTUnwrap(children(host).compactMap { $0 as? NSSecureTextField }.first)
        XCTAssertEqual(field.stringValue, SSHSettings.savedMask)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        for (characters, unmodified, code) in [("A", "a", UInt16(0)), ("!", "1", UInt16(18)), ("Z", "z", UInt16(6))] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: unmodified, isARepeat: false, keyCode: code))
            editor.keyDown(with: event)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(field.stringValue, "A!Z", "Each shifted keystroke enters exactly one character")
        XCTAssertEqual(settings.passphrase, "A!Z", "Typing replaces the saved mask")
        XCTAssertEqual(store.reads, 0)
        settings.save(); XCTAssertEqual(store.values[key.path], "A!Z")
    }
    func testInvalidKeysAndStoreFailureDoNotReportSuccessOrChangeConfiguration() throws {
        let (root, defaults, store) = try fixture()
        defaults.set("/previous/key", forKey: "sshKeyPath")
        let settings = SSHSettings(defaults: defaults, store: store)
        let publicKey = root.appendingPathComponent("id_ed25519.pub")
        try "test public key".write(to: publicKey, atomically: true, encoding: .utf8)
        for path in [root.path, publicKey.path, root.appendingPathComponent("missing").path, "relative/key", ""] {
            settings.keyPath = path; settings.passphrase = "test-only passphrase"; settings.save()
            XCTAssertTrue(settings.failed, path); XCTAssertEqual(defaults.string(forKey: "sshKeyPath"), "/previous/key")
        }
        let key = root.appendingPathComponent("id_ed25519")
        try "test private key".write(to: key, atomically: true, encoding: .utf8)
        store.failSave = true; settings.keyPath = key.path; settings.save()
        XCTAssertTrue(settings.failed); XCTAssertEqual(settings.message, "store unavailable")
        XCTAssertEqual(defaults.string(forKey: "sshKeyPath"), "/previous/key"); XCTAssertTrue(store.values.isEmpty)
    }
    func testConfiguredKeyIsQuotedAndUsedWhileEmptyConfigurationPreservesExistingSSH() throws {
        let (root, _, _) = try fixture()
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_SSH_COMMAND"] = "existing ssh"
        let before = environment
        XCTAssertEqual(try SSHConfiguration(keyPath: "").configure(&environment, directory: root), [])
        XCTAssertEqual(environment, before)
        let key = root.appendingPathComponent("id ' 星 & key").path
        try "test identity".write(toFile: key, atomically: true, encoding: .utf8)
        let configuration = SSHConfiguration(keyPath: key, helperPath: "/app with spaces/GitNebula")
        let arguments = try configuration.configure(&environment, directory: root)
        XCTAssertNil(environment["GIT_SSH_COMMAND"]); XCTAssertEqual(environment["GITNEBULA_SSH_KEY"], key)
        XCTAssertEqual(environment["SSH_ASKPASS"], "/app with spaces/GitNebula")
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
        let script = try XCTUnwrap(environment["GIT_SSH"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: script)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertFalse(arguments.joined().contains(key))
        // Exercise Git's shell quoting with spaces, apostrophes and Unicode, then
        // inspect SSH's resolved identity without making a network connection.
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", String(arguments[1].dropFirst("core.sshCommand=".count)) + " -G example.invalid"]
        process.environment = environment; process.standardInput = FileHandle.nullDevice
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("identityfile " + key))
    }
    func testPassphraseCannotBeUsedForServerPasswordHostConfirmationOrOtherKey() {
        let key = "/keys/id_ed25519"
        XCTAssertTrue(SSHConfiguration.isKeyPassphrasePrompt("Enter passphrase for key '\(key)': ", keyPath: key))
        for prompt in ["git@example.invalid's password: ", "Are you sure you want to continue connecting (yes/no)?", "Enter passphrase for key '/keys/another': ", "Enter passphrase for key '/keys/id_ed25519-other': "] {
            XCTAssertFalse(SSHConfiguration.isKeyPassphrasePrompt(prompt, keyPath: key))
        }
    }
    func testLegacyMaskedValueRequiresOneTimeResaveInsteadOfReportingSuccess() throws {
        let (root, defaults, store) = try fixture(), key = root.appendingPathComponent("id_ed25519")
        try "test private key".write(to: key, atomically: true, encoding: .utf8)
        defaults.set(key.path, forKey: "sshKeyPath"); store.values[key.path] = "old saved value"; store.migrationRequired = true
        let settings = SSHSettings(defaults: defaults, store: store)
        XCTAssertTrue(settings.needsMigration); XCTAssertEqual(store.reads, 0)
        settings.save(); XCTAssertTrue(settings.failed); XCTAssertEqual(store.reads, 0)
        XCTAssertEqual(store.values[key.path], "old saved value")
    }
    func testSystemSSHStorePersistsValidatesAndDeletesWithoutAgentCache() throws {
        let (root, _, _) = try fixture(), key = root.appendingPathComponent("encrypted key 星")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", "isolated-test-067", "-f", key.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let store = SSHSystemStore(legacy: SSHKeychain(service: "GitNebulaTest." + UUID().uuidString))
        defer { try? store.remove(for: key.path) }
        XCTAssertFalse(try store.contains(key: key.path))
        XCTAssertThrowsError(try store.save("incorrect", for: key.path))
        try store.save("isolated-test-067", for: key.path)
        XCTAssertTrue(try store.contains(key: key.path))
        XCTAssertThrowsError(try store.save("incorrect", for: key.path), "An existing correct value must not hide an invalid edit")
        XCTAssertTrue(try store.contains(key: key.path))
        XCTAssertNil(try store.read(for: key.path), "GitNebula never reads Apple's protected passphrase")
        try store.remove(for: key.path)
        XCTAssertFalse(try store.contains(key: key.path))
    }
    func testEncryptedKeyCloneFetchPullPushWithInstalledAskpass() throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["GITNEBULA_SSH_TEST_FIXTURE"] else {
            throw XCTSkip("Requires an isolated local SSH fixture and the installed app's test-only Keychain entry")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let root = try XCTUnwrap(fixture["root"] as? String)
        let configuration = SSHConfiguration(keyPath: try XCTUnwrap(fixture["key"] as? String), helperPath: try XCTUnwrap(fixture["helper"] as? String), sshExecutable: try XCTUnwrap(fixture["transport"] as? String))
        let source = try XCTUnwrap(fixture["sourceURL"] as? String)
        let destination = URL(fileURLWithPath: root).appendingPathComponent("authenticated clone " + UUID().uuidString).path
        func run(_ path: String, _ arguments: [String]) throws -> String {
            String(decoding: try GitProcess.run(in: path, arguments: arguments, ssh: configuration), as: UTF8.self)
        }
        _ = try run(root, ["clone", "--", source, destination])
        XCTAssertEqual(try String(contentsOfFile: destination + "/orbit.txt"), "initial\n")
        _ = try run(destination, ["config", "user.name", "SSH Test"])
        _ = try run(destination, ["config", "user.email", "ssh-test@example.invalid"])
        try "automatic encrypted-key push\n".write(toFile: destination + "/orbit.txt", atomically: true, encoding: .utf8)
        _ = try run(destination, ["add", "--", "orbit.txt"])
        _ = try run(destination, ["commit", "-m", "encrypted SSH push"])
        _ = try run(destination, ["push", "origin", "HEAD"])
        _ = try run(destination, ["fetch", "origin"])
        _ = try run(destination, ["pull", "--ff-only", "origin", "main"])
        XCTAssertEqual(try run(destination, ["rev-parse", "HEAD"]), try run(root + "/source.git", ["rev-parse", "main"]))
    }
}
