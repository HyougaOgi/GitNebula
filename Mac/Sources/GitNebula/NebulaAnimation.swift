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

/// Slowly flowing gas, luminous filaments and stars, rather than an animated app logo.
struct NebulaScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 18, paused: !visible || reduceMotion)) { timeline in
            Canvas { context, size in
                Self.draw(context: context, size: size, time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
            }
        }.background(VisibilityProbe(visible: $visible)).accessibilityLabel(L("星雲")).accessibilityIdentifier("nebulaScene")
    }
    private static func draw(context original: GraphicsContext, size: CGSize, time: Double) {
        let context = original
        let width = Double(size.width), height = Double(size.height)
        let palette: [Color] = [.init(red: 0.48, green: 0.23, blue: 0.9), .init(red: 0.2, green: 0.61, blue: 0.86), .init(red: 0.92, green: 0.3, blue: 0.51)]
        for index in 0..<84 {
            let phase = Double(index) * 2.39996
            let spread = sqrt(Double(index) / 84)
            let x = width * 0.5 + cos(phase) * spread * width * 0.32 + sin(time * 0.08 + phase) * 9
            let y = height * 0.48 + sin(phase) * spread * height * 0.28 + cos(time * 0.1 + phase) * 7
            let radius = 12 + Double(index % 9) * 3
            let center = CGPoint(x: x, y: y)
            let cloud = Path(ellipseIn: CGRect(x: x - radius * 1.4, y: y - radius, width: radius * 2.8, height: radius * 2))
            let opacity = 0.24 + 0.08 * sin(time * 0.12 + phase)
            context.fill(cloud, with: .radialGradient(Gradient(colors: [palette[index % 3].opacity(opacity), .clear]), center: center, startRadius: 0, endRadius: radius * 1.4))
        }
        // Small emission knots and intervening dust add texture without geometric lines.
        for index in 0..<18 {
            let phase = Double(index) * 2.7
            let x = width * (0.5 + cos(phase) * 0.22) + sin(time * 0.05 + phase) * 4
            let y = height * (0.48 + sin(phase) * 0.14)
            let radius = 5 + Double(index % 5) * 2
            let color = index % 3 == 0 ? Color(red: 0.03, green: 0.04, blue: 0.1).opacity(0.28) : Color(red: 0.99, green: 0.7, blue: 0.82).opacity(0.16)
            context.fill(Path(ellipseIn: CGRect(x: x - radius * 2, y: y - radius, width: radius * 4, height: radius * 2)), with: .radialGradient(Gradient(colors: [color, .clear]), center: CGPoint(x: x, y: y), startRadius: 0, endRadius: radius * 2))
        }
        for index in 0..<42 {
            let x = Double((index * 137 + 23) % 997) / 997 * width
            let y = Double((index * 239 + 67) % 991) / 991 * height
            let radius = index % 11 == 0 ? 1.4 : 0.65
            let brightness = 0.35 + 0.3 * sin(time * 0.5 + Double(index))
            if index % 11 == 0 {
                context.fill(Path(ellipseIn: CGRect(x: x - 7, y: y - 7, width: 14, height: 14)), with: .radialGradient(Gradient(colors: [.cyan.opacity(0.45), .clear]), center: CGPoint(x: x, y: y), startRadius: 0, endRadius: 7))
            }
            context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(.white.opacity(brightness)))
        }
    }

}
