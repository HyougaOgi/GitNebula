import SwiftUI
import AppKit

struct BrowserPlaceholder: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let title: String
    var detail = ""
    var symbol = "doc.text.magnifyingglass"
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled) }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


struct SideBySideDiffView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let document: DiffDocument
    @State private var hunk = 0
    @State private var navigation = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text")
                Text(document.path).font(.headline).lineLimit(1).help(document.path)
                Spacer()
                Text("+\(document.additions)").foregroundStyle(.green)
                Text("−\(document.deletions)").foregroundStyle(.red)
                Divider().frame(height: 16)
                Button { hunk -= 1; navigation += 1 } label: { Image(systemName: "chevron.up") }.disabled(hunk == 0 || document.hunks.isEmpty).help(L("前の変更箇所"))
                    .accessibilityLabel(L("前の変更箇所"))
                Text(document.hunks.isEmpty ? L("変更なし") : "\(hunk + 1) / \(document.hunks.count)").font(.caption).monospacedDigit()
                Button { hunk += 1; navigation += 1 } label: { Image(systemName: "chevron.down") }.disabled(hunk + 1 >= document.hunks.count).help(L("次の変更箇所"))
                    .accessibilityLabel(L("次の変更箇所"))
            }.padding(10)
            Divider()
            HStack(spacing: 0) {
                paneTitle(document.oldTitle, exists: document.old.exists, endsInNewline: document.oldEndsInNewline, color: .red)
                Divider()
                paneTitle(document.newTitle, exists: document.new.exists, endsInNewline: document.newEndsInNewline, color: .green)
            }.frame(height: 36).background(.white.opacity(0.04))
            Divider()
            if let notice = document.notice, document.rows.isEmpty {
                BrowserPlaceholder(title: L("テキスト比較できないファイル"), detail: notice, symbol: "doc")
            } else {
                SynchronizedDiffPanes(document: document, row: document.hunks.isEmpty ? 0 : document.hunks[hunk], navigation: navigation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let notice = document.notice { Text(notice).font(.caption).foregroundStyle(.orange).padding(6) }
                if document.hunks.isEmpty {
                    Text(document.old.exists != document.new.exists ? L("空のファイルの追加・削除です。") : L("テキストの変更はありません。名前・権限などの変更はファイル一覧を確認してください。"))
                        .font(.caption).foregroundStyle(.secondary).padding(6)
                }
            }
        }.accessibilityIdentifier("sideBySideDiff")
    }
    private func paneTitle(_ title: String, exists: Bool, endsInNewline: Bool, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.system(.caption, design: .monospaced))
            Spacer(minLength: 4)
            if !exists { Text(L("ファイルなし")).font(.caption2).foregroundStyle(.secondary) }
            else if !endsInNewline { Text(L("末尾改行なし")).font(.caption2).foregroundStyle(.orange) }
        }.padding(.horizontal, 10).frame(maxWidth: .infinity)
    }
}

private let diffLineHeight: CGFloat = 20
private let diffTextInset: CGFloat = 8

final class DiffTextView: NSTextView {
    var rows: [DiffRow] = []
    var isBefore = false
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let start = max(0, Int((rect.minY - diffTextInset) / diffLineHeight))
        let end = min(rows.count, Int((rect.maxY - diffTextInset) / diffLineHeight) + 1)
        guard start < end else { return }
        for index in start..<end {
            let row = rows[index]
            guard row.kind != .unchanged else { continue }
            let missing = isBefore ? row.oldNumber == nil : row.newNumber == nil
            let color: NSColor = missing ? .secondaryLabelColor : isBefore ? .systemRed : .systemGreen
            color.withAlphaComponent(missing ? 0.06 : 0.15).setFill()
            NSRect(x: 0, y: diffTextInset + CGFloat(index) * diffLineHeight, width: bounds.width, height: diffLineHeight).fill()
        }
    }
}

final class DiffLineRuler: NSRulerView {
    weak var codeView: DiffTextView?
    init(scrollView: NSScrollView, textView: DiffTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        codeView = textView; clientView = textView; ruleThickness = 55
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        guard let text = codeView, let scroll = scrollView else { return }
        let offset = scroll.contentView.bounds.minY
        let first = max(0, Int((offset - diffTextInset) / diffLineHeight))
        let last = min(text.rows.count, first + Int(bounds.height / diffLineHeight) + 3)
        guard first < last else { return }
        for index in first..<last {
            let row = text.rows[index], number = text.isBefore ? row.oldNumber : row.newNumber
            let value = number.map(String.init) ?? "·"
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
            let width = (value as NSString).size(withAttributes: attributes).width
            let y = diffTextInset + CGFloat(index) * diffLineHeight - offset + 3
            (value as NSString).draw(at: NSPoint(x: 43 - width, y: y), withAttributes: attributes)
            if row.kind != .unchanged, number != nil {
                let sign = text.isBefore ? "−" : "+"
                (sign as NSString).draw(at: NSPoint(x: 3, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: text.isBefore ? NSColor.systemRed : NSColor.systemGreen])
            }
        }
    }
}

