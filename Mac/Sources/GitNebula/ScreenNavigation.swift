import SwiftUI
import AppKit

struct FileComparisonRequest: Sendable {
    let repo: GitRepository
    let change: Change
    let base: String?
    let target: String?
}

enum UtilityPage: Equatable {
    case files, branches, conflicts, identity, tool(RepositoryTool)
    var title: String {
        switch self {
        case .files: return "作業ファイルの管理"
        case .branches: return "ブランチの管理"
        case .conflicts: return "競合の解決"
        case .identity: return "コミット作成者の設定"
        case .tool(let tool): return tool.title
        }
    }
    var hint: String {
        switch self {
        case .files: return "ステージ・ステージ解除・無視・変更の破棄を行います。"
        case .branches: return "ブランチの作成・名前変更・削除・マージを行います。"
        case .conflicts: return "競合ファイルを解決し、進行中の操作を再開または中止します。"
        case .identity: return "このリポジトリで使用するコミット作成者を設定します。"
        case .tool(let tool): return tool.hint
        }
    }
}

/// Weak callbacks avoid a navigation → retained host → environment → navigation cycle.
struct ScreenActions {
    var canGoBack = false
    var back: () -> Void = {}
    var close: () -> Void = {}
    var openAction: (GitAction) -> Void = { _ in }
    var openUtility: (UtilityPage) -> Void = { _ in }
    var openComparison: (FileComparisonRequest) -> Void = { _ in }
    var openRevision: (GitRepository, String, Bool) -> Void = { _, _, _ in }
}
private struct ScreenActionsKey: EnvironmentKey { static let defaultValue = ScreenActions() }
extension EnvironmentValues {
    var screenActions: ScreenActions {
        get { self[ScreenActionsKey.self] }
        set { self[ScreenActionsKey.self] = newValue }
    }
}

@MainActor
final class ScreenNavigation: ObservableObject {
    final class Frame {
        let id = UUID()
        let host: NSHostingView<AnyView>
        let model: Workspace?
        let title: String
        weak var firstResponder: NSResponder?
        init(host: NSHostingView<AnyView>, model: Workspace?, title: String) { self.host = host; self.model = model; self.title = title }
    }
    @Published private(set) var frames: [Frame] = []
    var current: Frame? { frames.last }
    var busy: Bool { frames.contains { $0.model?.busy == true } }
    func canReuseLauncher(_ model: Workspace) -> Bool {
        frames.count <= 1 && !busy && !model.busy && model.action == .open && model.repository == nil
    }
    private var launchID: UUID?
    private var closeWindow: (() -> Void)?

    func installRoot(_ model: Workspace, close: (() -> Void)?) {
        guard launchID != model.launchID || frames.isEmpty else { return }
        frames.forEach { $0.model?.isScreenActive = false }
        frames = []; launchID = model.launchID; closeWindow = close
        append(OperationScreen(model: model, closeWindow: close), model: model, title: model.action.title)
    }
    private func actions() -> ScreenActions {
        ScreenActions(canGoBack: !frames.isEmpty,
                      back: { [weak self] in self?.back() },
                      close: { [weak self] in
                          guard let self, !self.busy else { return }
                          if let close = self.closeWindow { close() } else { self.current?.host.window?.performClose(nil) }
                      },
                      openAction: { [weak self] in self?.openAction($0) },
                      openUtility: { [weak self] in self?.openUtility($0) },
                      openComparison: { [weak self] in self?.openComparison($0) },
                      openRevision: { [weak self] in self?.openRevision($0, reference: $1, stash: $2) })
    }
    private func append<V: View>(_ view: V, model: Workspace? = nil, title: String) {
        if let previous = current {
            previous.firstResponder = previous.host.window?.firstResponder
            previous.model?.isScreenActive = false
        }
        let host = NSHostingView(rootView: AnyView(view.environment(\.screenActions, actions())))
        host.appearance = NSAppearance(named: .darkAqua)
        let frame = Frame(host: host, model: model, title: title)
        model?.isScreenActive = true
        frames.append(frame)
    }
    func back() {
        guard frames.count > 1, !busy else { return }
        current?.model?.isScreenActive = false
        frames.removeLast()
        current?.model?.isScreenActive = true
        current?.model?.refreshIfNeeded()
    }
    private func childModel(action: GitAction) -> Workspace? {
        guard !busy, let source = frames.reversed().compactMap(\.model).first else { return nil }
        let model = Workspace()
        model.launch(source.request(for: action))
        return model
    }
    func openAction(_ action: GitAction) {
        guard let model = childModel(action: action) else { return }
        append(OperationScreen(model: model, closeWindow: closeWindow), model: model, title: action.title)
    }
    func openUtility(_ page: UtilityPage) {
        guard let model = childModel(action: .workspace) else { return }
        append(OperationScreen(model: model, page: page, closeWindow: closeWindow), model: model, title: page.title)
    }
    func openComparison(_ request: FileComparisonRequest) {
        guard !busy else { return }
        append(DetailScreen(title: "ファイル差分", subtitle: request.change.path) { FileComparisonScreen(request: request) }, title: request.change.path + " — ファイル差分")
    }
    func openRevision(_ repo: GitRepository, reference: String, stash: Bool) {
        guard !busy else { return }
        append(DetailScreen(title: "変更ファイル一覧", subtitle: reference) {
            if stash { StashComparisonView(repo: repo, reference: reference) }
            else { CommitReferenceView(repo: repo, reference: reference) }
        }, title: "変更ファイル一覧")
    }
}

