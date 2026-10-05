import Foundation

struct CommitRecord: Identifiable, Sendable, Equatable {
    let id: String
    let parents: [String]
    let author: String
    let email: String
    let date: String
    let decorations: String
    let subject: String
    let message: String
    var shortID: String { String(id.prefix(8)) }
    var displayDate: String { String(date.prefix(16)).replacingOccurrences(of: "T", with: " ") }
    func matches(_ query: String) -> Bool {
        query.isEmpty || [id, author, email, message, decorations].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct FileRevision: Sendable {
    let data: Data
    let exists: Bool
    let notice: String?
    init(_ data: Data = Data(), exists: Bool = true, notice: String? = nil) {
        self.data = data; self.exists = exists; self.notice = notice
    }
    static let absent = FileRevision(exists: false)
}

struct DiffRow: Sendable, Equatable {
    enum Kind: Sendable { case unchanged, added, removed, modified }
    let oldNumber: Int?
    let newNumber: Int?
    let oldText: String?
    let newText: String?
    let kind: Kind
}

struct DiffDocument: Identifiable, Sendable {
    let id = UUID()
    let path: String
    let oldTitle: String
    let newTitle: String
    let old: FileRevision
    let new: FileRevision
    let rows: [DiffRow]
    let hunks: [Int]
    let notice: String?
    var additions: Int { rows.filter { $0.kind != .unchanged && $0.newNumber != nil }.count }
    var deletions: Int { rows.filter { $0.kind != .unchanged && $0.oldNumber != nil }.count }
    var oldEndsInNewline: Bool { old.data.isEmpty || old.data.last == 10 }
    var newEndsInNewline: Bool { new.data.isEmpty || new.data.last == 10 }

    static func lines(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    // Git supplies zero-context hunk coordinates. Align the full source files
    // around those coordinates, including blank cells for insertions/deletions.
    static func align(old: [String], new: [String], patch: String) throws -> (rows: [DiffRow], hunks: [Int]) {
        let expression = try NSRegularExpression(pattern: "^@@ -(\\d+)(?:,(\\d+))? \\+(\\d+)(?:,(\\d+))? @@", options: .anchorsMatchLines)
        let text = patch as NSString
        var rows: [DiffRow] = [], hunks: [Int] = [], left = 0, right = 0
        func appendUnchanged(until end: Int) throws {
            guard end >= left, end <= old.count else { throw NSError(domain: "GitNebula", code: 1, userInfo: [NSLocalizedDescriptionKey: "差分の行情報を読み取れませんでした。更新して再度お試しください。"]) }
            while left < end {
                guard right < new.count else { throw NSError(domain: "GitNebula", code: 1, userInfo: [NSLocalizedDescriptionKey: "差分の行情報を読み取れませんでした。更新して再度お試しください。"]) }
                rows.append(DiffRow(oldNumber: left + 1, newNumber: right + 1, oldText: old[left], newText: new[right], kind: .unchanged))
                left += 1; right += 1
            }
        }
        for match in expression.matches(in: patch, range: NSRange(location: 0, length: text.length)) {
            func number(_ index: Int, fallback: Int) -> Int {
                let range = match.range(at: index)
                return range.location == NSNotFound ? fallback : Int(text.substring(with: range)) ?? fallback
            }
            let oldCount = number(2, fallback: 1), newCount = number(4, fallback: 1)
            let oldStart = number(1, fallback: 0) - (oldCount == 0 ? 0 : 1)
            let newStart = number(3, fallback: 0) - (newCount == 0 ? 0 : 1)
            try appendUnchanged(until: oldStart)
            guard right == newStart, oldStart + oldCount <= old.count, newStart + newCount <= new.count else { throw NSError(domain: "GitNebula", code: 1, userInfo: [NSLocalizedDescriptionKey: "差分の行情報を読み取れませんでした。更新して再度お試しください。"]) }
            hunks.append(rows.count)
            for offset in 0..<max(oldCount, newCount) {
                let l = offset < oldCount ? oldStart + offset : nil
                let r = offset < newCount ? newStart + offset : nil
                rows.append(DiffRow(oldNumber: l.map { $0 + 1 }, newNumber: r.map { $0 + 1 }, oldText: l.map { old[$0] }, newText: r.map { new[$0] }, kind: l == nil ? .added : r == nil ? .removed : .modified))
            }
            left += oldCount; right += newCount
        }
        try appendUnchanged(until: old.count)
        guard right == new.count else { throw NSError(domain: "GitNebula", code: 1, userInfo: [NSLocalizedDescriptionKey: "差分の行情報を読み取れませんでした。更新して再度お試しください。"]) }
        return (rows, hunks)
    }
}

extension GitRepository {
    func history(reference: String? = nil, limit: Int = 200, skip: Int = 0, file: String? = nil) throws -> [CommitRecord] {
        let head = try headRevision()
        if reference == nil && head == nil {
            if try run(["rev-list", "--all", "--max-count=1"]).isEmpty { return [] }
        }
        let refs: [String]
        if let reference { refs = [try revision(reference)] }
        else { refs = ["--all"] + (head.map { [$0] } ?? []) }
        if let file { _ = try fileURL(file) }
        let output = try run(["--literal-pathspecs", "log", "--no-color", "--date-order", "--decorate=short", "-z", "--max-count=\(limit)", "--skip=\(skip)", "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%D%x00%s%x00%B"] + (file == nil ? [] : ["--follow"]) + refs + ["--"] + (file.map { [$0] } ?? []))
        var fields = output.components(separatedBy: "\0")
        if fields.last == "" { fields.removeLast() }
        guard fields.count % 8 == 0 else { throw failure("コミット履歴を読み取れませんでした。") }
        var records: [CommitRecord] = []
        for i in stride(from: 0, to: fields.count, by: 8) {
            let parents = fields[i + 1].split(separator: " ").map(String.init)
            let message = fields[i + 7].trimmingCharacters(in: .newlines)
            records.append(CommitRecord(id: fields[i], parents: parents, author: fields[i + 2], email: fields[i + 3], date: fields[i + 4], decorations: fields[i + 5], subject: fields[i + 6], message: message))
        }
        return records
    }

    func revisionChanges(from base: String?, to target: String) throws -> [Change] {
        let target = try revision(target)
        let args: [String]
        if let base { args = ["diff", "--name-status", "-z", "--find-renames", try revision(base), target, "--"] }
        else { args = ["diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z", "--find-renames", target, "--"] }
        let fields = try run(args).components(separatedBy: "\0")
        var changes: [Change] = [], i = 0
        while i < fields.count && !fields[i].isEmpty {
            let code = fields[i]; i += 1
            guard i < fields.count else { throw failure("変更ファイルの一覧を読み取れませんでした。") }
            let first = fields[i]; i += 1
            if code.hasPrefix("R") || code.hasPrefix("C") {
                guard i < fields.count else { throw failure("名前変更を読み取れませんでした。") }
                changes.append(Change(code: String(code.prefix(1)), path: fields[i], original: first)); i += 1
            } else { changes.append(Change(code: code, path: first, original: nil)) }
        }
        return changes
    }

    func revisionFile(_ file: String, at reference: String?) throws -> FileRevision {
        guard let reference else { return .absent }
        guard !file.hasPrefix("/"), !file.split(separator: "/").contains(".."), !file.contains("\0") else { throw failure("リポジトリ内のファイルを指定してください。") }
        let entries = try run(["--literal-pathspecs", "ls-tree", "-z", reference, "--", file]).components(separatedBy: "\0")
        guard let entry = entries.first, !entry.isEmpty else { return .absent }
        let header = entry.prefix { $0 != "\t" }.split(separator: " ").map(String.init)
        guard header.count == 3 else { throw failure("ファイル情報を読み取れませんでした。") }
        if header[1] == "commit" { return FileRevision(Data(("Submodule " + header[2] + "\n").utf8)) }
        guard header[1] == "blob" else { return FileRevision(notice: "フォルダです。変更ファイルを選択してください。") }
        let size = Int(try run(["cat-file", "-s", header[2]]).trimmingCharacters(in: .newlines)) ?? 0
        if size > 1024 * 1024 { return FileRevision(notice: "1 MiB を超えるファイルです（\(size) bytes）。") }
        return FileRevision(try runData(["cat-file", "blob", header[2]]))
    }

    func workingFile(_ file: String) throws -> FileRevision {
        let url = try fileURL(file)
        guard try entryExists(file) else { return .absent }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            return FileRevision(Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8))
        }
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            let child = GitRepository(path: url.path)
            if let hash = try? child.revision("HEAD") { return FileRevision(Data(("Submodule " + hash + "\n").utf8)) }
            return FileRevision(notice: "フォルダです。")
        }
        if ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 1024 * 1024 { return FileRevision(notice: "1 MiB を超えるファイルです。") }
        return FileRevision(try Data(contentsOf: url))
    }

