import SwiftUI
import FinderSync

struct FinderIntegrationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var enabled = FIFinderSyncController.isExtensionEnabled
    private var bundled: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appendingPathComponent("GitNebulaFinder.appex").path)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Finder の右クリックメニュー", systemImage: "cursorarrow.click.2").font(.headline)
            Text(!bundled ? "開発用の実行ファイルです。Finder メニューを使うには、アプリをインストールしてください。" : enabled ? "有効です。Finder でファイル・フォルダ・背景を右クリック → GitNebula から操作できます。" : "Finder 拡張が無効です。設定で「GitNebula Finder」を有効にしてください。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if bundled {
                HStack {
                    Button("Finder 拡張の設定を開く") { FIFinderSyncController.showExtensionManagementInterface() }
                    Button("状態を更新") { enabled = FIFinderSyncController.isExtensionEnabled }
                }
            } else {
                Text("リポジトリで実行: bash Mac/install.sh").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: scenePhase) { phase in
            if phase == .active { enabled = FIFinderSyncController.isExtensionEnabled }
        }
    }
}
