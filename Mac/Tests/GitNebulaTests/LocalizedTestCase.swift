import XCTest

// Existing behavior tests use a stable language on both developer and CI hosts.
class LocalizedTestCase: XCTestCase {
    private var previousLanguage: Any?
    override func setUpWithError() throws {
        try super.setUpWithError()
        previousLanguage = UserDefaults.standard.object(forKey: "appLanguage")
        UserDefaults.standard.set("ja", forKey: "appLanguage")
    }
    override func tearDownWithError() throws {
        if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: "appLanguage") }
        else { UserDefaults.standard.removeObject(forKey: "appLanguage") }
        try super.tearDownWithError()
    }
}
