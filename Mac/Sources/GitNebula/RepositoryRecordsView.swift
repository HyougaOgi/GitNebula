import SwiftUI
import AppKit

struct RepositoryRecord: Identifiable, Sendable {
    let id: Int
    let first: String
    let second: String
    let third: String
    let fourth: String
}
enum RepositoryRecordKind: String, Sendable {
    case blame, reflog, worktrees, submodules
    var columns: [String] {
        switch self {
        case .blame: return ["行", "内容", "作成者", "コミット"]
        case .reflog: return ["参照", "操作", "作成者", "コミット"]
        case .worktrees: return ["フォルダ", "ブランチ", "状態", "コミット"]
        case .submodules: return ["パス", "状態", "参照", "コミット"]
        }
    }
}
extension GitRepository {
    func records(_ kind: RepositoryRecordKind, first: String = "", second: String = "") throws -> [RepositoryRecord] {
        var rows: [RepositoryRecord] = []
        func append(_ a: String, _ b: String, _ c: String, _ d: String) {
            rows.append(RepositoryRecord(id: rows.count, first: a, second: b, third: c, fourth: d))
        }
        switch kind {
        case .blame:
            let ref = try revision(second)
            let content = try revisionFile(first, at: ref)
            guard content.notice == nil, !content.data.contains(0) else { throw failure(content.notice ?? "バイナリファイルの Blame は表示できません。") }
            let result = try run(["--literal-pathspecs", "blame", "--line-porcelain", ref, "--", first])
            var hash = "", author = "", number = ""
            for line in result.components(separatedBy: "\n") {
                if line.hasPrefix("\t") { append(number, String(line.dropFirst()), author, String(hash.prefix(8))) }
                else if line.hasPrefix("author ") { author = String(line.dropFirst(7)) }
                else {
                    let fields = line.split(separator: " ")
                    if fields.count >= 3, fields[0].count >= 40, Int(fields[1]) != nil, Int(fields[2]) != nil {
                        hash = String(fields[0]); number = String(fields[2])
                    }
                }
            }
        case .reflog:
            guard (try? revision("HEAD")) != nil else { return [] }
            let fields = try run(["log", "-g", "-z", "-100", "--format=%gD%x00%gs%x00%an%x00%h", "HEAD", "--"]).components(separatedBy: "\0")
            for i in stride(from: 0, to: max(0, fields.count - 1), by: 4) where i + 3 < fields.count { append(fields[i], fields[i + 1], fields[i + 2], fields[i + 3]) }
        case .worktrees:
            let fields = try run(["worktree", "list", "--porcelain", "-z"]).components(separatedBy: "\0")
            var path = "", branch = "", status = "", hash = ""
            for field in fields {
                if field.hasPrefix("worktree ") { path = String(field.dropFirst(9)); branch = ""; status = ""; hash = "" }
                else if field.hasPrefix("HEAD ") { hash = String(field.dropFirst(5).prefix(8)) }
                else if field.hasPrefix("branch ") { branch = String(field.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
                else if !field.isEmpty { status += (status.isEmpty ? "" : ", ") + field }
                else if !path.isEmpty { append(path, branch, status.isEmpty ? "利用可能" : status, hash); path = "" }
            }
        case .submodules:
            for line in try submodules().components(separatedBy: "\n") where line.count >= 42 {
                let flag = line.first!, hash = String(line.dropFirst().prefix(40)), rest = String(line.dropFirst(42))
                let range = rest.range(of: " (", options: .backwards)
                let path = range.map { String(rest[..<$0.lowerBound]) } ?? rest
                let ref = range.map { String(rest[$0.upperBound...].dropLast()) } ?? ""
                let status = flag == "-" ? "未初期化" : flag == "+" ? "記録と異なるコミット" : flag == "U" ? "競合" : "一致"
                append(path, status, ref, String(hash.prefix(8)))
            }
        }
        return rows
    }
}

@MainActor
struct RepositoryRecordsView: View {
    let repo: GitRepository
    let kind: RepositoryRecordKind
    var first = ""
    var second = ""
    var refreshKey = ""
    @State private var rows: [RepositoryRecord] = []
    @State private var selection: Int?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if kind == .blame { Text(first + " · " + second).font(.headline) }
            Table(rows, selection: $selection) {
                TableColumn(kind.columns[0]) { Text($0.first).lineLimit(1).help($0.first) }.width(min: kind == .blame ? 45 : 150, ideal: kind == .blame ? 55 : 280)
                TableColumn(kind.columns[1]) { Text($0.second).font(kind == .blame ? .system(.body, design: .monospaced) : .body).lineLimit(1).help($0.second) }.width(min: 250, ideal: 450)
                TableColumn(kind.columns[2], value: \.third).width(min: 100, ideal: 160)
                TableColumn(kind.columns[3]) { Text($0.fourth).font(.system(.caption, design: .monospaced)) }.width(90)
            }.accessibilityIdentifier("repositoryRecords")
            .contextMenu {
                Button("選択行をコピー") {
                    if let row = rows.first(where: { $0.id == selection }) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString([row.first, row.second, row.third, row.fourth].joined(separator: "\t"), forType: .string)
                    }
                }.disabled(selection == nil)
            }
            .overlay {
                if loading { ProgressView() }
                else if let error { BrowserPlaceholder(title: "読み込めませんでした", detail: error, symbol: "exclamationmark.triangle") }
                else if rows.isEmpty { Text("表示する項目はありません").foregroundStyle(.secondary) }
            }
            Text("\(rows.count) 件").font(.caption).foregroundStyle(.secondary)
        }.task(id: [repo.path, kind.rawValue, first, second, refreshKey]) {
            loading = true; error = nil
            let repository = repo, type = kind, a = first, b = second
            do {
                let result = try await Task.detached { try repository.records(type, first: a, second: b) }.value
                if !Task.isCancelled { rows = result }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
    }
}
