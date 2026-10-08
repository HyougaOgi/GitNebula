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
struct CommitDetailsView: NSViewRepresentable {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let commit: CommitRecord
    var copy: (String) -> Bool = { CommitClipboard.copy($0) }
    func makeNSView(context: Context) -> CommitDetailsPanel {
        CommitDetailsPanel(commit: commit, copy: copy)
    }
    func updateNSView(_ panel: CommitDetailsPanel, context: Context) {
        panel.update(commit: commit, copy: copy, enabled: context.environment.isEnabled)
    }
}

/// Keep the full ID and copy controls visible. The entire body scrolls together
/// so every field remains reachable even in a short window.
@MainActor
private final class CommitDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class CommitDetailsPanel: NSView {
    override var isFlipped: Bool { true }
    private let heading = NSTextField(labelWithString: "")
    private let feedback = NSTextField(labelWithString: "")
    let hashField = NSTextField(wrappingLabelWithString: "")
    let messageView = NSTextView()
    private let messageScroll = NSScrollView()
    private let metadata = NSStackView()
    private let detailsBody = CommitDocumentView()
    private let messageHeading = NSTextField(labelWithString: "")
    private var messageHeight: NSLayoutConstraint!
    private var buttons: [NSButton] = []
    private var values: [String: String] = [:]
    private var displayed: CommitRecord?
    private var displayedLanguage = ""
    private var copyValue: (String) -> Bool
    init(commit: CommitRecord, copy: @escaping (String) -> Bool) {
        copyValue = copy
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 320))
        setAccessibilityIdentifier("commitDetails")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        feedback.font = .systemFont(ofSize: 13); feedback.textColor = .secondaryLabelColor
        let toolbar = NSStackView(views: [heading, feedback, NSView(), button("id", identifier: "copyCommit:id"), button("message", identifier: "copyCommit:message"), button("all", identifier: "copyCommit:all")])
        toolbar.orientation = .horizontal; toolbar.spacing = 12
        hashField.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        hashField.isSelectable = true; hashField.maximumNumberOfLines = 0
        hashField.lineBreakMode = .byWordWrapping
        hashField.setAccessibilityIdentifier("commitField:id")
        messageHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        messageView.isEditable = false; messageView.isSelectable = true; messageView.isRichText = false
        messageView.drawsBackground = false; messageView.textColor = .labelColor
        messageView.font = .systemFont(ofSize: 15)
        messageView.textContainerInset = NSSize(width: 8, height: 8)
        messageView.isHorizontallyResizable = false; messageView.isVerticallyResizable = true
        messageView.autoresizingMask = [.width]
        messageView.textContainer?.widthTracksTextView = true
        messageView.setAccessibilityIdentifier("commitField:message")
        messageScroll.documentView = detailsBody; messageScroll.hasVerticalScroller = true
        messageScroll.setAccessibilityIdentifier("commitDetailsScroll")
        messageScroll.drawsBackground = false; messageScroll.borderType = .lineBorder
        metadata.orientation = .vertical; metadata.alignment = .leading; metadata.spacing = 10
        detailsBody.translatesAutoresizingMaskIntoConstraints = false
        detailsBody.widthAnchor.constraint(equalTo: messageScroll.contentView.widthAnchor).isActive = true
        for view in [messageHeading, messageView, metadata] {
            view.translatesAutoresizingMaskIntoConstraints = false; detailsBody.addSubview(view)
            view.leadingAnchor.constraint(equalTo: detailsBody.leadingAnchor, constant: 8).isActive = true
            view.trailingAnchor.constraint(equalTo: detailsBody.trailingAnchor, constant: -8).isActive = true
        }
        messageHeight = messageView.heightAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            detailsBody.topAnchor.constraint(equalTo: messageScroll.contentView.topAnchor),
            detailsBody.leadingAnchor.constraint(equalTo: messageScroll.contentView.leadingAnchor),
            messageHeading.topAnchor.constraint(equalTo: detailsBody.topAnchor, constant: 8),
            messageHeading.heightAnchor.constraint(equalToConstant: 18),
            messageView.topAnchor.constraint(equalTo: messageHeading.bottomAnchor, constant: 6), messageHeight,
            metadata.topAnchor.constraint(equalTo: messageView.bottomAnchor, constant: 12),
            metadata.bottomAnchor.constraint(equalTo: detailsBody.bottomAnchor, constant: -12)
        ])
        for view in [toolbar, hashField, messageScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view)
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10).isActive = true
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10).isActive = true
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            toolbar.heightAnchor.constraint(equalToConstant: 26),
            hashField.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            hashField.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            messageScroll.topAnchor.constraint(equalTo: hashField.bottomAnchor, constant: 10),
            messageScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
        update(commit: commit, copy: copy, enabled: true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let width = max(100, messageView.bounds.width - 16)
        let height = (messageView.string as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: messageView.font ?? NSFont.systemFont(ofSize: 15)]).height
        let needed = max(80, ceil(height) + 24)
        if abs(messageHeight.constant - needed) > 0.5 { messageHeight.constant = needed }
    }
    private func button(_ field: String, identifier: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(copyField(_:)))
        button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 13)
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        button.setContentHuggingPriority(.required, for: .horizontal)
        buttons.append(button)
        return button
    }
    func update(commit: CommitRecord, copy: @escaping (String) -> Bool, enabled: Bool) {
        copyValue = copy
        let language = AppearanceSettings.shared.language.rawValue
        if displayed != commit || displayedLanguage != language {
            displayed = commit; displayedLanguage = language
            feedback.stringValue = ""; feedback.setAccessibilityIdentifier(nil)
            heading.stringValue = L("コミット情報"); messageHeading.stringValue = L("メッセージ")
            hashField.stringValue = commit.id; hashField.toolTip = commit.id
            messageView.string = commit.message
            needsLayout = true
            values = Dictionary(uniqueKeysWithValues: commit.detailFields.map { ($0.id, $0.value) })
            values["all"] = commit.detailsText
            for view in metadata.arrangedSubviews { metadata.removeArrangedSubview(view); view.removeFromSuperview() }
            buttons.removeAll { $0.identifier?.rawValue.hasPrefix("copyCommitField:") == true }
            let titles = ["id": L("コミット ID をコピー"), "message": L("メッセージをコピー"), "all": L("全体をコピー")]
            for button in buttons { button.title = titles[button.identifier!.rawValue.replacingOccurrences(of: "copyCommit:", with: "")] ?? "" }
            for field in commit.detailFields where field.id != "id" && field.id != "message" {
                let label = NSTextField(labelWithString: field.title)
                label.font = .systemFont(ofSize: 13); label.textColor = .secondaryLabelColor
                let value = NSTextField(wrappingLabelWithString: field.value)
                value.font = field.monospaced ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 14)
                value.isSelectable = true; value.maximumNumberOfLines = 0
                value.setAccessibilityIdentifier("commitField:" + field.id)
                let copyButton = button(field.id, identifier: "copyCommitField:" + field.id)
                copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
                copyButton.toolTip = L("\(field.title)をコピー"); copyButton.setAccessibilityLabel(copyButton.toolTip)
                let fieldHeading = NSStackView(views: [label, NSView(), copyButton])
                fieldHeading.orientation = .horizontal; fieldHeading.spacing = 8
                let row = NSStackView(views: [fieldHeading, value])
                row.orientation = .vertical; row.alignment = .leading; row.spacing = 4
                value.setContentHuggingPriority(.defaultLow, for: .horizontal)
                metadata.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: metadata.widthAnchor).isActive = true
                fieldHeading.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
                value.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            }
            messageScroll.contentView.scroll(to: .zero)
        }
        buttons.forEach { $0.isEnabled = enabled }
    }
    @objc private func copyField(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }
        let field = identifier.replacingOccurrences(of: "copyCommitField:", with: "").replacingOccurrences(of: "copyCommit:", with: "")
        guard let value = values[field] else { return }
        let succeeded = copyValue(value)
        feedback.stringValue = succeeded ? L("コピーしました") : L("コピーできませんでした。再度お試しください。")
        feedback.textColor = succeeded ? .secondaryLabelColor : .systemOrange
        feedback.setAccessibilityIdentifier(succeeded ? "commitCopyResult" : "commitCopyError")
    }
}
