import SwiftUI
import AppKit

/// A list owns selection and sorting, never a file comparison or its contents.
@MainActor
struct ChangedFilesView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let repo: GitRepository
    let files: [Change]
    var base: String? = "HEAD"
    var target: String? = nil
    var allowsChecking = false
    @Binding var checked: Set<String>
    @Environment(\.screenActions) private var navigation
    @State private var active: String?
    @State private var query = ""
    @State private var sort = "path"
    @State private var ascending = true
    private var filtered: [Change] {
        let items = files.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) || ($0.original?.localizedCaseInsensitiveContains(query) ?? false) }
        return items.sorted {
            let left = sort == "status" ? $0.label : sort == "stage" ? $0.stageLabel : $0.path
            let right = sort == "status" ? $1.label : sort == "stage" ? $1.stageLabel : $1.path
            let result = left == right ? $0.path.localizedStandardCompare($1.path) : left.localizedStandardCompare(right)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }
    private var current: Change? { filtered.first { $0.path == active } }
    private func open(_ file: Change) {
        navigation.openComparison(FileComparisonRequest(repo: repo, change: file, base: base, target: target))
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField(L("ファイルを絞り込み"), text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("diffFileSearch")
                Text(L("\(filtered.count) ファイル")).font(.caption).foregroundStyle(.secondary)
                Button(L("差分を開く")) { if let current { open(current) } }.disabled(current == nil)
                    .accessibilityIdentifier("openFileDiff")
            }
            ChangedFilesTable(files: filtered, allowsChecking: allowsChecking, showsStage: target == nil,
                              selection: $active, checked: $checked, sort: $sort, ascending: $ascending, open: open)
                .overlay {
                    if filtered.isEmpty { Text(files.isEmpty ? L("変更ファイルはありません") : L("一致するファイルはありません")).foregroundStyle(.secondary).allowsHitTesting(false) }
                }
            HStack {
                Text(L("ファイルをダブルクリック、または選択して Enter で差分を開きます。")).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.frame(minHeight: 160, maxHeight: .infinity).accessibilityIdentifier("changedFilesScreen")
    }
}

extension Change {
    var stageLabel: String {
        if code == "??" { return L("未追跡") }
        let status = Array(code)
        guard status.count == 2 else { return "—" }
        if label == L("競合") { return L("競合") }
        let staged = status[0] != " ", unstaged = status[1] != " "
        return staged && unstaged ? L("ステージ済み＋未ステージ") : staged ? L("ステージ済み") : L("未ステージ")
    }
}

final class FileTableView: NSTableView {
    var openSelected: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { openSelected?() }
        else { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return super.menu(for: event)
    }
}

/// Native rows provide reliable double-click/Enter and retain exact scroll offsets.
struct ChangedFilesTable: NSViewRepresentable {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let files: [Change]
    let allowsChecking: Bool
    let showsStage: Bool
    @Binding var selection: String?
    @Binding var checked: Set<String>
    @Binding var sort: String
    @Binding var ascending: Bool
    let open: (Change) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let table = FileTableView()
        table.setAccessibilityIdentifier("changedFilesTable")
        table.rowHeight = 30; table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true; table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        if allowsChecking { addColumn(table, "check", L("対象"), 48) }
        addColumn(table, "status", L("状態"), 100)
        if showsStage { addColumn(table, "stage", L("ステージ"), 185) }
        addColumn(table, "path", L("ファイル（リポジトリからの相対パス）"), 620)
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.openFile)
        table.openSelected = { [weak coordinator = context.coordinator] in coordinator?.openFile() }
        let menu = NSMenu()
        let item = NSMenuItem(title: L("差分を開く"), action: #selector(Coordinator.openFile), keyEquivalent: "")
        item.target = context.coordinator; menu.addItem(item); table.menu = menu
        context.coordinator.table = table; scroll.documentView = table
        return scroll
    }
    private func addColumn(_ table: NSTableView, _ key: String, _ title: String, _ width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
        column.title = title; column.width = width; column.minWidth = key == "path" ? 250 : width
        if key != "check" { column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true) }
        table.addTableColumn(column)
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.enabled = context.environment.isEnabled
        guard let table = coordinator.table else { return }
        for column in table.tableColumns {
            column.title = ["check": L("対象"), "status": L("状態"), "stage": L("ステージ"), "path": L("ファイル（リポジトリからの相対パス）")][column.identifier.rawValue] ?? column.title
        }
        table.menu?.items.first?.title = L("差分を開く")
        let languageChanged = coordinator.language != appearance.language
        coordinator.language = appearance.language
        if languageChanged || coordinator.displayedFiles != files || coordinator.displayedChecked != checked || coordinator.displayedEnabled != coordinator.enabled {
            let offset = scroll.contentView.bounds.origin
            coordinator.updating = true; table.reloadData(); coordinator.updating = false
            coordinator.displayedFiles = files; coordinator.displayedChecked = checked; coordinator.displayedEnabled = coordinator.enabled
            scroll.contentView.scroll(to: offset); scroll.reflectScrolledClipView(scroll.contentView)
        }
        let row = files.firstIndex { $0.path == selection }
        let indexes = row.map { IndexSet(integer: $0) } ?? IndexSet()
        if table.selectedRowIndexes != indexes {
            coordinator.updating = true; table.selectRowIndexes(indexes, byExtendingSelection: false); coordinator.updating = false
        }
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ChangedFilesTable
        weak var table: FileTableView?
        var updating = false
        var enabled = true
        var displayedEnabled = true
        var language: AppLanguage?
        var displayedFiles: [Change]?
        var displayedChecked = Set<String>()
        init(_ parent: ChangedFilesTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.files.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.files.indices.contains(row), let key = tableColumn?.identifier.rawValue else { return nil }
            let file = parent.files[row]
            if key == "check" {
                let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkFile(_:)))
                button.isEnabled = enabled
                button.tag = row; button.state = parent.checked.contains(file.path) ? .on : .off
                button.setAccessibilityLabel(L("対象: ") + file.path)
                return button
            }
            let value = key == "status" ? file.label : key == "stage" ? file.stageLabel : file.original.map { $0 + " → " + file.path } ?? file.path
            let field = NSTextField(labelWithString: value)
            field.lineBreakMode = .byTruncatingMiddle; field.toolTip = value
            field.font = .systemFont(ofSize: 12)
            return field
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.selection = parent.files.indices.contains(table.selectedRow) ? parent.files[table.selectedRow].path : nil
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            parent.sort = key; parent.ascending = descriptor.ascending
        }
        @objc func openFile() {
            guard enabled, let table, parent.files.indices.contains(table.selectedRow) else { return }
            parent.open(parent.files[table.selectedRow])
        }
        @objc func checkFile(_ sender: NSButton) {
            guard enabled, parent.files.indices.contains(sender.tag) else { return }
            let path = parent.files[sender.tag].path
            if sender.state == .on { parent.checked.insert(path) } else { parent.checked.remove(path) }
        }
    }
}
