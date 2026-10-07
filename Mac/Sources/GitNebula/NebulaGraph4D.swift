import SwiftUI
import AppKit
import SceneKit
import simd

/// Space holds the commit graph; the fourth dimension reveals its history over time.
struct NebulaGraph4D: View {
    let rows: [GraphRow]
    @Binding var selection: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 1.0
    @State private var previousCount = 0
    @State private var playing = false
    @State private var visible = false
    @State private var cameraReset = 0
    private let clock = Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()
    private var count: Int { min(rows.count, max(1, Int(progress))) }
    private var moment: CommitRecord? { rows.isEmpty ? nil : rows[rows.count - count].commit }
    private var branches: [NebulaBranch] { NebulaBranch.group(rows) }
    private var selectedBranch: NebulaBranch? { branches.first { branch in branch.rows.contains { $0.id == selection } } ?? branches.first }
    private var selectedCommit: CommitRecord? { rows.first { $0.id == selection }?.commit }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                NebulaGraphScene(rows: rows, visibleCount: count, selection: $selection, cameraReset: cameraReset)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("gitGraph4D")
                if let branch = selectedBranch {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(branch.title).font(.headline).lineLimit(1)
                        let visible = Set(rows.suffix(count).map(\.id))
                        let logs = branch.rows.filter { visible.contains($0.id) }
                        Text(L("\(logs.count) コミット")).font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 3) {
                                ForEach(logs) { row in
                                    Button { selection = row.id } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(row.commit.subject).lineLimit(2)
                                            HStack {
                                                Text(row.commit.shortID).font(.system(.caption, design: .monospaced))
                                                Spacer()
                                                Text(row.commit.displayDate).font(.caption2)
                                            }.foregroundStyle(.secondary)
                                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(selection == row.id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    }.buttonStyle(.plain).accessibilityIdentifier("graphBranchCommit:" + row.id)
                                }
                            }
                        }
                    }.padding(12).frame(width: 290).frame(maxHeight: .infinity)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("graphBranchLog")
                }
            }
            HStack {
                Text(L("ドラッグで回転・スクロールで接近・ダブルクリックで星へ")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("全体を表示")) { cameraReset += 1 }.accessibilityIdentifier("graphResetCamera")
            }
            if let commit = selectedCommit {
                HStack {
                    Text(commit.shortID).font(.system(.body, design: .monospaced))
                    Text(commit.subject).lineLimit(1)
                    if !commit.decorations.isEmpty { Text(commit.decorations).font(.caption).foregroundStyle(.purple).lineLimit(1) }
                }.accessibilityIdentifier("graphSelectedCommit")
            }
            HStack(spacing: 12) {
                Button(playing ? L("一時停止") : L("履歴を再生")) {
                    if !playing && count == rows.count { progress = 1 }
                    playing.toggle()
                }.disabled(rows.count < 2 || reduceMotion).accessibilityIdentifier("graphPlayTimeline")
                Text(L("時間軸")).font(.caption)
                Slider(value: $progress, in: 1...Double(max(2, rows.count)), step: 1)
                    .disabled(rows.count < 2).accessibilityIdentifier("graphTimeline")
                Text(moment?.displayDate ?? "—").font(.system(.caption, design: .monospaced)).frame(width: 130, alignment: .trailing)
                Text("\(count) / \(rows.count)").font(.caption).monospacedDigit().frame(width: 75, alignment: .trailing)
            }
        }
        .background(VisibilityProbe(visible: $visible).frame(width: 0, height: 0))
        .onAppear { updateCount() }
        .onChange(of: rows.count) { _ in updateCount() }
        .onChange(of: count) { _ in
            if playing || !rows.suffix(count).contains(where: { $0.id == selection }) { selection = moment?.id }
        }
        .onChange(of: reduceMotion) { if $0 { playing = false } }
        .onDisappear { playing = false }
        .onReceive(clock) { _ in
            guard playing, visible, !reduceMotion else { return }
            progress = min(Double(rows.count), progress + Double(max(1, rows.count / 80)))
            if count == rows.count { playing = false }
        }
    }
    private func updateCount() {
        if previousCount == 0 || progress >= Double(previousCount) { progress = Double(max(1, rows.count)) }
        else { progress = min(progress, Double(max(1, rows.count))) }
        previousCount = rows.count
    }
}

