import Foundation
import Darwin

enum GitAction: String, CaseIterable, Sendable {
    case open, commit, diff, log, pull, push, fetch, switchBranch = "switch", clone, initialize = "init", stash, tags, remotes
    case cherryPick = "cherry-pick", revert, rebase, merge, tools, workspace, graph

    static var menuGroups: [(title: String, actions: [GitAction])] { [
        (L("変更"), [.commit, .diff, .stash]),
        (L("履歴"), [.log, .graph, .cherryPick, .revert]),
        (L("ブランチ"), [.switchBranch, .merge, .rebase, .tags]),
        (L("リモート"), [.fetch, .pull, .push, .remotes]),
        (L("リポジトリ"), [.clone, .initialize, .workspace, .tools])
    ] }
    static var menuActions: [GitAction] { menuGroups.flatMap(\.actions) }

    var title: String {
        switch self {
        case .open: return "GitNebula"
        case .commit: return "Commit"
        case .diff: return L("差分一覧")
        case .log: return L("履歴")
        case .graph: return L("Git グラフ")
        case .pull: return "Pull"
        case .push: return "Push"
        case .fetch: return "Fetch"
        case .switchBranch: return L("ブランチを切り替え")
        case .clone: return "Clone"
        case .initialize: return L("リポジトリを作成（Init）")
        case .stash: return "Stash"
        case .tags: return L("タグを管理")
        case .remotes: return L("リモートを設定")
        case .cherryPick: return "Cherry-pick"
        case .revert: return "Revert"
        case .rebase: return "Rebase"
        case .merge: return "Merge"
        case .tools: return L("その他の機能")
        case .workspace: return L("リポジトリの管理")
        }
    }
    var hint: String {
        switch self {
        case .open: return L("アプリの設定と起動オプションを管理します。")
        case .commit: return L("ファイルを確認して、メッセージを入力するだけ。")
        case .diff: return L("変更ファイルの一覧です。ファイルを開くと、その差分を表示します。")
        case .log: return L("コミットの一覧・説明・変更ファイルを表示します。")
        case .graph: return L("ブランチの分岐・合流とコミットを表示します。")
        case .pull: return L("リモートの変更を現在のブランチに取り込みます（fast-forward のみ）。")
        case .push: return L("現在のブランチのコミットをリモートに送信します。")
        case .fetch: return L("リモートの最新情報を取得します。作業ファイルは変更しません。")
        case .switchBranch: return L("切り替え先を選んで実行します。未コミットの変更がある場合は停止します。")
        case .clone: return L("保存先の中に、リポジトリ名のフォルダを作って複製します。")
        case .initialize: return L("選択したフォルダに新しい Git リポジトリを作成します。")
        case .stash: return L("変更を一時保存し、後で作業ツリーに戻します。")
        case .tags: return L("リリースなどの目印をコミットに付けます。")
        case .remotes: return L("取得・送信先の URL を登録・変更します。")
        case .cherryPick: return L("履歴からコミットを選び、現在のブランチに変更を取り込みます。")
        case .revert: return L("履歴からコミットを選び、変更を打ち消す新しいコミットを作ります。")
        case .rebase: return L("現在のブランチのコミットを選んだブランチの上につなぎ直します。")
        case .merge: return L("選んだブランチの変更を現在のブランチに取り込みます。")
        case .tools: return L("履歴・ファイルの確認、履歴編集、パッチ、Worktree、Submodule の専用画面を開きます。")
        case .workspace: return L("作業ファイル・ブランチ・競合解決・設定の画面を開きます。")
        }
    }
    var symbol: String {
        switch self {
        case .commit: return "checkmark.circle"
        case .diff: return "doc.text.magnifyingglass"
        case .log: return "clock.arrow.circlepath"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .pull: return "arrow.down.circle"
        case .push: return "arrow.up.circle"
        case .fetch: return "arrow.clockwise"
        case .switchBranch: return "arrow.triangle.branch"
        case .clone: return "square.on.square"
        case .initialize: return "folder.badge.plus"
        case .stash: return "archivebox"
        case .tags: return "tag"
        case .remotes: return "network"
        case .cherryPick: return "arrow.turn.down.right"
        case .revert: return "arrow.uturn.backward"
        case .rebase, .merge: return "arrow.triangle.branch"
        case .tools: return "wrench.and.screwdriver"
        default: return "sparkles"
        }
    }
}

struct LaunchRequest: Sendable {
    let action: GitAction
    let paths: [String]

    func url() throws -> URL {
        var components = URLComponents()
        components.scheme = "gitnebula"
        components.host = action.rawValue
        components.queryItems = paths.map { URLQueryItem(name: "path", value: $0) }
        guard !paths.isEmpty, let url = components.url else { throw Self.invalid() }
        return url
    }

    static func parse(_ arguments: [String]) throws -> LaunchRequest {
        var action = GitAction.open, paths: [String] = [], index = 0
        while index < arguments.count {
            let value = arguments[index]
            if value == "--action" {
                index += 1
                guard index < arguments.count, let parsed = GitAction(rawValue: arguments[index]) else { throw invalid() }
                action = parsed
            } else if value == "--path" || value == "--open" {
                index += 1
                guard index < arguments.count else { throw invalid() }
                paths.append(arguments[index])
            } else if value == "--" {
                paths.append(contentsOf: arguments.dropFirst(index + 1)); break
            } else { throw invalid() }
            index += 1
        }
        return LaunchRequest(action: action, paths: paths)
    }
    static func parse(_ url: URL) throws -> LaunchRequest {
        guard url.scheme == "gitnebula", let host = url.host, let action = GitAction(rawValue: host) else { throw invalid() }
        let paths = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "path" }.compactMap(\.value) ?? []
        guard !paths.isEmpty else { throw invalid() }
        return LaunchRequest(action: action, paths: paths)
    }
    static func invalid() -> NSError {
        NSError(domain: "GitNebula", code: 1, userInfo: [NSLocalizedDescriptionKey: L("起動引数が不正です。--action commit --path /path/to/repo の形式で指定してください。")])
    }
    func includes(_ file: String, root: String) -> Bool {
        if paths.isEmpty { return true }
        let target = Self.normalized(URL(fileURLWithPath: root).appendingPathComponent(file).path)
        return paths.contains {
            let path = Self.normalized($0)
            return target == path || target.hasPrefix(path.hasSuffix("/") ? path : path + "/")
        }
    }
    private static func normalized(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }
    static func directory(for path: String) -> String {
        if (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            return URL(fileURLWithPath: path).deletingLastPathComponent().path
        }
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue {
            return URL(fileURLWithPath: path).deletingLastPathComponent().path
        }
        return path
    }
    static func canonicalDirectory(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func inputPath(_ input: String) throws -> String {
        var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count >= 2, let first = path.first, first == path.last, first == "\"" || first == "'" {
            path = String(path.dropFirst().dropLast())
        }
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL { path = url.path }
        path = NSString(string: path).expandingTildeInPath
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw NSError(domain: "GitNebula", code: 1, userInfo: [NSLocalizedDescriptionKey: L("フォルダの絶対パスを入力してください（例: ~/Projects/my-repo）。")])
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
