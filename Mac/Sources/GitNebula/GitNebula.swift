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
    let head: String?
    static func afterOperation(_ repo: GitRepository) throws -> Snapshot {
        do { return try Snapshot(repo) }
        catch { throw repo.failure(L("Git 操作は完了しましたが、画面の更新に失敗しました。操作を再実行せず「更新」で確認してください。\n") + error.localizedDescription) }
    }
    init(_ repo: GitRepository) throws {
        self.repo = repo; changes = try repo.changes()
        branch = try repo.currentBranch()
        graph = try repo.graph(); branches = try repo.branches(); remotes = try repo.remotes()
        conflicts = try repo.conflicts(); merging = try repo.mergeInProgress(); preferredRemote = try repo.preferredRemote()
        sequence = try repo.sequence(); head = try repo.headRevision()
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
        if action == .push, let repository { return LaunchRequest(action: action, paths: [repository.path]) }
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
    @Published var status = L("準備完了")
    @Published var busy = false
    @Published var succeeded = false
    @Published private(set) var commitCompleted = false
    @Published var failed = false
    @Published var missingRepository = false
    @Published var cloneSource = ""
    @Published var cloneParent = ""
    var cloneDestination: String { (try? CloneLocation.destination(parent: cloneParent, source: cloneSource)) ?? "" }
    @Published var repositoryPath = ""
    @Published var sequence: GitSequence?
    @Published var revisionID = UUID()
    @Published var head: String?
    @Published var transferReport: RemoteOperationReport?
    @Published var transferProgress: GitTransferProgress?
    private var transferProgressID: UUID?
    var canRunRemote: Bool {
        !busy && !chosenRemote.isEmpty && remotes.contains(chosenRemote) && (action == .fetch || head != nil && branch != "detached HEAD" && (action != .pull || changes.isEmpty && sequence == nil && conflicts.isEmpty))
    }
    private var request = LaunchRequest(action: .open, paths: [])
    private var initialSelection = true
    var visibleChanges: [Change] {
        changes.filter { action == .workspace || request.includes($0.path, root: repository?.path ?? "/") }
    }
    func apply(_ state: Snapshot) {
        repository = state.repo; if ApplicationDelegate.shared != nil { HomeScreen.remember(state.repo.path) }; changes = state.changes; branch = state.branch; graph = state.graph
        branches = state.branches; remotes = state.remotes; conflicts = state.conflicts; merging = state.merging
        sequence = state.sequence; head = state.head; revisionID = UUID()
        chosenBranch = branches.contains(chosenBranch) ? chosenBranch : branches.first(where: { $0 != branch }) ?? branch
        if !remotes.contains(chosenRemote) { chosenRemote = state.preferredRemote }
        if !conflicts.contains(chosenConflict) { chosenConflict = conflicts.first ?? "" }
        let available = Set(visibleChanges.map(\.path))
        selected = initialSelection ? available : selected.intersection(available)
        initialSelection = false
    }
    func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T, success: String = L("準備完了"), notifiesChanges: Bool = false, message: ((T) -> String)? = nil, apply: @escaping (T) -> Void) {
        guard !busy else { return }; busy = true; succeeded = false; failed = false; status = L("処理中…")
        if transferProgressID == nil { transferProgress = nil }
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try work() }.value
                apply(result); status = message?(result) ?? success; succeeded = status != L("準備完了")
                if notifiesChanges { notifyRepositoryChanged() }
            } catch {
                missingRepository = error is MissingGitRepository
                let message = error.localizedDescription
                var refreshError = ""
                if let repo = repository {
                    do { self.apply(try await Task.detached(operation: { try Snapshot(repo) }).value) }
                    catch { refreshError = L("\n画面の更新にも失敗しました: ") + error.localizedDescription }
                }
                status = message + refreshError; failed = true
                if notifiesChanges { notifyRepositoryChanged() }
            }
            busy = false
            if transferProgressID != nil {
                transferProgress = failed ? .failed : .completed
                transferProgressID = nil
            }
            if isScreenActive { refreshIfNeeded() }
        }
    }
    func launch(_ newRequest: LaunchRequest) {
        guard !busy else { return }
        launchID = UUID(); request = newRequest; action = request.action; initialSelection = true
        repository = nil; changes = []; selected = []; conflicts = []; merging = false; chosenRemote = ""; chosenBranch = ""
        sequence = nil; head = nil; transferReport = nil; transferProgress = nil; transferProgressID = nil
        message = ""; status = L("準備完了"); succeeded = false; failed = false; commitCompleted = false; missingRepository = false
        if action == .clone {
            cloneParent = request.paths.first.map(LaunchRequest.directory) ?? NSHomeDirectory()
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
                    throw repo.failure(L("同じリポジトリ内のファイルを選択してください。"))
                }
            }
            return try Snapshot(repo)
        }, apply: apply)
    }
    func chooseRepository() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.title = L("Git リポジトリを選択"); panel.prompt = L("開く")
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
        perform({ try Snapshot.afterOperation(GitRepository.initialize(path)) }, success: L("リポジトリを作成しました。ファイルを追加してコミットできます。")) { state in
            self.request = LaunchRequest(action: .commit, paths: [state.repo.path]); self.action = .commit; self.initialSelection = true
            self.repositoryPath = state.repo.path; self.apply(state)
        }
    }
    func adoptRepository(_ repo: GitRepository) {
        guard !busy else { return }
        request = LaunchRequest(action: .open, paths: [repo.path])
        repository = repo; repositoryPath = repo.path; initialSelection = true
        selectAction(.open); refresh()
    }
    func selectAction(_ value: GitAction) {
        action = value; selected.formIntersection(Set(visibleChanges.map(\.path))); status = L("準備完了"); succeeded = false; failed = false; transferReport = nil; transferProgress = nil; commitCompleted = false
        if value == .clone, cloneParent.isEmpty {
            cloneParent = repository?.path ?? NSHomeDirectory()
        }
    }
    func operation(success: String = L("完了しました。"), _ work: @escaping @Sendable (GitRepository) throws -> Void) {
        guard let repo = repository else { return }
        perform({ try work(repo); return try Snapshot.afterOperation(repo) }, success: success, notifiesChanges: true) { state in
            self.apply(state)
        }
    }
    func commit() {
        let paths = Array(selected.intersection(Set(visibleChanges.map(\.path)))), text = message
        guard !busy, let repo = repository else { return }
        commitCompleted = false
        perform({ try repo.commit(paths, text); return try Snapshot.afterOperation(repo) }, success: L("コミットしました。"), notifiesChanges: true) {
            self.apply($0); self.message = ""; self.commitCompleted = true
        }
    }
    func runAction() {
        guard !busy else { return }
        let remote = chosenRemote, name = chosenBranch
        switch action {
        case .pull, .push, .fetch:
            guard let repo = repository else { return }
            let action = action; transferReport = nil
            let progress = beginTransferProgress()
            perform({ let report = try repo.transfer(action, remote: remote, progress: progress); return (try Snapshot.afterOperation(repo), report) }, notifiesChanges: true, message: { $0.1.summary }) {
                self.apply($0.0); self.transferReport = $0.1
            }
        case .switchBranch: operation(success: L("ブランチを切り替えました。")) { try $0.switchBranch(name) }
        case .clone:
            let source = cloneSource, parent = cloneParent
            let progress = beginTransferProgress()
            perform({
                let destination = try CloneLocation.destination(parent: parent, source: source)
                return try Snapshot.afterOperation(GitRepository.clone(source, destination, progress: progress))
            }, success: L("Clone が完了しました。閉じて作業を始められます。")) { state in
                self.request = LaunchRequest(action: .clone, paths: []); self.initialSelection = true; self.apply(state)
            }
        default: break
        }
    }
    private func beginTransferProgress() -> @Sendable (GitTransferProgress) -> Void {
        let id = UUID(); transferProgressID = id; transferProgress = .connecting
        return { [weak self] progress in
            DispatchQueue.main.async {
                guard let self, self.transferProgressID == id, self.busy else { return }
                self.transferProgress = progress
            }
        }
    }
}

