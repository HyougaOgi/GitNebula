import SwiftUI

struct GraphEdge: Sendable { let from, to, color: Int }
struct GraphRow: Identifiable, Sendable {
    var id: String { commit.id }
    let commit: CommitRecord
    let lane, color, width: Int
    let incoming, outgoing: [GraphEdge]
}
enum GitGraphLayout {
    static func rows(_ commits: [CommitRecord]) -> [GraphRow] {
        var lanes: [String] = [], colors: [String: Int] = [:], nextColor = 0
        return commits.map { commit in
            let previous = lanes
            if !lanes.contains(commit.id) { lanes.append(commit.id); colors[commit.id] = nextColor; nextColor += 1 }
            let before = lanes, lane = lanes.firstIndex(of: commit.id)!, color = colors[commit.id]!
            lanes.remove(at: lane)
            for (index, parent) in commit.parents.enumerated() where !lanes.contains(parent) {
                lanes.insert(parent, at: min(lane + index, lanes.count))
                colors[parent] = index == 0 ? color : nextColor
                if index > 0 { nextColor += 1 }
            }
            let incoming = previous.enumerated().map { GraphEdge(from: $0.offset, to: before.firstIndex(of: $0.element)!, color: colors[$0.element] ?? color) }
            var outgoing = before.enumerated().compactMap { index, id -> GraphEdge? in
                guard id != commit.id, let to = lanes.firstIndex(of: id) else { return nil }
                return GraphEdge(from: index, to: to, color: colors[id] ?? color)
            }
            outgoing += commit.parents.compactMap { parent in lanes.firstIndex(of: parent).map { GraphEdge(from: lane, to: $0, color: colors[parent] ?? color) } }
            return GraphRow(commit: commit, lane: lane, color: color, width: max(before.count, lanes.count), incoming: incoming, outgoing: outgoing)
        }
    }
}

struct GraphLaneView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let row: GraphRow
    let columns: Int
    static let colors: [Color] = [.purple, .cyan, .orange, .green, .pink, .blue]
    var body: some View {
        Canvas { context, size in
            let center = size.height / 2
            func x(_ lane: Int) -> CGFloat { CGFloat(lane) * 20 + 14 }
            for edge in row.incoming {
                var path = Path(); path.move(to: CGPoint(x: x(edge.from), y: 0)); path.addLine(to: CGPoint(x: x(edge.to), y: center))
                context.stroke(path, with: .color(Self.colors[edge.color % Self.colors.count]), lineWidth: 2)
            }
            for edge in row.outgoing {
                var path = Path(); path.move(to: CGPoint(x: x(edge.from), y: center)); path.addCurve(to: CGPoint(x: x(edge.to), y: size.height), control1: CGPoint(x: x(edge.from), y: center + 10), control2: CGPoint(x: x(edge.to), y: size.height - 10))
                context.stroke(path, with: .color(Self.colors[edge.color % Self.colors.count]), lineWidth: 2)
            }
            let node = Path(ellipseIn: CGRect(x: x(row.lane) - 5, y: center - 5, width: 10, height: 10))
            context.fill(node, with: .color(Self.colors[row.color % Self.colors.count]))
        }.frame(width: CGFloat(columns) * 20 + 20, height: 48).accessibilityHidden(true)
    }
}
@MainActor struct GitGraphView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let repo: GitRepository
    let refreshID: UUID
    @State private var rows: [GraphRow] = []
    @State private var selection: String?
    @State private var limit = 200
    @State private var error: String?
    @State private var loading = false
    @State private var spatial: Bool
    @Environment(\.screenActions) private var navigation
    private static let displayPreference = "graphSpatialDisplay"
    init(repo: GitRepository, refreshID: UUID) {
        self.repo = repo; self.refreshID = refreshID
        _spatial = State(initialValue: UserDefaults.standard.bool(forKey: Self.displayPreference))
    }
    private var columns: Int { max(1, rows.map(\.width).max() ?? 1) }
    private var selectedCommit: CommitRecord? { rows.first { $0.id == selection }?.commit }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("表示"), selection: $spatial) {
                Text(L("通常")).tag(false)
                Text("4D").tag(true)
            }.pickerStyle(.segmented).frame(width: 180).accessibilityIdentifier("graphDisplayMode")
            if let error { Text(error).foregroundStyle(.orange) }
            if rows.isEmpty && !loading { Text(L("まだコミットはありません。")) }
            VSplitView {
                Group {
                    if spatial {
                        if !rows.isEmpty { NebulaGraph4D(rows: rows, selection: $selection) }
                        else { Spacer() }
                    } else { standardGraph }
                }.frame(minHeight: 250, maxHeight: .infinity)
                if let commit = selectedCommit {
                    CommitDetailsView(commit: commit).frame(minHeight: 150, idealHeight: 210, maxHeight: 350)
                }
            }
            HStack {
                Text(L("\(rows.count) コミット")).foregroundStyle(.secondary)
                Spacer()
                if let id = selection { Button(L("コミットを開く")) { navigation.openRevision(repo, id, false) } }
                if rows.count >= limit { Button(L("さらに読み込む")) { limit += 200 } }
                if loading { ProgressView().controlSize(.small) }
            }
        }.onChange(of: spatial) { UserDefaults.standard.set($0, forKey: Self.displayPreference) }
        .task(id: [refreshID.uuidString, String(limit)]) {
            loading = true; error = nil
            do {
                let repo = repo, count = limit
                let records = try await Task.detached { try repo.history(limit: count, topological: true) }.value
                if !Task.isCancelled {
                    rows = GitGraphLayout.rows(records)
                    if !records.contains(where: { $0.id == selection }) { selection = records.first?.id }
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
    }
    private var standardGraph: some View {
        GeometryReader { viewport in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        Button { selection = row.id } label: {
                            HStack(spacing: 12) {
                                GraphLaneView(row: row, columns: columns)
                                Text(row.commit.id).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).frame(width: 340, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.commit.subject).lineLimit(1)
                                    if !row.commit.decorations.isEmpty { Text(row.commit.decorations).font(.caption).foregroundStyle(.purple).lineLimit(1) }
                                }.frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
                                Text(row.commit.author).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                                Text(row.commit.displayDate).font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
                            }.frame(height: 48).padding(.horizontal, 8)
                                .background(selection == row.id ? Color.accentColor.opacity(0.12) : .clear)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { navigation.openRevision(repo, row.id, false) })
                            .accessibilityIdentifier("graphCommit:" + row.id)
                    }
                }.frame(width: max(viewport.size.width, CGFloat(columns) * 20 + 1020))
                    .frame(minHeight: viewport.size.height, alignment: .topLeading)
            }.accessibilityIdentifier("gitGraph")
        }
    }
}
