import SwiftUI
import AppKit

enum AppTheme: String, CaseIterable {
    case system, light, dark
    var title: String { switch self { case .system: return L("システム"); case .light: return L("ライト"); case .dark: return L("ダーク") } }
    var scheme: ColorScheme? { self == .system ? nil : self == .light ? .light : .dark }
}
enum AppLanguage: String, CaseIterable {
    case system, ja, en
    var title: String { switch self { case .system: return L("システム"); case .ja: return L("日本語"); case .en: return "English" } }
    var code: String { self == .system ? (Locale.preferredLanguages.first?.hasPrefix("ja") == true ? "ja" : "en") : rawValue }
}
@MainActor final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()
    static let changed = Notification.Name("GitNebula.appearanceChanged")
    private let defaults: UserDefaults
    @Published var theme: AppTheme { didSet { save() } }
    @Published var language: AppLanguage { didSet { save() } }
    @Published var transparency: Double { didSet { save() } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "system") ?? .system
        language = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "system") ?? .system
        transparency = min(0.8, max(0, defaults.double(forKey: "windowTransparency")))
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

// Native vibrancy changes only the background; text and controls stay opaque.
struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .underWindowBackground
        view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { }
}

struct AppearanceScope<Content: View>: View {
    @ObservedObject private var settings = AppearanceSettings.shared
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().environment(\.locale, Locale(identifier: settings.language.code))
            .preferredColorScheme(settings.theme.scheme)
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