/// A first-parent lineage forms a branch's log; cross-lineage parent links
/// retain the real forks and merges when those logs are collected into stars.
struct NebulaBranch: Identifiable {
    let id: String
    let color: Int
    let rows: [GraphRow]
    var title: String {
        rows.map(\.commit.decorations).first { !$0.isEmpty && !$0.hasPrefix("tag: ") }?
            .replacingOccurrences(of: "HEAD -> ", with: "") ?? L("分岐 \(color + 1)")
    }
    static func radius(_ count: Int) -> Float { 0.22 + 0.16 * sqrt(Float(count)) }
    static func group(_ rows: [GraphRow]) -> [NebulaBranch] {
        let records = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        func priority(_ row: GraphRow) -> Int {
            let refs = row.commit.decorations
            if refs.contains("HEAD -> ") || refs == "HEAD" { return 0 }
            if refs.components(separatedBy: ", ").contains(where: { !$0.isEmpty && !$0.hasPrefix("tag: ") }) { return 1 }
            return 2
        }
        let roots = rows.enumerated().sorted {
            let a = priority($0.element), b = priority($1.element)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        var assigned = Set<String>(), branches: [NebulaBranch] = []
        for root in roots where !assigned.contains(root.id) {
            var ids = Set<String>(), current: GraphRow? = root
            while let row = current, !assigned.contains(row.id) {
                assigned.insert(row.id); ids.insert(row.id)
                current = row.commit.parents.first.flatMap { records[$0] }
            }
            let index = branches.count
            branches.append(NebulaBranch(id: String(index), color: index, rows: rows.filter { ids.contains($0.id) }))
        }
        return branches
    }
}
struct NebulaBranchLink {
    let from, to: String
    var commits: [(child: String, parent: String)]
    static func links(_ branches: [NebulaBranch]) -> [NebulaBranchLink] {
        let membership = Dictionary(uniqueKeysWithValues: branches.flatMap { branch in branch.rows.map { ($0.id, branch.id) } })
        var links: [String: NebulaBranchLink] = [:]
        for branch in branches {
            for row in branch.rows {
                for parent in row.commit.parents {
                    guard let other = membership[parent], other != branch.id else { continue }
                    let pair = [branch.id, other].sorted(), key = pair.joined(separator: ":")
                    if links[key] == nil { links[key] = NebulaBranchLink(from: pair[0], to: pair[1], commits: []) }
                    links[key]!.commits.append((row.id, parent))
                }
            }
        }
        return links.keys.sorted().map { links[$0]! }
    }
}

/// Spatial relaxation uses branch relationships and log sizes, without imposing row axes.
enum CommitConstellation {
    static func seed(_ id: String) -> UInt64 {
        id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
    static func positions(_ branches: [NebulaBranch], links: [NebulaBranchLink]) -> [String: SIMD3<Float>] {
        guard !branches.isEmpty else { return [:] }
        let radius = max(6, pow(Float(branches.count), 1 / 3) * 3)
        var points = branches.map { branch -> SIMD3<Float> in
            var value = seed(branch.id + ":nebula")
            func random() -> Float {
                value ^= value << 13; value ^= value >> 7; value ^= value << 17
                return Float(value & 0xffff) / 65535
            }
            let direction = simd_normalize(SIMD3<Float>(random() * 2 - 1, random() * 2 - 1, random() * 2 - 1) + SIMD3<Float>(repeating: 0.0001))
            return direction * radius * pow(0.12 + random() * 0.88, 1 / 3)
        }
        let indices = Dictionary(uniqueKeysWithValues: branches.enumerated().map { ($0.element.id, $0.offset) })
        for _ in 0..<55 {
            var forces = Array(repeating: SIMD3<Float>.zero, count: branches.count)
            for a in points.indices {
                for b in points.indices where b > a {
                    let delta = points[a] - points[b], distance = max(0.25, simd_length(delta))
                    let spacing = NebulaBranch.radius(branches[a].rows.count) + NebulaBranch.radius(branches[b].rows.count) + 2
                    let force = delta / distance * min(1.8, spacing * spacing / (distance * distance))
                    forces[a] += force; forces[b] -= force
                }
                forces[a] -= points[a] * 0.015
            }
            for link in links {
                let a = indices[link.from]!, b = indices[link.to]!
                let delta = points[b] - points[a], distance = max(0.01, simd_length(delta))
                let spacing = NebulaBranch.radius(branches[a].rows.count) + NebulaBranch.radius(branches[b].rows.count) + 4
                let force = delta / distance * (distance - spacing) * 0.055
                forces[a] += force; forces[b] -= force
            }
            for index in points.indices { points[index] += forces[index] * 0.45 }
        }
        let center = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        return Dictionary(uniqueKeysWithValues: branches.indices.map { (branches[$0].id, points[$0] - center) })
    }
}

struct NebulaGraphScene: NSViewRepresentable {
    let rows: [GraphRow]
    let visibleCount: Int
    @Binding var selection: String?
    let cameraReset: Int