final class RetainedScreenHost: NSView {
    weak var active: NSView?
    func display(_ frame: ScreenNavigation.Frame) {
        guard active !== frame.host else { return }
        active?.removeFromSuperview()
        let view = frame.host
        view.frame = bounds; view.autoresizingMask = [.width, .height]
        addSubview(view); active = view
        window?.title = frame.title + " — GitNebula"
        // The actual table and clip view are retained, including their scroll offsets.
        if let responder = frame.firstResponder { window?.makeFirstResponder(responder) }
        else { window?.makeFirstResponder(view) }
    }
}
struct RouteHost: NSViewRepresentable {
    @ObservedObject var navigation: ScreenNavigation
    func makeNSView(context: Context) -> RetainedScreenHost { RetainedScreenHost() }
    func updateNSView(_ view: RetainedScreenHost, context: Context) {
        if let frame = navigation.current { view.display(frame) }
    }
}

@MainActor
struct ContentView: View {
    @ObservedObject var model: Workspace
    var closeWindow: (() -> Void)?
    @StateObject var navigation: ScreenNavigation
    init(model: Workspace, closeWindow: (() -> Void)? = nil, navigation: ScreenNavigation? = nil) {
        self.model = model; self.closeWindow = closeWindow; _navigation = StateObject(wrappedValue: navigation ?? ScreenNavigation())
    }
    var body: some View {
        RouteHost(navigation: navigation)
            .frame(minWidth: 1050, minHeight: 720)
            .onAppear { navigation.installRoot(model, close: closeWindow) }
            .onChange(of: model.launchID) { _ in navigation.installRoot(model, close: closeWindow) }
    }
}

struct DetailScreen<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    @Environment(\.screenActions) private var navigation
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: navigation.back) { Label("戻る", systemImage: "chevron.left") }
                    .keyboardShortcut("[", modifiers: .command).accessibilityIdentifier("navigateBack")
                Text(title).font(.title2.bold())
                Spacer()
                Label("GitNebula", systemImage: "sparkles").font(.caption).foregroundStyle(.purple)
            }
            Text(subtitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(16).background(NebulaBackground()).foregroundStyle(Color(red: 0.91, green: 0.92, blue: 0.98))
            .tint(Color(red: 0.70, green: 0.62, blue: 1)).environment(\.colorScheme, .dark).preferredColorScheme(.dark)
    }
}

struct FileComparisonScreen: View {
    let request: FileComparisonRequest
    @State private var document: DiffDocument?
    @State private var error: String?
    var body: some View {
        Group {
            if let document { SideBySideDiffView(document: document).id(document.id) }
            else if let error { BrowserPlaceholder(title: "差分を読み込めませんでした", detail: error, symbol: "exclamationmark.triangle") }
            else { ProgressView("変更前後を読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.accessibilityIdentifier("fileComparisonScreen")
        .task {
            guard document == nil else { return }
            let request = request
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try request.repo.comparison(request.change, from: request.base, to: request.target)
                }.value
                if !Task.isCancelled { document = result }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
