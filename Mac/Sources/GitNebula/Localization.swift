import Foundation

// Interpolated values (paths, branches and user messages) are never translated.
struct AppText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let value: String
    init(stringLiteral value: String) { self.value = Localization.text(value) }
    init(stringInterpolation: StringInterpolation) { value = stringInterpolation.value }
    struct StringInterpolation: StringInterpolationProtocol {
        private var format = ""
        private var arguments: [String] = []
        private var fallback = ""
        var value: String { Localization.render(format, arguments: arguments) ?? fallback }
        init(literalCapacity: Int, interpolationCount: Int) { }
        mutating func appendLiteral(_ literal: String) { format += literal; fallback += Localization.text(literal) }
        mutating func appendInterpolation<T>(_ value: T) {
            format += "{\(arguments.count)}"
            let text = String(describing: value)
            arguments.append(text); fallback += text
        }
    }
}
func L(_ value: AppText) -> String { value.value }
func LT(_ value: String) -> String { Localization.text(value) }
enum Localization {
    static let changed = Notification.Name("dev.gitnebula.languageChanged")
    static let request = Notification.Name("dev.gitnebula.languageRequested")
    #if FINDER_EXTENSION
    static var extensionLanguage: String?
    #endif
    static var language: String {
        #if FINDER_EXTENSION
        if let extensionLanguage { return extensionLanguage }
        #endif
        let defaults = UserDefaults(suiteName: "dev.gitnebula.desktop") ?? .standard
        let selected = UserDefaults.standard.string(forKey: "appLanguage") ?? defaults.string(forKey: "appLanguage") ?? "system"
        return selected == "system" ? (Locale.preferredLanguages.first?.hasPrefix("ja") == true ? "ja" : "en") : selected
    }
    private static let english: [String: String] = {
        var resource = Bundle.main.resourceURL?.appendingPathComponent("en.json")
        if resource.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
            #if FINDER_EXTENSION
            resource = nil
            #else
            resource = Bundle.module.url(forResource: "en", withExtension: "json")
            #endif
        }
        guard let url = resource,
              let data = try? Data(contentsOf: url), let strings = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return strings
    }()
    static func text(_ value: String) -> String {
        guard language == "en" else { return value }
        return english[value] ?? value
    }
    static func render(_ format: String, arguments: [String]) -> String? {
        guard language == "en", let template = english[format] else { return nil }
        let regex = try! NSRegularExpression(pattern: "\\{([0-9]+)\\}")
        let source = template as NSString
        var result = "", cursor = 0
        for match in regex.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            guard let index = Int(source.substring(with: match.range(at: 1))), arguments.indices.contains(index) else { return nil }
            result += arguments[index]; cursor = NSMaxRange(match.range)
        }
        return result + source.substring(from: cursor)
    }
}