@MainActor
struct OperationScreen: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @ObservedObject var model: Workspace
    var page: UtilityPage? = nil
    var closeWindow: (() -> Void)? = nil
    @Environment(\.screenActions) private var navigation
    @State private var showEditor = false
    @State private var editPath = ""
    @State private var resolution = ""
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { colorScheme == .dark ? Color(red: 0.70, green: 0.62, blue: 1) : Color(red: 0.42, green: 0.24, blue: 0.72) }
    private var remoteAction: Bool { [.pull, .push, .fetch].contains(model.action) }
    private var title: String { page?.title ?? model.action.title }
    private var hint: String { page?.hint ?? model.action.hint }
    func prompt(_ title: String, _ labels: [String], done: ([String]) -> Void) {
        let alert = NSAlert(); alert.messageText = title
        alert.addButton(withTitle: L("実行")); alert.addButton(withTitle: L("キャンセル"))
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
        alert.addButton(withTitle: L("実行")); alert.addButton(withTitle: L("キャンセル"))
        if alert.runModal() == .alertFirstButtonReturn { done() }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.action != .open || page != nil {
                HStack(alignment: .top) {
                    if navigation.canGoBack {
                        Button(action: navigation.back) { Label(L("戻る"), systemImage: "chevron.left") }
                            .keyboardShortcut("[", modifiers: .command).accessibilityIdentifier("navigateBack")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Label(title, systemImage: model.action.symbol).font(.title2.bold()).lineLimit(1)
                        Text(hint).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if model.repository != nil && page != .settings {
                        Menu(L("Git 操作")) {
                            ForEach(GitAction.menuGroups, id: \.title) { group in
                                Menu(group.title) { ForEach(group.actions, id: \.self) { action in Button(action.title) { navigation.openAction(action) } } }
                            }
                        }.fixedSize().accessibilityIdentifier("operationMenu")
                        if model.action != .commit { Button("Commit") { navigation.openAction(.commit) }.accessibilityIdentifier("openCommit") }
                    }
                    Button(L("アプリ画面"), action: navigation.home)
                    Label("GitNebula", systemImage: "sparkles").font(.caption.bold()).foregroundStyle(accent)
                }
            }
            if page != .settings && ![.open, .clone].contains(model.action) && (model.repository == nil || model.action == .initialize) { repositoryForm }
            if let repo = model.repository, page != .settings, ![.open, .clone, .initialize].contains(model.action) {
                HStack {
                    Label(URL(fileURLWithPath: repo.path).lastPathComponent, systemImage: "folder")
                    Label(model.branch, systemImage: "arrow.triangle.branch").foregroundStyle(accent)
                    Text(repo.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(repo.path)
                    Spacer()
                    Button(L("更新"), action: model.refresh)
                }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            if page == .settings { AppSettingsView() }
            else if model.action == .clone { cloneForm }
            else if model.action == .initialize {
                Text(L("上の欄に作成済みフォルダのパスを入力するか、「参照…」で選び、リポジトリを作成してください。既存リポジトリ内には作成しません。"))
                Button(L("このフォルダにリポジトリを作成"), action: model.initializeRepository).buttonStyle(.borderedProminent).disabled(model.repositoryPath.isEmpty)
            }
            else if model.action == .open { launcher }
            else if model.repository == nil {
                VStack(spacing: 18) {
                    Image(systemName: "folder.badge.questionmark").font(.system(size: 40)).foregroundStyle(accent)
                    Text(model.missingRepository ? L("Git の履歴がないフォルダです。") : L("操作するリポジトリを選択してください。"))
                    if model.missingRepository { Button("Clone") { navigation.openAction(.clone) } }
                    Button(L("フォルダを選択"), action: model.chooseRepository).buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let page {
                    switch page {
                    case .files: filePanel
                    case .branches: branchForm
                    case .conflicts: conflictForm
                    case .identity: IdentitySettingsView(model: model)
                    case .settings: AppSettingsView()
                    case .repositoryActions: RepositoryActionLauncher()
                    case .tool(let tool): RepositoryToolsView(model: model, tool: tool)
                    }
                } else {
                    switch model.action {
                    case .pull, .push, .fetch: ScrollView { RemoteOperationView(model: model) }
                    case .switchBranch: BranchSelectionView(model: model)
                    case .commit, .diff: filePanel
                    case .log:
                        if let repo = model.repository { HistoryBrowserView(repo: repo, branches: model.branches, refreshID: model.revisionID, model: model) }
                    case .graph:
                        if let repo = model.repository { GitGraphView(repo: repo, refreshID: model.revisionID) }
                    case .cherryPick, .revert: CommitOperationView(model: model)
                    case .rebase, .merge: BranchIntegrationView(model: model)
                    case .stash, .tags, .remotes: RepositoryToolsView(model: model).id(model.action)
                    case .tools, .workspace: FunctionLauncher(management: model.action == .workspace)
                    default: EmptyView()
                    }
                    if model.action == .commit {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("コミットメッセージ")).font(.headline)
                            TextField(L("変更内容を短く説明してください"), text: $model.message).textFieldStyle(.roundedBorder).accessibilityIdentifier("commitMessage")
                            HStack {
                                Text(L("\(model.selected.count) ファイルを選択")).foregroundStyle(.secondary)
                                Spacer()
                                Button(L("コミット"), action: model.commit).buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                                    .accessibilityIdentifier("executeCommit")
                                    .disabled(model.selected.isEmpty || model.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.sequence != nil)
                            }
                        }
                    }
                }
                if page != .conflicts && (model.sequence != nil || !model.conflicts.isEmpty) {
                    HStack {
                        Text(L("競合または進行中の Git 操作があります。")).foregroundStyle(.orange)
                        Button(L("競合の解決を開く")) { navigation.openUtility(.conflicts) }
                    }
                }
            }
            if [.clone, .initialize].contains(model.action) || page == .branches || page == .conflicts { Spacer(minLength: 0) }
            if model.action != .open || page != nil {
                Divider()
                HStack(alignment: .top) {
                    if model.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.failed ? "exclamationmark.circle" : model.succeeded ? "checkmark.circle.fill" : "sparkle").foregroundStyle(model.failed ? .orange : accent) }
                    ScrollView { Text(LT(model.status)).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: model.failed ? 90 : 38)
                    if model.failed && (remoteAction || model.action == .clone) {
                        Button(L("SSH の設定")) { navigation.openUtility(.settings) }
                    }
                    if model.action == .commit && model.commitCompleted {
                        Button("Push") { navigation.openAction(.push) }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("pushAfterCommit")
                    }
                    Button(L("閉じる")) { navigation.close() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(16).frame(minWidth: 1050, idealWidth: 1220, minHeight: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NebulaBackground()).foregroundStyle(.primary).disabled(model.busy).tint(accent)
        .sheet(isPresented: $showEditor) {
            VStack {
                Text(editPath).font(.headline)
                TextEditor(text: $resolution).font(.system(.body, design: .monospaced))
                HStack {
                    Button(L("キャンセル")) { showEditor = false }
                    Button(L("保存して解決")) { let file = editPath, text = resolution; showEditor = false; model.operation { try $0.saveResolution(file, text) } }
                }
            }.padding().frame(width: 800, height: 520)
        }
    }
    private var launcher: some View { HomeScreen(model: model) }
    private var repositoryForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("リポジトリのパス")).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("~/Projects/my-repo", text: $model.repositoryPath)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("repositoryPath")
                    .onSubmit { model.openEnteredPath() }
                if model.action != .initialize { Button(L("開く"), action: model.openEnteredPath).disabled(model.repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                Button(L("参照…"), action: model.chooseRepository)
            }
        }
    }
    private var cloneForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("取得元 URL / パス")); TextField(L("https://… / ローカルのパス"), text: $model.cloneSource).textFieldStyle(.roundedBorder).accessibilityIdentifier("cloneSource")
            Text(L("保存先（親フォルダ）")); TextField("~/Projects", text: $model.cloneParent).textFieldStyle(.roundedBorder).accessibilityIdentifier("cloneParent")
            Text(L("この中にリポジトリ用のフォルダを作ります。既存のファイルやフォルダはそのまま残ります。")).font(.caption).foregroundStyle(.secondary)
            Button(L("保存先を選択…")) {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                if let path = try? LaunchRequest.inputPath(model.cloneParent) { panel.directoryURL = URL(fileURLWithPath: path) }
                if panel.runModal() == .OK, let url = panel.url { model.cloneParent = url.path }
            }
            Text(L("実際の作成先: ") + (model.cloneDestination.isEmpty ? L("取得元と保存先を指定してください") : model.cloneDestination)).textSelection(.enabled).accessibilityIdentifier("cloneDestination")
            if model.repository != nil { Button(L("複製したリポジトリをホームで開く"), action: navigation.home) }
            Button("Clone", action: model.runAction).buttonStyle(.borderedProminent).accessibilityIdentifier("cloneExecute").disabled(model.cloneSource.isEmpty || model.cloneDestination.isEmpty || model.busy)
            if let progress = model.transferProgress { GitTransferProgressView(progress: progress, busy: model.busy) }
        }
    }
    private var branchForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("切り替え先"), selection: $model.chosenBranch) { ForEach(model.branches, id: \.self) { Text($0 == model.branch ? L("\($0)（現在）") : $0).tag($0) } }
            Button(L("切り替え")) { let name = model.chosenBranch; model.operation { try $0.switchBranch(name) } }.disabled(model.chosenBranch.isEmpty || model.chosenBranch == model.branch)
            if page == .branches {
                HStack {
                    Button(L("ブランチ作成")) { prompt(L("ブランチを作成して切替"), [L("名前")]) { values in model.operation { try $0.createBranch(values[0]) } } }
                    Button(L("名前変更")) { let old = model.chosenBranch; prompt(L("ブランチ名を変更"), [L("新しい名前")]) { values in model.operation { try $0.renameBranch(old, values[0]) } } }
                    Button(L("削除")) { let name = model.chosenBranch; confirm(L("\(name) を削除します（マージ済みのみ）。")) { model.operation { try $0.deleteBranch(name) } } }
                    Button(L("現在のブランチにマージ")) { let name = model.chosenBranch; model.operation { try $0.merge(name) } }
                }
            }
        }
    }
    private var filePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("対象の変更  ·  \(model.visibleChanges.count) ファイル")).font(.headline)
                Spacer()
                if model.action == .commit || page == .files {
                    Button(L("すべて選択")) { model.selected = Set(model.visibleChanges.map(\.path)) }
                    Button(L("選択解除")) { model.selected.removeAll() }
                }
            }
            if page == .files {
                HStack {
                    Button(L("ステージ")) { let files = Array(model.selected); model.operation { try $0.stage(files) } }
                    Button(L("ステージ解除")) { let files = Array(model.selected); model.operation { try $0.unstage(files) } }
                    Button(L("無視リストに追加")) { let files = Array(model.selected); model.operation { try $0.ignore(files) } }
                    Button(L("変更を破棄")) {
                        let files = Array(model.selected)
                        confirm(L("選択した \(files.count) ファイルの変更を破棄し、HEAD の内容に戻します。未コミットの変更は復元できません。")) { model.operation { try $0.discard(files) } }
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
                Text(model.conflicts.isEmpty ? L("競合はありません。\(model.sequence?.title ?? "操作") を完了してください。") : L("競合があります。内容を確認して解決してください。")).foregroundStyle(.orange)
            }
            if model.conflicts.isEmpty && model.sequence == nil { Text(L("解決が必要な競合や進行中の操作はありません。")) }
            if !model.conflicts.isEmpty {
                Picker(L("競合"), selection: $model.chosenConflict) { ForEach(model.conflicts, id: \.self) { Text($0).tag($0) } }
                HStack {
                    Button(L("競合を編集")) {
                        let file = model.chosenConflict
                        if let repo = model.repository { model.perform({ try repo.conflictText(file) }) { resolution = $0; editPath = file; showEditor = true } }
                    }
                    Button(L("外部で解決済み")) { let file = model.chosenConflict; confirm(L("現在の内容（削除を含む）を解決済みとしてステージします。")) { model.operation { try $0.markResolved(file) } } }
                }
            }
            if model.merging {
                HStack {
                    Button(L("マージ完了")) { prompt(L("マージコミット（ステージ済みの全変更を含みます）"), [L("コミットメッセージ")]) { values in model.operation { try $0.finishMerge(values[0]) } } }.disabled(!model.conflicts.isEmpty)
                    Button(L("マージ中止")) { confirm(L("競合解決作業を破棄してマージを中止します。")) { model.operation { try $0.abortMerge() } } }
                }
            }
            if let sequence = model.sequence, sequence != .merge {
                HStack {
                    Button(L("\(sequence.title) を再開")) { model.operation { try $0.continueSequence() } }.disabled(!model.conflicts.isEmpty)
                    Button(L("\(sequence.title) を中止")) { confirm(L("競合解決作業を破棄して \(sequence.title) を中止します。")) { model.operation { try $0.abortSequence() } } }
                }
            }
        }
    }
}
