import SwiftUI

/// Allocate panes from the space left by the window chrome, rather than the
/// fitting height of the commit message or the previously expanded split view.
struct CommitBrowserPanes<ListContent: View, DetailContent: View>: View {
    @ViewBuilder var list: () -> ListContent
    @ViewBuilder var detail: () -> DetailContent
    var body: some View {
        GeometryReader { viewport in
            let listMinimum = min(80, max(0, viewport.size.height / 3))
            let detailMinimum = min(200, max(0, viewport.size.height - listMinimum - 6))
            VSplitView {
                list().frame(minHeight: listMinimum, idealHeight: min(220, viewport.size.height * 0.35), maxHeight: max(listMinimum, viewport.size.height - detailMinimum - 6))
                detail().frame(minHeight: detailMinimum, maxHeight: .infinity)
            }.frame(width: viewport.size.width, height: viewport.size.height)
        }
    }
}

enum WorkspaceWindowLayout {
    static let minimum = CGSize(width: 850, height: 600)
    static let preferred = CGSize(width: 1100, height: 740)
}
