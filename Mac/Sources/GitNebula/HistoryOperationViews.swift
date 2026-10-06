import SwiftUI
import AppKit

@MainActor
struct CommitOperationView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @ObservedObject var model: Workspace
    @State private var commits: [CommitRecord] = []
    @State private var selection: String?
    @State private var query = ""
    @State private var error: String?
    private var filtered: [CommitRecord] { commits.filter { $0.matches(query) } }
    private var selected: CommitRecord? { filtered.first { $0.id == selection } }
    private var canExecute: Bool {
        guard let selected else { return false }
        return selected.parents.count <= 1 && model.changes.isEmpty
            && model.sequence == nil && model.conflicts.isEmpty && !model.busy
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField(L("コミットを検索（メッセージ・作成者・ID）"), text: $query).textFieldStyle(.roundedBorder)
            Table(filtered, selection: $selection) {
                TableColumn("ID", value: \.shortID).width(min: 80, ideal: 95, max: 110)
                TableColumn(L("コミット"), value: \.subject)
                TableColumn(L("作成者"), value: \.author).width(min: 110, ideal: 150, max: 200)
                TableColumn(L("日時"), value: \.displayDate).width(min: 130, ideal: 170, max: 220)
            }.frame(minHeight: 220).accessibilityIdentifier("commitOperationTable")
            if let selected {
                Text(selected.message).textSelection(.enabled).lineLimit(6)
                Text(L("対象: \(selected.id)\n実行先: \(model.branch)")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if selected.parents.count > 1 { Text(L("マージコミットは親の指定が必要なため、この画面からは実行できません。")).foregroundStyle(.orange) }
            } else { Text(L("一覧から実行するコミットを選んでください。")).foregroundStyle(.secondary) }
            if !model.changes.isEmpty { Text(L("実行前に、作業中の変更をコミットまたは Stash してください。")).foregroundStyle(.orange) }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Text(model.action == .revert ? L("履歴を残して変更を取り消すコミットを作成します。") : L("選んだコミットの変更を現在のブランチへ取り込みます。"))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                GitOperationButton(title: model.action == .revert ? L("このコミットを取り消す（Revert）") : L("この変更を取り込む（Cherry-pick）"),
                                   identifier: model.action == .revert ? "executeRevert" : "executeCherryPick", enabled: canExecute, action: execute)
                    .fixedSize()
            }
        }.accessibilityIdentifier("commitOperationScreen")
        .task(id: model.revisionID) {
            guard let repo = model.repository else { return }
            error = nil
            do {
                let records = try await Task.detached { try repo.history() }.value
                guard !Task.isCancelled else { return }
                commits = records
                if !records.contains(where: { $0.id == selection }) { selection = nil }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func execute() {
        guard canExecute, let commit = selected else { return }
        let operation = model.action
        let alert = NSAlert(); alert.messageText = operation.title
        alert.informativeText = L("\(operation.hint)\n対象: \(commit.shortID) · \(commit.subject)\n実行先: \(model.branch)\nリポジトリ: \(model.repository?.path ?? "")")
        alert.addButton(withTitle: L("実行")); alert.addButton(withTitle: L("キャンセル"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let id = commit.id
        model.operation(success: operation == .revert ? L("Revert が完了しました。履歴を残して変更を取り消しました。") : L("Cherry-pick が完了しました。")) {
            if operation == .revert { try $0.revert(id) } else { try $0.cherryPick(id) }
        }
    }
}

@MainActor
struct BranchIntegrationView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @ObservedObject var model: Workspace
    @State private var records: [BranchRecord] = []
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("現在のブランチ: ") + model.branch).font(.headline)
            Table(records, selection: Binding(get: { Optional(model.chosenBranch) }, set: { model.chosenBranch = $0 ?? "" })) {
                TableColumn(L("対象のブランチ")) { record in Text(record.name == model.branch ? record.name + L("（現在）") : record.name) }
                TableColumn(L("最新のコミット"), value: \.subject)
                TableColumn(L("追跡先"), value: \.upstream)
            }.frame(minHeight: 220).accessibilityIdentifier("branchIntegrationTable")
            Text(model.action == .rebase ? L("\(model.branch) のコミットを \(model.chosenBranch) の上につなぎ直します。コミット ID が変わります。") : L("\(model.chosenBranch) の変更を \(model.branch) に取り込みます。"))
                .textSelection(.enabled)
            if !model.changes.isEmpty { Text(L("実行前に、作業中の変更をコミットまたは Stash してください。")).foregroundStyle(.orange) }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                GitOperationButton(title: model.action == .rebase ? L("選んだブランチの上に Rebase") : L("選んだブランチを Merge"),
                                   identifier: model.action == .rebase ? "executeRebase" : "executeMerge",
                                   enabled: !model.chosenBranch.isEmpty && model.chosenBranch != model.branch && model.changes.isEmpty && model.sequence == nil && model.conflicts.isEmpty && !model.busy,
                                   action: execute).fixedSize()
            }
        }.accessibilityIdentifier("branchIntegrationScreen")
        .task(id: model.revisionID) {
            guard let repo = model.repository else { return }
            error = nil
            do {
                let branches = try await Task.detached { try repo.branchRecords() }.value
                if !Task.isCancelled { records = branches }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func execute() {
        let operation = model.action, branch = model.chosenBranch
        let alert = NSAlert(); alert.messageText = operation.title
        alert.informativeText = operation == .rebase ? L("\(model.branch) のコミットを \(branch) の上につなぎ直します。コミット ID が変わります。") : L("\(branch) の変更を \(model.branch) に取り込みます。")
        alert.addButton(withTitle: L("実行")); alert.addButton(withTitle: L("キャンセル"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.operation(success: operation == .rebase ? L("Rebase が完了しました。") : L("Merge が完了しました。")) {
            if operation == .rebase { try $0.rebase(onto: branch) } else { try $0.merge(branch) }
        }
    }
}

struct GitOperationButton: NSViewRepresentable {
    let title: String
    let identifier: String
    let enabled: Bool
    let action: () -> Void
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func execute(_ sender: NSButton) { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.execute(_:)))
        button.bezelStyle = .rounded; button.controlSize = .large; button.bezelColor = .systemPurple
        button.setAccessibilityIdentifier(identifier); button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title; button.isEnabled = enabled; context.coordinator.action = action
    }
}