    func comparison(_ change: Change, from base: String?, to target: String? = nil) throws -> DiffDocument {
        let baseID: String?
        if base == "HEAD" && target == nil { baseID = try? revision("HEAD") }
        else { baseID = try base.map { try revision($0) } }
        let targetID = try target.map { try revision($0) }
        let old = try revisionFile(change.original ?? change.path, at: baseID)
        let new = try targetID.map { try revisionFile(change.path, at: $0) } ?? workingFile(change.path)
        return try compareFiles(old: old, new: new, path: change.path,
                                oldTitle: base == "HEAD" ? "HEAD · 変更前" : baseID.map { String($0.prefix(8)) + " · 変更前" } ?? "作成前",
                                newTitle: targetID.map { String($0.prefix(8)) + " · 変更後" } ?? "作業ツリー · 変更後")
    }

    func compareFiles(old: FileRevision, new: FileRevision, path: String, oldTitle: String, newTitle: String) throws -> DiffDocument {
        var notice = [old.notice, new.notice].compactMap { $0 }.joined(separator: "\n")
        if old.data.contains(0) || new.data.contains(0) { notice = "バイナリファイルです。テキストとして比較できません。" }
        if !notice.isEmpty { return DiffDocument(path: path, oldTitle: oldTitle, newTitle: newTitle, old: old, new: new, rows: [], hunks: [], notice: notice) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = directory.appendingPathComponent("before"), after = directory.appendingPathComponent("after")
        try old.data.write(to: before); try new.data.write(to: after)
        let patch = String(decoding: try runData(["-c", "diff.interHunkContext=0", "diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv", "--text", "--unified=0", "--", before.path, after.path], accepting: [0, 1]), as: UTF8.self)
        let aligned = try DiffDocument.align(old: DiffDocument.lines(old.data), new: DiffDocument.lines(new.data), patch: patch)
        let invalidUTF8 = String(data: old.data, encoding: .utf8) == nil || String(data: new.data, encoding: .utf8) == nil
        return DiffDocument(path: path, oldTitle: oldTitle, newTitle: newTitle, old: old, new: new, rows: aligned.rows, hunks: aligned.hunks, notice: invalidUTF8 ? "UTF-8 で読めない文字を置き換えて表示しています。元のファイルは変更しません。" : nil)
    }
}
