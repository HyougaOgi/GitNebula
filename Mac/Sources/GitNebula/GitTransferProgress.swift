import Foundation
import SwiftUI

struct GitTransferProgress: Sendable, Equatable {
    let stage: String
    var fraction: Double? = nil
    var detail = ""
    static let connecting = GitTransferProgress(stage: "Connecting")
    static let checking = GitTransferProgress(stage: "Checking result")
    static let completed = GitTransferProgress(stage: "Completed", fraction: 1)
    static let failed = GitTransferProgress(stage: "Failed")
    var title: String {
        switch stage {
        case "Connecting": return L("接続中…")
        case "Counting objects", "Enumerating objects": return L("オブジェクトを確認中")
        case "Compressing objects": return L("オブジェクトを圧縮中")
        case "Receiving objects": return L("オブジェクトを受信中")
        case "Writing objects": return L("オブジェクトを送信中")
        case "Unpacking objects": return L("オブジェクトを展開中")
        case "Resolving deltas": return L("差分を展開中")
        case "Updating files", "Checking out files": return L("ファイルを展開中")
        case "Checking result": return L("更新を確認中…")
        case "Completed": return L("完了")
        case "Failed": return L("失敗")
        default: return stage
        }
    }
    var percent: Int? { fraction.map { Int(($0 * 100).rounded()) } }
}

struct GitProgressParser {
    private var pending = Data()
    private static let percentage = try! NSRegularExpression(pattern: "^\\s*(?:remote:\\s*)?([^:]+):\\s*(\\d{1,3})%")
    mutating func consume(_ data: Data, finish: Bool = false) -> [GitTransferProgress] {
        pending.append(data)
        var result: [GitTransferProgress] = []
        while let delimiter = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let line = String(decoding: pending[..<delimiter], as: UTF8.self)
            pending.removeSubrange(...delimiter)
            if let progress = Self.parse(line) { result.append(progress) }
        }
        if finish && !pending.isEmpty {
            if let progress = Self.parse(String(decoding: pending, as: UTF8.self)) { result.append(progress) }
            pending.removeAll()
        }
        return result
    }
    private static func parse(_ line: String) -> GitTransferProgress? {
        let text = line as NSString
        guard let match = percentage.firstMatch(in: line, range: NSRange(location: 0, length: text.length)),
              let percent = Int(text.substring(with: match.range(at: 2))), (0...100).contains(percent) else { return nil }
        return GitTransferProgress(stage: text.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces), fraction: Double(percent) / 100, detail: line.trimmingCharacters(in: .whitespaces))
    }
}

/// The serial queue owns the file cursor and parser. stderr remains a file,
/// so large Git output cannot block the child process on a full pipe.
final class GitProgressReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.gitnebula.transfer-progress")
    private let file: FileHandle
    private let timer: DispatchSourceTimer
    private let report: @Sendable (GitTransferProgress) -> Void
    private var parser = GitProgressParser()
    init(file url: URL, report: @escaping @Sendable (GitTransferProgress) -> Void) throws {
        file = try FileHandle(forReadingFrom: url); self.report = report
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.read() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.resume()
    }
    private func read(finish: Bool = false) {
        let data = (try? file.readToEnd()) ?? Data()
        for progress in parser.consume(data, finish: finish) { report(progress) }
    }
    func finish() {
        timer.cancel()
        queue.sync { read(finish: true); try? file.close() }
    }
}

@MainActor
struct GitTransferProgressView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let progress: GitTransferProgress
    let busy: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(progress.title).accessibilityIdentifier("gitTransferStage")
                Spacer()
                Text(progress.percent.map { "\($0)%" } ?? "—%")
                    .monospacedDigit().accessibilityIdentifier("gitTransferPercent")
            }
            if let fraction = progress.fraction { ProgressView(value: fraction).progressViewStyle(.linear) }
            else if busy { ProgressView().progressViewStyle(.linear) }
            else { ProgressView(value: 0).progressViewStyle(.linear).tint(.orange) }
            if !progress.detail.isEmpty {
                Text(progress.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(progress.detail)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("gitTransferProgress")
    }
}