final class DiffPanesView: NSView {
    let before = NSScrollView(), after = NSScrollView()
    let oldText = DiffTextView(), newText = DiffTextView()
    private var observers: [NSObjectProtocol] = []
    private var synchronizing = false
    private var documentID: UUID?
    private var lastNavigation = -1
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true
        for (scroll, text, isBefore) in [(before, oldText, true), (after, newText, false)] {
            scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .noBorder
            text.isBefore = isBefore; text.isEditable = false; text.isSelectable = true; text.isRichText = false
            text.isHorizontallyResizable = true; text.isVerticallyResizable = true
            text.textContainerInset = NSSize(width: 10, height: diffTextInset)
            text.textContainer?.widthTracksTextView = false
            text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.setAccessibilityIdentifier(isBefore ? "diffBefore" : "diffAfter")
            text.setAccessibilityLabel(isBefore ? L("変更前のファイル") : L("変更後のファイル"))
            scroll.documentView = text
            scroll.verticalRulerView = DiffLineRuler(scrollView: scroll, textView: text)
            scroll.hasVerticalRuler = true; scroll.rulersVisible = true
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                guard let self, let scroll else { return }; self.synchronize(scroll)
            })
        }
        NSLayoutConstraint.activate([
            before.leadingAnchor.constraint(equalTo: leadingAnchor), before.topAnchor.constraint(equalTo: topAnchor), before.bottomAnchor.constraint(equalTo: bottomAnchor),
            before.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5, constant: -0.5),
            after.leadingAnchor.constraint(equalTo: before.trailingAnchor, constant: 1), after.trailingAnchor.constraint(equalTo: trailingAnchor), after.topAnchor.constraint(equalTo: topAnchor), after.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    private func synchronize(_ source: NSScrollView) {
        guard !synchronizing else { return }; synchronizing = true
        let other = source === before ? after : before
        other.contentView.scroll(to: NSPoint(x: other.contentView.bounds.minX, y: source.contentView.bounds.minY))
        other.reflectScrolledClipView(other.contentView)
        before.verticalRulerView?.needsDisplay = true; after.verticalRulerView?.needsDisplay = true
        synchronizing = false
    }
    override func layout() {
        super.layout()
        for (scroll, text) in [(before, oldText), (after, newText)] {
            text.setFrameSize(NSSize(width: max(text.frame.width, scroll.contentSize.width), height: max(CGFloat(text.rows.count) * diffLineHeight + 2 * diffTextInset, scroll.contentSize.height)))
        }
    }
    func display(_ document: DiffDocument, row: Int, navigation: Int) {
        if documentID != document.id {
            documentID = document.id; lastNavigation = -1
            for (scroll, text, isBefore) in [(before, oldText, true), (after, newText, false)] {
                text.rows = document.rows
                let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = diffLineHeight; paragraph.maximumLineHeight = diffLineHeight
                paragraph.defaultTabInterval = 28; paragraph.tabStops = []
                let lines = document.rows.map { (isBefore ? $0.oldText : $0.newText) ?? "" }.map { $0.replacingOccurrences(of: "\r", with: "␍") }
                let value = lines.joined(separator: "\n") + "\n"
                text.textStorage?.setAttributedString(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]))
                let width = min(200_000, (lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0) + 48)
                text.setFrameSize(NSSize(width: max(scroll.contentSize.width, width), height: max(scroll.contentSize.height, CGFloat(lines.count + 1) * diffLineHeight + 2 * diffTextInset)))
                scroll.contentView.scroll(to: .zero); text.needsDisplay = true
                scroll.verticalRulerView?.needsDisplay = true
            }
        }
        if lastNavigation != navigation {
            lastNavigation = navigation
            let y = max(0, CGFloat(row) * diffLineHeight - 60)
            before.contentView.scroll(to: NSPoint(x: before.contentView.bounds.minX, y: y))
            before.reflectScrolledClipView(before.contentView); synchronize(before)
        }
    }
}

struct SynchronizedDiffPanes: NSViewRepresentable {
    let document: DiffDocument
    let row: Int
    let navigation: Int
    func makeNSView(context: Context) -> DiffPanesView { DiffPanesView(frame: .zero) }
    func updateNSView(_ view: DiffPanesView, context: Context) { view.display(document, row: row, navigation: navigation) }
}
