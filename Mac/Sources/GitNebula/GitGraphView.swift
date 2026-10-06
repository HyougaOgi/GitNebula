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
    @Environment(\.screenActions) private var navigation
    private var columns: Int { max(1, rows.map(\.width).max() ?? 1) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error { Text(error).foregroundStyle(.orange) }
            if rows.isEmpty && !loading { Text(L("まだコミットはありません。")) }
            GeometryReader { viewport in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 12) {
                            GraphLaneView(row: row, columns: columns)
                            Text(row.commit.shortID).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).frame(width: 80)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.commit.subject).lineLimit(1)
                                if !row.commit.decorations.isEmpty { Text(row.commit.decorations).font(.caption).foregroundStyle(.purple).lineLimit(1) }
                            }.frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
                            Text(row.commit.author).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                            Text(row.commit.displayDate).font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
                        }.frame(height: 48).padding(.horizontal, 8)
                            .background(selection == row.id ? Color.accentColor.opacity(0.12) : .clear)
                            .contentShape(Rectangle()).onTapGesture { selection = row.id }
                            .onTapGesture(count: 2) { navigation.openRevision(repo, row.id, false) }
                            .accessibilityElement(children: .combine)
                    }
                }.frame(width: max(viewport.size.width, CGFloat(columns) * 20 + 760))
                    .frame(minHeight: viewport.size.height, alignment: .topLeading)
            }.accessibilityIdentifier("gitGraph")
            }
            HStack {
                Text(L("\(rows.count) コミット")).foregroundStyle(.secondary)
                Spacer()
                if let id = selection { Button(L("コミットを開く")) { navigation.openRevision(repo, id, false) } }
                if rows.count >= limit { Button(L("さらに読み込む")) { limit += 200 } }
                if loading { ProgressView().controlSize(.small) }
            }
        }.task(id: [refreshID.uuidString, String(limit)]) {
            loading = true; error = nil
            do {
                let repo = repo, count = limit
                let records = try await Task.detached { try repo.history(limit: count, topological: true) }.value
                if !Task.isCancelled { rows = GitGraphLayout.rows(records); selection = selection ?? rows.first?.id }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
    }
}
