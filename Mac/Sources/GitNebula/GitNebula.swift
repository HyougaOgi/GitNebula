import SwiftUI
import AppKit
import Foundation
import Combine

struct Snapshot: Sendable {
    let repo: GitRepository
    let changes: [Change]
    let branch: String
    let graph: String
    let branches: [String]
    let remotes: [String]
    let conflicts: [String]
    let merging: Bool
    let preferredRemote: String
    let sequence: GitSequence?
    init(_ repo: GitRepository) throws {
        self.repo = repo; changes = try repo.changes()
        branch = (try? repo.run(["symbolic-ref", "--short", "HEAD"]))?.trimmingCharacters(in: .newlines) ?? "detached HEAD"
        graph = try repo.graph(); branches = try repo.branches(); remotes = try repo.remotes()
        conflicts = try repo.conflicts(); merging = try repo.mergeInProgress(); preferredRemote = try repo.preferredRemote()
        sequence = try repo.sequence()
    }
}

@MainActor
final class Workspace: ObservableObject {
    @Published var launchID = UUID()
    var isScreenActive = true
    private var needsRefresh = false
    private let instanceID = UUID()
    private var changeObserver: AnyCancellable?
    static let repositoryChanged = Notification.Name("GitNebula.repositoryChanged")
    init() {
        changeObserver = NotificationCenter.default.publisher(for: Self.repositoryChanged).receive(on: RunLoop.main).sink { [weak self] note in
            guard let self, let path = note.userInfo?["path"] as? String,
                  path == self.repository?.path, note.userInfo?["source"] as? UUID != self.instanceID else { return }
            self.needsRefresh = true
            if self.isScreenActive { self.refreshIfNeeded() }
        }
    }
    func notifyRepositoryChanged() {
        guard let path = repository?.path else { return }
        NotificationCenter.default.post(name: Self.repositoryChanged, object: nil, userInfo: ["path": path, "source": instanceID])
    }
    func refreshIfNeeded() {
        guard needsRefresh, !busy else { return }
        needsRefresh = false; refresh()
    }
    func refresh() {
        guard let repo = repository else { return }
        perform({ try Snapshot(repo) }, apply: apply)
    }
    func request(for action: GitAction) -> LaunchRequest {
        let paths = request.paths.isEmpty ? repository.map { [$0.path] } ?? [] : request.paths
        return LaunchRequest(action: action, paths: paths)
    }
    @Published var repository: GitRepository?
    @Published var action = GitAction.open
    @Published var changes: [Change] = []
    @Published var selected = Set<String>()
    @Published var branch = ""
    @Published var graph = ""
    @Published var branches: [String] = []
    @Published var remotes: [String] = []
    @Published var conflicts: [String] = []
    @Published var merging = false
    @Published var chosenBranch = ""
    @Published var chosenRemote = ""
    @Published var chosenConflict = ""
    @Published var message = ""
    @Published var status = "準備完了"
    @Published var busy = false
    @Published var succeeded = false
    @Published var failed = false
    @Published var cloneSource = ""
    @Published var cloneDestination = ""
    @Published var repositoryPath = ""
    @Published var sequence: GitSequence?
    @Published var revisionID = UUID()
    private var request = LaunchRequest(action: .open, paths: [])
    private var initialSelection = true
    var visibleChanges: [Change] {
        changes.filter { action == .workspace || request.includes($0.path, root: repository?.path ?? "/") }
    }
    func apply(_ state: Snapshot) {
        repository = state.repo; changes = state.changes; branch = state.branch; graph = state.graph
        branches = state.branches; remotes = state.remotes; conflicts = state.conflicts; merging = state.merging
        sequence = state.sequence; revisionID = UUID()
        chosenBranch = branches.contains(chosenBranch) ? chosenBranch : branches.first(where: { $0 != branch }) ?? branch
        if !remotes.contains(chosenRemote) { chosenRemote = state.preferredRemote }
        if !conflicts.contains(chosenConflict) { chosenConflict = conflicts.first ?? "" }
        let available = Set(visibleChanges.map(\.path))
        selected = initialSelection ? available : selected.intersection(available)
        initialSelection = false
    }
    func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T, success: String = "準備完了", notifiesChanges: Bool = false, apply: @escaping (T) -> Void) {
        guard !busy else { return }; busy = true; succeeded = false; failed = false; status = "処理中…"
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try work() }.value
                apply(result); status = success; succeeded = success != "準備完了"
                if notifiesChanges { notifyRepositoryChanged() }
            } catch {
                let message = error.localizedDescription
                if let repo = repository, let state = try? await Task.detached(operation: { try Snapshot(repo) }).value { self.apply(state) }
                status = message; failed = true
                if notifiesChanges { notifyRepositoryChanged() }
            }
            busy = false
            if isScreenActive { refreshIfNeeded() }
        }
    }
    func launch(_ newRequest: LaunchRequest) {
        guard !busy else { return }
        launchID = UUID(); request = newRequest; action = request.action; initialSelection = true
        repository = nil; changes = []; selected = []; conflicts = []; merging = false; chosenRemote = ""; chosenBranch = ""
        sequence = nil
        message = ""; status = "準備完了"; succeeded = false; failed = false
        if action == .clone {
            let parent = request.paths.first.map(LaunchRequest.directory) ?? NSHomeDirectory()
            cloneDestination = URL(fileURLWithPath: parent).appendingPathComponent("new-repository").path
            return
        }
        if action == .initialize { repositoryPath = request.paths.first.map(LaunchRequest.directory) ?? repositoryPath; return }
        guard let path = request.paths.first else { return }
        repositoryPath = path
        let paths = request.paths
        perform({
            let repo = try GitRepository.open(LaunchRequest.directory(for: path))
            for selectedPath in paths.dropFirst() {
                guard try GitRepository.open(LaunchRequest.directory(for: selectedPath)).path == repo.path else {
                    throw repo.failure("同じリポジトリ内のファイルを選択してください。")
                }
            }
            return try Snapshot(repo)
        }, apply: apply)
    }
    func chooseRepository() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.title = "Git リポジトリを選択"; panel.prompt = "開く"
        if let path = try? LaunchRequest.inputPath(repositoryPath) { panel.directoryURL = URL(fileURLWithPath: path) }
        if panel.runModal() == .OK, let url = panel.url { repositoryPath = url.path; openEnteredPath() }
    }
    func openEnteredPath() {
        guard !busy else { return }
        do {
            let path = try LaunchRequest.inputPath(repositoryPath)
            launch(LaunchRequest(action: action, paths: [path]))
        } catch { status = error.localizedDescription; failed = true; succeeded = false }
    }
    func initializeRepository() {
        let path = repositoryPath
        perform({ try Snapshot(GitRepository.initialize(path)) }, success: "リポジトリを作成しました。ファイルを追加してコミットできます。") { state in
            self.request = LaunchRequest(action: .open, paths: [state.repo.path]); self.action = .open; self.initialSelection = true
            self.repositoryPath = state.repo.path; self.apply(state)
        }
    }
    func selectAction(_ value: GitAction) {
        action = value; selected.formIntersection(Set(visibleChanges.map(\.path))); status = "準備完了"; succeeded = false; failed = false
        if value == .clone, cloneDestination.isEmpty {
            cloneDestination = URL(fileURLWithPath: repository?.path ?? NSHomeDirectory()).appendingPathComponent("new-repository").path
        }
    }
    func operation(success: String = "完了しました。", _ work: @escaping @Sendable (GitRepository) throws -> Void) {
        guard let repo = repository else { return }
        perform({ try work(repo); return try Snapshot(repo) }, success: success, notifiesChanges: true) { state in
            self.apply(state)
        }
    }
    func commit() {
        let paths = Array(selected.intersection(Set(visibleChanges.map(\.path)))), text = message
        guard let repo = repository else { return }
        perform({ try repo.commit(paths, text); return try Snapshot(repo) }, success: "コミットしました。閉じて作業に戻れます。", notifiesChanges: true) {
            self.apply($0); self.message = ""
        }
    }
    func runAction() {
        let remote = chosenRemote, name = chosenBranch
        switch action {
        case .pull: operation(success: "Pull が完了しました。") { try $0.pull(remote) }
        case .push: operation(success: "Push が完了しました。") { try $0.push(remote) }
        case .fetch: operation(success: "Fetch が完了しました。") { try $0.fetch(remote) }
        case .switchBranch: operation(success: "ブランチを切り替えました。") { try $0.switchBranch(name) }
        case .clone:
            let source = cloneSource, destination = cloneDestination
            perform({ try Snapshot(GitRepository.clone(source, destination)) }, success: "Clone が完了しました。閉じて作業を始められます。") { state in
                self.request = LaunchRequest(action: .clone, paths: []); self.initialSelection = true; self.apply(state)
            }
        default: break
        }
    }
}

