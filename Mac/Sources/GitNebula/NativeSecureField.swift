import SwiftUI
import AppKit

/// AppKit owns secure text input, including Shift and input method composition.
/// Binding updates never write the active editor's text back during a keystroke.
struct NativeSecureField: NSViewRepresentable {
    @Binding var text: String
    var showsSavedValue = false
    let placeholder: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSecureTextField {
        let field = SecureTextField()
        field.isBezeled = true; field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13); field.focusRingType = .exterior
        field.delegate = context.coordinator
        field.beginEditing = { [weak coordinator = context.coordinator, weak field] in
            guard coordinator?.parent.showsSavedValue == true else { return }
            field?.stringValue = ""
        }
        field.setAccessibilityIdentifier("sshPassphrase")
        return field
    }
    func updateNSView(_ field: NSSecureTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.placeholderString = placeholder; field.setAccessibilityLabel(placeholder)
        if coordinator.lastValue != text {
            field.stringValue = text; coordinator.lastValue = text
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeSecureField
        var lastValue: String?
        init(_ parent: NativeSecureField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSecureTextField else { return }
            lastValue = field.stringValue
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            if parent.showsSavedValue, let field = notification.object as? NSSecureTextField {
                field.stringValue = parent.text
            }
        }
    }
    final class SecureTextField: NSSecureTextField {
        var beginEditing: (() -> Void)?
        override func becomeFirstResponder() -> Bool {
            // Clear the display mask before AppKit creates the editor, not during input.
            beginEditing?()
            return super.becomeFirstResponder()
        }
    }
}
