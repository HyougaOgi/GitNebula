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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var settings = AppearanceSettings.shared
    @State private var visible = false
    var body: some View {
        ZStack {
            (scheme == .dark ? Color(red: 0.035, green: 0.05, blue: 0.11) : Color(red: 0.96, green: 0.96, blue: 0.99))
            RadialGradient(colors: [.purple.opacity(scheme == .dark ? 0.2 : 0.09), .clear], center: .topTrailing, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [.cyan.opacity(0.08), .clear], center: .bottomLeading, startRadius: 0, endRadius: 600)
            TimelineView(.animation(minimumInterval: 1 / 12, paused: !visible || reduceMotion)) { timeline in
                Canvas { context, size in
                    let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    for star in NebulaStar.field {
                        let rect = CGRect(x: star.x * size.width, y: star.y * size.height, width: star.size * 2, height: star.size * 2)
                        context.fill(Path(ellipseIn: rect), with: .color((scheme == .dark ? Color.white : .purple).opacity(star.opacity(at: time))))
                    }
                }
            }
            VisibilityProbe(visible: $visible).frame(width: 0, height: 0)
        }.compositingGroup().opacity(1 - settings.transparency).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A transparent GPU volume of turbulent gas; its timeline pauses when hidden.
struct NebulaScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    private static let epoch = Date()
    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1 / 18, paused: !visible || reduceMotion)) { timeline in
                Canvas { context, size in
                    let time = reduceMotion ? 0 : timeline.date.timeIntervalSince(Self.epoch)
                    let renderSize = CGSize(width: size.width * 1.5, height: size.height * 1.5)
                    if let gas = try? NebulaRenderer.shared?.image(size: renderSize, time: Float(time)) {
                        context.draw(Image(decorative: gas, scale: 1.5), in: CGRect(origin: .zero, size: size))
                    }
                    for index in 0..<42 {
                        let x = Double((index * 137 + 23) % 997) / 997 * size.width
                        let y = Double((index * 239 + 67) % 991) / 991 * size.height
                        let radius = index % 11 == 0 ? 1.2 : 0.6
                        let brightness = 0.45 + 0.25 * sin(time * 0.5 + Double(index))
                        if index % 11 == 0 {
                            context.fill(Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)), with: .radialGradient(Gradient(colors: [.cyan.opacity(0.35), .clear]), center: CGPoint(x: x, y: y), startRadius: 0, endRadius: 5))
                        }
                        context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(.white.opacity(brightness)))
                    }
                }
            }
        }.background(VisibilityProbe(visible: $visible)).allowsHitTesting(false)
            .accessibilityLabel(L("星雲")).accessibilityIdentifier("nebulaScene")
    }
}
