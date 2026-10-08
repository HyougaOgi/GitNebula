import SwiftUI
import AppKit

struct NativeCommitMessage: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let editor = NSTextView()
        editor.isRichText = false; editor.isEditable = true; editor.isSelectable = true
        editor.font = .systemFont(ofSize: 15); editor.textColor = .labelColor
        editor.drawsBackground = false; editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false; editor.isGrammarCheckingEnabled = false
        editor.string = text; editor.delegate = context.coordinator
        editor.setAccessibilityIdentifier("commitMessage")
        editor.setAccessibilityLabel(L("コミットメッセージ"))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder; scroll.drawsBackground = false; scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = context.environment.isEnabled
        if editor.string != text { editor.string = text }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeCommitMessage
        init(_ parent: NativeCommitMessage) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, parent.text != editor.string else { return }
            parent.text = editor.string
        }
    }
}