struct NebulaBackground: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.035, green: 0.05, blue: 0.11)
                RadialGradient(colors: [Color.purple.opacity(0.30), .clear], center: .topTrailing, startRadius: 0, endRadius: geometry.size.width * 0.8)
                RadialGradient(colors: [Color.cyan.opacity(0.12), .clear], center: .bottomLeading, startRadius: 0, endRadius: geometry.size.width * 0.7)
                Canvas { context, size in
                    for index in 0..<65 {
                        let x = CGFloat((index * 137 + 31) % 997) / 997 * size.width
                        let y = CGFloat((index * 251 + 73) % 991) / 991 * size.height
                        let radius: CGFloat = index % 7 == 0 ? 2 : 1
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius)), with: .color(.white.opacity(index % 3 == 0 ? 0.5 : 0.18)))
                    }
                }.accessibilityHidden(true)
            }
        }.allowsHitTesting(false)
    }
}

@MainActor
struct OperationScreen: View {
    @ObservedObject var model: Workspace
    var page: UtilityPage? = nil
    var closeWindow: (() -> Void)? = nil
    @Environment(\.screenActions) private var navigation
    @State private var showEditor = false
    @State private var editPath = ""
    @State private var resolution = ""
    private let accent = Color(red: 0.70, green: 0.62, blue: 1)
    private var remoteAction: Bool { [.pull, .push, .fetch].contains(model.action) }
    private var filesAction: Bool { page == .files || page == nil && [.commit, .diff].contains(model.action) }
    private var title: String { page?.title ?? model.action.title }
    private var hint: String { page?.hint ?? model.action.hint }
    func prompt(_ title: String, _ labels: [String], done: ([String]) -> Void) {
        let alert = NSAlert(); alert.messageText = title
        alert.addButton(withTitle: "実行"); alert.addButton(withTitle: "キャンセル")
        let stack = NSStackView(); stack.orientation = .vertical
        let fields = labels.map { label -> NSTextField in
            let field = NSTextField(string: ""); field.placeholderString = label
            field.widthAnchor.constraint(equalToConstant: 420).isActive = true
            stack.addArrangedSubview(field); return field
        }
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: labels.count * 34); alert.accessoryView = stack
        if alert.runModal() == .alertFirstButtonReturn { done(fields.map(\.stringValue)) }
    }
    func confirm(_ text: String, done: () -> Void) {
        let alert = NSAlert(); alert.messageText = text; alert.alertStyle = .warning
        alert.addButton(withTitle: "実行"); alert.addButton(withTitle: "キャンセル")
        if alert.runModal() == .alertFirstButtonReturn { done() }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                if navigation.canGoBack {
                    Button(action: navigation.back) { Label("戻る", systemImage: "chevron.left") }
                        .keyboardShortcut("[", modifiers: .command).accessibilityIdentifier("navigateBack")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Label(title, systemImage: model.action.symbol).font(.title2.bold())
                    Text(hint).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Label("GitNebula", systemImage: "sparkles").font(.caption.bold()).foregroundStyle(accent)
            }
            if model.action != .clone && (model.repository == nil || [.open, .initialize].contains(model.action)) { repositoryForm }
            if let repo = model.repository, ![.clone, .initialize].contains(model.action) {
                HStack {
                    Label(URL(fileURLWithPath: repo.path).lastPathComponent, systemImage: "folder")
                    Label(model.branch, systemImage: "arrow.triangle.branch").foregroundStyle(accent)
                    Text(repo.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(repo.path)
                    Spacer()
                    Button("更新", action: model.refresh)
                }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            if model.action == .clone { cloneForm }
            else if model.action == .initialize {
                Text("上の欄に作成済みフォルダのパスを入力するか、「参照…」で選び、リポジトリを作成してください。既存リポジトリ内には作成しません。")
                Button("このフォルダにリポジトリを作成", action: model.initializeRepository).buttonStyle(.borderedProminent).disabled(model.repositoryPath.isEmpty)
            }
            else if model.action == .open { launcher }
            else if model.repository == nil {
                VStack(spacing: 18) {
                    Image(systemName: "folder.badge.questionmark").font(.system(size: 40)).foregroundStyle(accent)
                    Text("操作するリポジトリを選択してください。")
                    Button("フォルダを選択", action: model.chooseRepository).buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let page {
                    switch page {
                    case .files: filePanel
                    case .branches: branchForm
                    case .conflicts: conflictForm
                    case .identity: IdentitySettingsView(model: model)
                    case .tool(let tool): RepositoryToolsView(model: model, tool: tool)
                    }
                } else {
                    if remoteAction { ScrollView { RemoteOperationView(model: model) } }
                    if model.action == .switchBranch { BranchSelectionView(model: model) }
                    if filesAction { filePanel }
                    if model.action == .log, let repo = model.repository { HistoryBrowserView(repo: repo, branches: model.branches, refreshID: model.revisionID) }
                    if [.stash, .tags, .remotes].contains(model.action) { RepositoryToolsView(model: model).id(model.action) }
                    if model.action == .tools || model.action == .workspace { FunctionLauncher(management: model.action == .workspace) }
                    if model.action == .commit {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("コミットメッセージ").font(.headline)
                            TextField("変更内容を短く説明してください", text: $model.message).textFieldStyle(.roundedBorder).accessibilityIdentifier("commitMessage")
                            HStack {
                                Text("\(model.selected.count) ファイルを選択").foregroundStyle(.secondary)
                                Spacer()
                                Button("コミット", action: model.commit).buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                                    .disabled(model.selected.isEmpty || model.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.sequence != nil)
                            }
                        }
                    }
                }
                if page != .conflicts && (model.sequence != nil || !model.conflicts.isEmpty) {
                    HStack {
                        Text("競合または進行中の Git 操作があります。").foregroundStyle(.orange)
                        Button("競合の解決を開く") { navigation.openUtility(.conflicts) }
                    }
                }
            }
            if [.clone, .initialize].contains(model.action) || page == .branches || page == .conflicts { Spacer(minLength: 0) }
            Divider()
            HStack(alignment: .top) {
                if model.busy { ProgressView().controlSize(.small) }
                else { Image(systemName: model.failed ? "exclamationmark.circle" : model.succeeded ? "checkmark.circle.fill" : "sparkle").foregroundStyle(model.failed ? .orange : accent) }
                ScrollView { Text(model.status).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: model.failed ? 90 : 38)
                Button("閉じる") { navigation.close() }.keyboardShortcut(.cancelAction)
            }
        }
        .navigationTitle(title + " — GitNebula")
        .padding(16).frame(minWidth: 1050, idealWidth: 1220, minHeight: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NebulaBackground()).foregroundStyle(Color(red: 0.91, green: 0.92, blue: 0.98)).disabled(model.busy).tint(accent).environment(\.colorScheme, .dark).preferredColorScheme(.dark)
        .sheet(isPresented: $showEditor) {
            VStack {
                Text(editPath).font(.headline)
                TextEditor(text: $resolution).font(.system(.body, design: .monospaced))
                HStack {
                    Button("キャンセル") { showEditor = false }
                    Button("保存して解決") { let file = editPath, text = resolution; showEditor = false; model.operation { try $0.saveResolution(file, text) } }
                }
            }.padding().frame(width: 800, height: 520).preferredColorScheme(.dark)
        }
    }
    private var launcher: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            FinderIntegrationView()
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(GitAction.allCases.filter { $0 != .open }, id: \.self) { action in
                    Button { navigation.openAction(action) } label: {
                        Label(action.title, systemImage: action.symbol).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.buttonStyle(.bordered).disabled(model.repository == nil && ![.clone, .initialize].contains(action))
                }
            }
        }
        }
    }
    private var repositoryForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("リポジトリのパス").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("~/Projects/my-repo", text: $model.repositoryPath)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("repositoryPath")
                    .onSubmit { model.openEnteredPath() }
                if model.action != .initialize { Button("開く", action: model.openEnteredPath).disabled(model.repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                Button("参照…", action: model.chooseRepository)
            }
        }
    }
    private var cloneForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("取得元 URL / パス"); TextField("https://… / ローカルのパス", text: $model.cloneSource).textFieldStyle(.roundedBorder)
            Text("作成先（新しいフォルダ）"); TextField("/path/to/new-repository", text: $model.cloneDestination).textFieldStyle(.roundedBorder)
            Button("親フォルダを選択…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url { model.cloneDestination = url.appendingPathComponent("new-repository").path }
            }
            Button("Clone", action: model.runAction).buttonStyle(.borderedProminent).disabled(model.cloneSource.isEmpty || model.cloneDestination.isEmpty || model.succeeded)
        }
    }
    private var branchForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("切り替え先", selection: $model.chosenBranch) { ForEach(model.branches, id: \.self) { Text($0 == model.branch ? "\($0)（現在）" : $0).tag($0) } }
            Button("切り替え") { let name = model.chosenBranch; model.operation { try $0.switchBranch(name) } }.disabled(model.chosenBranch.isEmpty || model.chosenBranch == model.branch)
            if page == .branches {
                HStack {
                    Button("ブランチ作成") { prompt("ブランチを作成して切替", ["名前"]) { values in model.operation { try $0.createBranch(values[0]) } } }
                    Button("名前変更") { let old = model.chosenBranch; prompt("ブランチ名を変更", ["新しい名前"]) { values in model.operation { try $0.renameBranch(old, values[0]) } } }
                    Button("削除") { let name = model.chosenBranch; confirm("\(name) を削除します（マージ済みのみ）。") { model.operation { try $0.deleteBranch(name) } } }
                    Button("現在のブランチにマージ") { let name = model.chosenBranch; model.operation { try $0.merge(name) } }
                }
            }
        }
    }
    private var filePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("対象の変更  ·  \(model.visibleChanges.count) ファイル").font(.headline)
                Spacer()
                if model.action == .commit || page == .files {
                    Button("すべて選択") { model.selected = Set(model.visibleChanges.map(\.path)) }
                    Button("選択解除") { model.selected.removeAll() }
                }
            }
            if page == .files {
                HStack {
                    Button("ステージ") { let files = Array(model.selected); model.operation { try $0.stage(files) } }
                    Button("ステージ解除") { let files = Array(model.selected); model.operation { try $0.unstage(files) } }
                    Button("無視リストに追加") { let files = Array(model.selected); model.operation { try $0.ignore(files) } }
                    Button("変更を破棄") {
                        let files = Array(model.selected)
                        confirm("選択した \(files.count) ファイルの変更を破棄し、HEAD の内容に戻します。未コミットの変更は復元できません。") { model.operation { try $0.discard(files) } }
                    }
                }.disabled(model.selected.isEmpty || model.sequence != nil)
            }
            if let repo = model.repository {
                ChangedFilesView(repo: repo, files: model.visibleChanges,
                                 allowsChecking: model.action == .commit || page == .files, checked: $model.selected)
                    .frame(minHeight: 260, maxHeight: .infinity)
            }
        }.frame(maxHeight: .infinity).layoutPriority(1)
    }
    private var conflictForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.sequence != nil || !model.conflicts.isEmpty {
                Text(model.conflicts.isEmpty ? "競合はありません。\(model.sequence?.title ?? "操作") を完了してください。" : "競合があります。内容を確認して解決してください。").foregroundStyle(.orange)
            }
            if model.conflicts.isEmpty && model.sequence == nil { Text("解決が必要な競合や進行中の操作はありません。") }
            if !model.conflicts.isEmpty {
                Picker("競合", selection: $model.chosenConflict) { ForEach(model.conflicts, id: \.self) { Text($0).tag($0) } }
                HStack {
                    Button("競合を編集") {
                        let file = model.chosenConflict
                        if let repo = model.repository { model.perform({ try repo.conflictText(file) }) { resolution = $0; editPath = file; showEditor = true } }
                    }
                    Button("外部で解決済み") { let file = model.chosenConflict; confirm("現在の内容（削除を含む）を解決済みとしてステージします。") { model.operation { try $0.markResolved(file) } } }
                }
            }
            if model.merging {
                HStack {
                    Button("マージ完了") { prompt("マージコミット（ステージ済みの全変更を含みます）", ["コミットメッセージ"]) { values in model.operation { try $0.finishMerge(values[0]) } } }.disabled(!model.conflicts.isEmpty)
                    Button("マージ中止") { confirm("競合解決作業を破棄してマージを中止します。") { model.operation { try $0.abortMerge() } } }
                }
            }
            if let sequence = model.sequence, sequence != .merge {
                HStack {
                    Button("\(sequence.title) を再開") { model.operation { try $0.continueSequence() } }.disabled(!model.conflicts.isEmpty)
                    Button("\(sequence.title) を中止") { confirm("競合解決作業を破棄して \(sequence.title) を中止します。") { model.operation { try $0.abortSequence() } } }
                }
            }
        }
    }
}

