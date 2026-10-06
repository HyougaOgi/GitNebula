import SwiftUI
import AppKit

struct NebulaStar {
    let x, y, phase, period, size: Double
    static let field: [NebulaStar] = (0..<72).map { _ in
        NebulaStar(x: .random(in: 0...1), y: .random(in: 0...1), phase: .random(in: 0...(2 * .pi)), period: .random(in: 3...12), size: .random(in: 0.6...1.8))
    }
    func opacity(at time: Double) -> Double { 0.12 + 0.55 * pow((sin(time * 2 * .pi / period + phase) + 1) / 2, 4) }
}
private struct VisibilityProbe: NSViewRepresentable {
    @Binding var visible: Bool
    final class Probe: NSView {
        var update: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in self?.refresh() }
            refresh()
        }
        func refresh() { let visible = window?.occlusionState.contains(.visible) == true; DispatchQueue.main.async { [weak self] in self?.update?(visible) } }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.update = { visible = $0 }; return view }
    func updateNSView(_ view: Probe, context: Context) { view.update = { visible = $0 } }
}
struct NebulaBackground: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var settings = AppearanceSettings.shared
    @State private var visible = false
    var body: some View {
        ZStack {
            WindowBackdrop()
            (scheme == .dark ? Color(red: 0.035, green: 0.05, blue: 0.11) : Color(red: 0.96, green: 0.96, blue: 0.99)).opacity(1 - settings.transparency)
            RadialGradient(colors: [.purple.opacity(scheme == .dark ? 0.2 : 0.09), .clear], center: .topTrailing, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [.cyan.opacity(0.08), .clear], center: .bottomLeading, startRadius: 0, endRadius: 600)
            TimelineView(.animation(minimumInterval: 1 / 20, paused: !visible || reduceMotion)) { timeline in
                Canvas { context, size in
                    let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    for star in NebulaStar.field {
                        let rect = CGRect(x: star.x * size.width, y: star.y * size.height, width: star.size * 2, height: star.size * 2)
                        context.fill(Path(ellipseIn: rect), with: .color((scheme == .dark ? Color.white : .purple).opacity(star.opacity(at: time))))
                    }
                }
            }
            VisibilityProbe(visible: $visible).frame(width: 0, height: 0)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct AnimatedNebulaIcon: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !visible || reduceMotion)) { timeline in
            Canvas { context, size in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let scale = size.width / 1024
                context.scaleBy(x: scale, y: scale)
                let background = Path(roundedRect: CGRect(x: 40, y: 40, width: 944, height: 944), cornerRadius: 205)
                context.fill(background, with: .linearGradient(Gradient(colors: [Color(red: 0.08, green: 0.1, blue: 0.25), Color(red: 0.37, green: 0.24, blue: 0.64)]), startPoint: .zero, endPoint: CGPoint(x: 1024, y: 1024)))
                let orbit = Path(ellipseIn: CGRect(x: 140, y: 160, width: 740, height: 670))
                context.stroke(orbit, with: .color(.white.opacity(0.25)), lineWidth: 14)
                var branch = Path()
                branch.move(to: CGPoint(x: 378, y: 736)); branch.addLine(to: CGPoint(x: 378, y: 300))
                branch.move(to: CGPoint(x: 378, y: 572)); branch.addCurve(to: CGPoint(x: 660, y: 314), control1: CGPoint(x: 378, y: 429), control2: CGPoint(x: 660, y: 534))
                context.stroke(branch, with: .color(Color(red: 0.86, green: 0.82, blue: 1)), style: StrokeStyle(lineWidth: 58, lineCap: .round))
                for (index, point) in [CGPoint(x: 378, y: 738), CGPoint(x: 378, y: 286), CGPoint(x: 660, y: 298)].enumerated() {
                    let radius = 64 + 5 * sin(time * 1.6 + Double(index) * 1.4)
                    let node = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                    context.fill(node, with: .color(Color(red: 0.78, green: 0.72, blue: 1)))
                    context.stroke(node, with: .color(.white), lineWidth: 14)
                }
                for index in 0..<3 {
                    let angle = time * 0.4 + Double(index) * 2 * .pi / 3
                    let center = CGPoint(x: 510 + cos(angle) * 370, y: 495 + sin(angle) * 335)
                    context.fill(Path(ellipseIn: CGRect(x: center.x - 17, y: center.y - 17, width: 34, height: 34)), with: .color(.cyan.opacity(0.85)))
                }
            }
        }.background(VisibilityProbe(visible: $visible)).accessibilityLabel("GitNebula").accessibilityIdentifier("animatedNebulaIcon")
    }
}
