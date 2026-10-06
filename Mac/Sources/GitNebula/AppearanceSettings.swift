import SwiftUI
import AppKit

enum AppTheme: String, CaseIterable {
    case system, light, dark
    var title: String { switch self { case .system: return L("システム"); case .light: return L("ライト"); case .dark: return L("ダーク") } }
    var scheme: ColorScheme? { self == .system ? nil : self == .light ? .light : .dark }
}
enum AppLanguage: String, CaseIterable {
    case ja, en
    var title: String { self == .ja ? L("日本語") : "English" }
    var code: String { rawValue }
}
@MainActor final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()
    static let changed = Notification.Name("GitNebula.appearanceChanged")
    private let defaults: UserDefaults
    @Published var theme: AppTheme { didSet { save() } }
    @Published var language: AppLanguage { didSet { save() } }
    @Published var transparency: Double { didSet { save() } }
    @Published private(set) var systemScheme: ColorScheme
    private var systemAppearanceObserver: NSKeyValueObservation?
    var colorScheme: ColorScheme { theme.scheme ?? systemScheme }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "system") ?? .system
        language = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? (Localization.preferredLanguage == "ja" ? .ja : .en)
        transparency = min(0.8, max(0, defaults.double(forKey: "windowTransparency")))
        systemScheme = Self.scheme(for: NSApplication.shared.effectiveAppearance)
        // Migrate the former automatic language option to an explicit choice.
        defaults.set(language.rawValue, forKey: "appLanguage")
        systemAppearanceObserver = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] application, _ in
            let scheme = Self.scheme(for: application.effectiveAppearance)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.systemScheme != scheme else { return }
                self.systemScheme = scheme
            }
        }
    }
    nonisolated static func scheme(for appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
    private func save() {
        defaults.set(theme.rawValue, forKey: "appTheme"); defaults.set(language.rawValue, forKey: "appLanguage")
        defaults.set(min(0.8, max(0, transparency)), forKey: "windowTransparency")
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject private var settings = AppearanceSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("表示")).font(.headline)
            Picker(L("テーマ"), selection: $settings.theme) {
                ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).id(settings.language).accessibilityIdentifier("themePicker")
            HStack {
                Text(L("透明度"))
                Slider(value: $settings.transparency, in: 0...0.8).accessibilityIdentifier("transparencySlider")
                Text("\(Int(settings.transparency * 100))%").monospacedDigit().frame(width: 45)
            }
            Picker(L("言語"), selection: $settings.language) {
                ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
            }.id(settings.language).accessibilityIdentifier("languagePicker")
        }
    }
}

// No opaque hosting/material layer may cover the window's alpha background.
final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor
    }
}

struct AppearanceScope<Content: View>: View {
    @ObservedObject private var settings = AppearanceSettings.shared
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().environment(\.locale, Locale(identifier: settings.language.code))
            .environment(\.colorScheme, settings.colorScheme)
            .tint(Color.accentColor)
            .background(NativeWindowTheme(theme: settings.theme))
    }
}

private struct NativeWindowTheme: NSViewRepresentable {
    let theme: AppTheme
    final class Probe: NSView {
        var theme = AppTheme.system
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            guard let window else { return }
            if theme == .system {
                if window.appearance != nil { window.appearance = nil }
            } else {
                let name: NSAppearance.Name = theme == .light ? .aqua : .darkAqua
                if window.appearance?.name != name { window.appearance = NSAppearance(named: name) }
            }
        }
    }
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.theme = theme; return view }
    func updateNSView(_ view: Probe, context: Context) { view.theme = theme; view.apply() }
}