    final class BranchStar: SCNNode { var commitID = "" }

    final class GraphView: SCNView {
        var selectCommit: ((String) -> Void)?
        private(set) var orbitTarget = SIMD3<Float>.zero
        private var spaceRadius: Float = 8
        private var zoomBaseOffset = SIMD3<Float>(0, 0, 1)
        private var zoomBaseTransform = matrix_identity_float4x4
        private var scrollTotal = 0.0
        private var mouseStart = NSPoint.zero
        private var mousePrevious = NSPoint.zero
        private var dragged = false
        override var acceptsFirstResponder: Bool { true }
        func resetCamera(_ camera: SCNNode, radius: Float) {
            spaceRadius = radius; orbitTarget = .zero
            camera.simdPosition = SIMD3<Float>(0, radius * 0.12, radius * 3.2)
            camera.look(at: SCNVector3(0, 0, 0)); pointOfView = camera
            anchorZoom(camera)
            needsDisplay = true
        }
        private func star(at point: NSPoint) -> BranchStar? {
            for hit in hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue]) {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let star = current as? BranchStar, !star.isHidden { return star }
                    node = current.parent
                }
            }
            return nil
        }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            mouseStart = convert(event.locationInWindow, from: nil); mousePrevious = mouseStart; dragged = false
        }
        override func mouseDragged(with event: NSEvent) {
            guard let camera = pointOfView else { return }
            let point = convert(event.locationInWindow, from: nil)
            if hypot(point.x - mouseStart.x, point.y - mouseStart.y) > 3 { dragged = true }
            let delta = NSPoint(x: point.x - mousePrevious.x, y: point.y - mousePrevious.y); mousePrevious = point
            let offset = camera.simdPosition - orbitTarget, distance = max(0.28, simd_length(offset))
            let yaw = atan2(offset.x, offset.z) - Float(delta.x) * 0.007
            let pitch = max(-1.45, min(1.45, asin(offset.y / distance) - Float(delta.y) * 0.007))
            camera.simdPosition = orbitTarget + SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
            camera.look(at: SCNVector3(orbitTarget)); anchorZoom(camera); needsDisplay = true
        }
        override func mouseUp(with event: NSEvent) {
            guard !dragged, let node = star(at: convert(event.locationInWindow, from: nil)) else { return }
            selectCommit?(node.commitID)
            if event.clickCount == 2 { focusStar(node) }
        }
        func focusStar(_ node: BranchStar) {
            guard let camera = pointOfView else { return }
            let direction = simd_normalize(camera.simdPosition - node.simdPosition)
            orbitTarget = node.simdPosition
            let distance = max(2.4, (node.childNode(withName: "star", recursively: false)?.simdScale.x ?? 1) * 4)
            camera.simdPosition = orbitTarget + direction * distance
            camera.look(at: SCNVector3(orbitTarget)); anchorZoom(camera); needsDisplay = true
        }
        private func anchorZoom(_ camera: SCNNode) {
            zoomBaseOffset = camera.simdPosition - orbitTarget
            zoomBaseTransform = camera.simdTransform; scrollTotal = 0
        }
        override func scrollWheel(with event: NSEvent) {
            dolly(delta: Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 1 : 8))
        }
        /// Keep the orbit anchor fixed and retain overscroll, so opposite wheel
        /// movement retraces the same camera path even at a distance limit.
        func dolly(delta: Double) {
            guard let camera = pointOfView, delta != 0 else { return }
            scrollTotal += delta
            let baseDistance = Double(simd_length(zoomBaseOffset))
            let factor = Float(exp(min(log(Double(spaceRadius * 30) / baseDistance), max(log(0.28 / baseDistance), -scrollTotal * 0.014))))
            var transform = zoomBaseTransform
            if scrollTotal != 0 { transform.columns.3 = SIMD4<Float>(orbitTarget + zoomBaseOffset * factor, 1) }
            camera.simdTransform = transform; needsDisplay = true
        }
    }
    final class Coordinator {
        static let colors: [NSColor] = [
            NSColor(red: 0.70, green: 0.40, blue: 1, alpha: 1),
            NSColor(red: 0.20, green: 0.78, blue: 1, alpha: 1),
            NSColor(red: 1, green: 0.40, blue: 0.70, alpha: 1),
            NSColor(red: 0.38, green: 0.50, blue: 1, alpha: 1)
        ]
        private var signature: [String] = []
        private var nodes: [String: BranchStar] = [:]
        private var edges: [(SCNNode, NebulaBranchLink)] = []
        private var branches: [NebulaBranch] = []
        private let camera = SCNNode()
        private var radius: Float = 8
        private var lastReset = 0
        private(set) var scene = SCNScene()
        func update(_ view: GraphView, rows: [GraphRow], count: Int, selection: String?, reset: Int) {
            let ids = rows.map(\.id)
            if ids != signature || view.scene == nil {
                signature = ids; build(rows)
                view.scene = scene; view.resetCamera(camera, radius: radius)
            }
            let visible = Set(rows.suffix(count).map(\.id))
            let selectedBranch = branches.first { $0.rows.contains { $0.id == selection } }?.id
            for branch in branches {
                guard let node = nodes[branch.id] else { continue }
                let logs = branch.rows.filter { visible.contains($0.id) }
                node.isHidden = logs.isEmpty
                node.commitID = logs.first?.id ?? ""
                let size = NebulaBranch.radius(logs.count)
                node.childNode(withName: "star", recursively: false)?.simdScale = SIMD3<Float>(repeating: size)
                let color = Self.colors[branch.color % Self.colors.count]
                node.childNode(withName: "star", recursively: false)?.childNodes.first?.geometry?.firstMaterial?.diffuse.contents = branch.id == selectedBranch ? NSColor.white : NSColor.white.blended(withFraction: 0.4, of: color)
                if let label = node.childNode(withName: "label", recursively: false), let text = label.geometry as? SCNText {
                    let caption = branch.title + " · " + String(logs.count)
                    if text.string as? String != caption {
                        text.string = caption
                        let box = text.boundingBox; label.pivot = SCNMatrix4MakeTranslation((box.min.x + box.max.x) / 2, box.min.y, 0)
                    }
                    label.simdPosition.y = -(size + 0.6)
                }
            }
            for (node, link) in edges {
                node.isHidden = !link.commits.contains { visible.contains($0.child) && visible.contains($0.parent) }
                node.opacity = link.from == selectedBranch || link.to == selectedBranch ? 1 : 0.7
            }
            if lastReset != reset { lastReset = reset; view.resetCamera(camera, radius: radius) }
        }
        private func material(_ color: NSColor, opacity: CGFloat = 1) -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .constant; material.diffuse.contents = color
            material.transparency = opacity
            return material
        }
        private func glow(_ color: NSColor, diameter: CGFloat) -> SCNNode {
            let image = NSImage(size: NSSize(width: 96, height: 96), flipped: false) { rect in
                NSGradient(colorsAndLocations: (color.withAlphaComponent(0.8), 0), (color.withAlphaComponent(0.18), 0.15), (color.withAlphaComponent(0), 1))?.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: .zero)
                let rays = NSGradient(colorsAndLocations: (color.withAlphaComponent(0), 0), (NSColor.white.withAlphaComponent(0.55), 0.5), (color.withAlphaComponent(0), 1))
                rays?.draw(in: NSRect(x: 15, y: 47.5, width: 66, height: 1), angle: 0)
                rays?.draw(in: NSRect(x: 47.5, y: 23, width: 1, height: 50), angle: 90)
                return true
            }
            let plane = SCNPlane(width: diameter, height: diameter)
            let material = SCNMaterial(); material.lightingModel = .constant
            material.diffuse.contents = image; material.isDoubleSided = true
            material.writesToDepthBuffer = false; material.blendMode = .alpha
            plane.materials = [material]
            let node = SCNNode(geometry: plane); node.constraints = [SCNBillboardConstraint()]
            return node
        }
        private func build(_ rows: [GraphRow]) {
            scene = SCNScene(); nodes = [:]; edges = []
            scene.background.contents = NSColor(red: 0.006, green: 0.009, blue: 0.027, alpha: 1)
            branches = NebulaBranch.group(rows)
            let links = NebulaBranchLink.links(branches)
            let positions = CommitConstellation.positions(branches, links: links)
            radius = max(7, branches.map { simd_length(positions[$0.id]!) + NebulaBranch.radius($0.rows.count) }.max() ?? 7)
            for branch in branches {
                let color = Self.colors[branch.color % Self.colors.count]
                let sphere = SCNSphere(radius: 1); sphere.segmentCount = 24
                sphere.materials = [material(NSColor.white.blended(withFraction: 0.3, of: color) ?? color)]
                let star = SCNNode(); star.name = "star"
                star.addChildNode(SCNNode(geometry: sphere)); star.addChildNode(glow(color, diameter: 8))
                let node = BranchStar(); node.name = "branch:" + branch.id; node.simdPosition = positions[branch.id]!
                node.addChildNode(star)
                let text = SCNText(string: "", extrusionDepth: 0)
                text.font = .systemFont(ofSize: 18, weight: .medium); text.flatness = 0.3; text.materials = [material(.white)]
                let label = SCNNode(geometry: text); label.name = "label"
                label.scale = SCNVector3(0.032, 0.032, 0.032); label.constraints = [SCNBillboardConstraint()]
                node.addChildNode(label)
                scene.rootNode.addChildNode(node); nodes[branch.id] = node
            }
            for link in links {
                let start = positions[link.from]!, end = positions[link.to]!, distance = simd_length(end - start)
                guard distance > 0 else { continue }
                let color = Self.colors[(branches.first { $0.id == link.to }?.color ?? 0) % Self.colors.count]
                let filament = SCNCylinder(radius: 0.018, height: CGFloat(distance))
                filament.radialSegmentCount = 6; filament.materials = [material(color, opacity: 0.65)]
                let edge = SCNNode(geometry: filament); edge.simdPosition = (start + end) / 2
                edge.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(end - start))
                scene.rootNode.addChildNode(edge); edges.append((edge, link))
            }
            if let volume = NebulaVolume.shared?.node(radius: radius) { scene.rootNode.addChildNode(volume) }
            // A spherical star field surrounds the viewer, including foreground stars.
            for index in 0..<650 {
                let angle = Float(index) * 2.399963, y = 1 - 2 * Float(index) / 650
                let ring = sqrt(1 - y * y)
                let distance = radius * (2.4 + Float((index * 137) % 997) / 997 * 14)
                let star = SCNSphere(radius: index % 17 == 0 ? 0.055 : 0.025); star.segmentCount = 6
                star.materials = [material(index % 4 == 0 ? Self.colors[index % 3] : .white, opacity: index % 17 == 0 ? 0.85 : 0.45)]
                let node = SCNNode(geometry: star)
                node.simdPosition = SIMD3<Float>(cos(angle) * ring, y, sin(angle) * ring) * distance
                scene.rootNode.addChildNode(node)
            }
            camera.removeFromParentNode(); camera.camera = SCNCamera()
            camera.camera?.zNear = 0.03; camera.camera?.zFar = Double(radius * 100)
            camera.camera?.fieldOfView = 58; camera.camera?.wantsHDR = false
            scene.rootNode.addChildNode(camera)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> GraphView {
        let view = GraphView(); view.allowsCameraControl = false; view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30; view.isPlaying = false; view.rendersContinuously = false
        view.setAccessibilityLabel(L("星雲のコミットグラフ"))
        return view
    }
    func updateNSView(_ view: GraphView, context: Context) {
        view.selectCommit = { selection = $0 }
        context.coordinator.update(view, rows: rows, count: visibleCount, selection: selection, reset: cameraReset)
    }
}
