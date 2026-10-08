import SwiftUI
import AppKit

struct CommitDetailField: Identifiable {
    let id: String
    let title: String
    let value: String
    var monospaced = false
}

extension CommitRecord {
    var detailFields: [CommitDetailField] {
        [
            CommitDetailField(id: "id", title: L("コミット ID"), value: id, monospaced: true),
            CommitDetailField(id: "message", title: L("メッセージ"), value: message),
            CommitDetailField(id: "author", title: L("作成者"), value: author),
            CommitDetailField(id: "email", title: L("作成者のメール"), value: email),
            CommitDetailField(id: "authorDate", title: L("作成日時"), value: date),
            CommitDetailField(id: "committer", title: L("コミットした人"), value: committer),
            CommitDetailField(id: "committerEmail", title: L("コミットした人のメール"), value: committerEmail),
            CommitDetailField(id: "commitDate", title: L("コミット日時"), value: commitDate),
            CommitDetailField(id: "parents", title: L("親コミット"), value: parents.joined(separator: "\n"), monospaced: true),
            CommitDetailField(id: "references", title: L("ブランチ・タグ"), value: decorations),
            CommitDetailField(id: "tree", title: L("ツリー ID"), value: tree, monospaced: true)
        ].filter { !$0.value.isEmpty }
    }
    var detailsText: String { detailFields.map { $0.title + ":\n" + $0.value }.joined(separator: "\n\n") }
}

enum CommitClipboard {
    @MainActor static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

@MainActor
struct CommitDetailsView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let commit: CommitRecord
    var copy: (String) -> Bool = { CommitClipboard.copy($0) }
    @State private var copiedField: String?
    @State private var copyFailed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("コミット情報")).font(.headline)
                Spacer()
                if copyFailed { Text(L("コピーできませんでした。再度お試しください。")).font(.caption).foregroundStyle(.orange) }
                else if copiedField != nil { Text(L("コピーしました")).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("commitCopyResult") }
                Button { copyValue(commit.detailsText, field: "all") } label: {
                    Label(L("全体をコピー"), systemImage: "doc.on.doc")
                }.accessibilityIdentifier("copyCommit:all")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(commit.detailFields) { field in
                        HStack(alignment: .top, spacing: 12) {
                            Text(field.title).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
                            Text(field.value).font(field.monospaced ? .system(.body, design: .monospaced) : .body)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("commitField:" + field.id)
                            Button { copyValue(field.value, field: field.id) } label: {
                                Image(systemName: copiedField == field.id ? "checkmark" : "doc.on.doc")
                                    .frame(width: 14)
                            }.buttonStyle(.borderless)
                                .help(L("\(field.title)をコピー"))
                                .accessibilityLabel(L("\(field.title)をコピー"))
                                .accessibilityIdentifier("copyCommit:" + field.id)
                        }
                    }
                }.padding(.trailing, 6).frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("commitDetailsScroll")
        }.padding(10).accessibilityIdentifier("commitDetails")
            .onChange(of: commit.id) { _ in copiedField = nil; copyFailed = false }
    }
    private func copyValue(_ value: String, field: String) {
        let succeeded = copy(value)
        copiedField = succeeded ? field : nil
        copyFailed = !succeeded
    }
}
