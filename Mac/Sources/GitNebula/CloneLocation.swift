import Foundation

enum CloneLocation {
    static func repositoryName(for source: String) -> String {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        // Preserve existing URL escapes while encoding literal Unicode/spaces.
        // URL(string:) alone can double-encode % when both are present.
        let encodedURL = source.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(CharacterSet(charactersIn: "%#"))) ?? source
        if source.contains("://"), let url = URL(string: encodedURL) { path = url.path }
        else { path = source.replacingOccurrences(of: "\\", with: "/") }
        var name = path.split(separator: "/").last.map(String.init) ?? ""
        if !path.contains("/"), let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name == "." || name == ".." ? "" : name
    }

    static func destination(parent: String, source: String) throws -> String {
        let folder = repositoryName(for: source)
        guard !folder.isEmpty, folder != ".", folder != "..", !folder.contains("/"), !folder.contains("\\"), !folder.contains("\0") else {
            throw NSError(domain: "GitNebula", code: 1, userInfo: [NSLocalizedDescriptionKey: "取得元からリポジトリ名を取得できません。取得元の URL / パスを確認してください。"])
        }
        return URL(fileURLWithPath: try LaunchRequest.inputPath(parent)).appendingPathComponent(folder).path
    }
}