// Each subsequent Finder action gets its own model; drafts and running operations
// in another dialog must survive a new context-menu invocation.
@MainActor
final class ActionWindows: NSObject, NSWindowDelegate {
    static let shared = ActionWindows()
    private var windows: [ObjectIdentifier: (NSWindowController, ScreenNavigation)] = [:]
    func open(_ request: LaunchRequest) {
        let model = Workspace()
        let navigation = ScreenNavigation()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = request.action.title + " — GitNebula"; window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: ContentView(model: model, closeWindow: { [weak window] in window?.performClose(nil) }, navigation: navigation))
        let controller = NSWindowController(window: window)
        windows[ObjectIdentifier(window)] = (controller, navigation)
        model.launch(request); window.center(); controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !(windows[ObjectIdentifier(sender)]?.1.busy ?? false) }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { windows.removeValue(forKey: ObjectIdentifier(window)) }
    }
}

@main
struct GitNebulaApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate
    @StateObject private var model = Workspace()
    @StateObject private var navigation = ScreenNavigation()
    @State private var handledArguments = false
    var body: some Scene {
        WindowGroup {
            ContentView(model: model, navigation: navigation)
                // Route Finder URLs through the existing scene. Without this,
                // SwiftUI creates an extra copy of the shared workspace window.
                .handlesExternalEvents(preferring: ["gitnebula://"], allowing: ["gitnebula://"])
                .onOpenURL { url in
                    do {
                        let request = try LaunchRequest.parse(url)
                        handledArguments = true
                        if navigation.canReuseLauncher(model) { model.launch(request) }
                        else { ActionWindows.shared.open(request) }
                    }
                    catch { model.status = error.localizedDescription; model.failed = true }
                }
                .onAppear {
                    guard !handledArguments else { return }; handledArguments = true
                    do { model.launch(try LaunchRequest.parse(Array(CommandLine.arguments.dropFirst()))) }
                    catch { model.status = error.localizedDescription; model.failed = true }
                }
        }.windowStyle(.titleBar).defaultSize(width: 1220, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("リポジトリを開く…") { ActionWindows.shared.open(LaunchRequest(action: .open, paths: [])) }.keyboardShortcut("o")
                Button("新しい操作ウィンドウ") { ActionWindows.shared.open(LaunchRequest(action: .open, paths: [])) }.keyboardShortcut("n")
            }
        }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A SwiftPM executable is not launched by LaunchServices. It still needs
        // a regular, active application to accept keyboard input and paste.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
    }
}
