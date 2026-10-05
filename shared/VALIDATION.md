# 実装調査と検証

## 修正した原因と構成

- Windows のリモート・ブランチ一覧は LF だけで分割し、CRLF の `\r` を名前に残していた。UI で選んだ値を push / fetch / switch に渡すと不正な名前になる。GitProcess.Lines で行末だけを正規化し、空白を含むパスや NUL 区切りのファイル一覧は変更しない。
- Windows の Git 探索は PATH のみだった。Explorer が古い PATH を引き継いだ場合にも Git for Windows の標準インストール先を探索する。アプリ設定から実行ファイルを指定できる。
- macOS は SwiftUI の WindowGroup と追加の AppKit ウィンドウの両方で起動要求を扱っていた。アプリ所有の一つのウィンドウに集約し、Finder 要求も同一ウィンドウ内の画面遷移で扱う。下書きと元の画面は保持する。
- 画面の表示条件を整理し、macOS のコンテンツは action / utility の選択によって一つに決める。保持する NSHostingView のうち表示中の一つだけを接続する。Windows の「詳細操作」に同居していたブランチ・変更一覧・コミットを、管理の入口と専用画面に分ける。
- 通常起動・アプリ / Dock の再表示は「GitNebula へようこそ」。メニューバーには機能一覧を置き、選択した専用画面を開く。閉じる操作は初期設定では非表示にして常駐を維持する。設定で変更でき、明示的な終了操作がある。処理中の終了は拒否する。
- stash は未追跡ファイルだけの作業ツリーで include-untracked を外した場合、実際には退避されないのに成功としていた。この条件をエラーにし、初回コミット前にも明確な案内を出す。一覧の再番号付け後もコミット ID から現在の stash 参照を解決する。
- 初回コミット前の Unstage は index と作業ファイルの内容が違うと失敗していた。作業ファイルを残し index のみ解除する。
- Unstage は未追跡・未ステージのファイルが混在した選択でも、ステージ済みのファイルだけを処理する。解除できるステージがない場合は明確な案内を出す。
- Windows の競合解決は専用画面に分離し、他の機能には入口だけを表示する。メニューの Cherry-pick / Revert はコミット一覧、Rebase はブランチ一覧で対象を選ぶ。Stash のボタンは変更・選択・初回コミット・競合の状態に合わせて有効にする。
- Git 処理中にメニューバー / トレイからホームを要求しても、進行中の画面や処理を切り替えず、完了後にホームへ戻る。初回コミット前と detached HEAD の Push は必要な操作を説明する。
- Cherry-pick / Revert は履歴の選択対象から実行できる。Rebase / Merge はブランチの選択から実行できる。競合、再開、中止を両プラットフォームで扱う。マージコミットの Cherry-pick / Revert は親指定 UI がないため履歴画面からは無効。
- macOS は Cherry-pick / Revert / Rebase / Merge を起動操作として追加し、Finder・メニューバー・既存の機能ランチャーから同じ専用画面へ配送する。保持している SwiftUI 画面の navigationTitle が現行ウィンドウ名を上書きする経路を削除し、表示中の経路にタイトル更新を集約する。
- Git 未検出、終了コード、stdout / stderr、操作後の画面更新エラーを表示する。「設定がない」「detached HEAD」「初回コミット前」はそれぞれ想定する終了コードだけを許可し、それ以外のエラーを隠さない。

## Git バックエンド

macOS / Windows はどちらも Git CLI を使用する。Swift と C# のネイティブ UI に合わせて各言語のモデルを維持し、各プラットフォーム内で全機能のプロセス実行を GitProcess に集約する。実行する Git 操作の方針は共通で、シェルにコマンド文字列を渡さず引数配列を使う。OS 固有の実行ファイル探索・プロセス IO はランナーに分離する。認証には既存の credential helper / SSH agent を使い、GUI の認証ダイアログは妨げない。ターミナルからの入力は要求しない。

## 実行する検証

```sh
swift test --package-path Mac
bash Mac/package.sh --unsigned
python3 -m unittest discover -s tests -v
dotnet run --project tests/windows/GitNebula.BackendTests.csproj
# macOS から Windows ソースをコンパイルする場合
dotnet build Windows/GitNebula.csproj -p:EnableWindowsTargeting=true
dotnet build tests/windows-ui/GitNebula.UiTests.csproj -p:EnableWindowsTargeting=true
```

テストは一時ディレクトリとローカル bare repository を使う。clone / fetch / pull / push、選択ファイルだけの commit、add / unstage、ブランチ作成・名前変更・削除・switch、merge と競合解決、diff / log、tag / remote、stash、Cherry-pick / Revert / Rebase の競合・再開・中止を検証する。Windows バックエンドのテストは macOS でも実行でき、CRLF を返す Git ラッパーによる push / fetch / switch の再現テストを含む。

macOS の GUI テストはようこそ、設定、全メニューの排他表示とウィンドウ名、一覧→比較→戻る、選択・スクロール・下書きの保持、閉じる→再表示、Finder 要求の同一ウィンドウへの配送を確認する。Cherry-pick / Revert は実際のメニュー、コミット一覧の選択、実行ボタン、確認ダイアログを通して一時リポジトリの変更結果まで確認する。Windows の WPF テストも各画面の排他表示を確認するが、実行には Windows が必要。

## 残る環境依存の確認

Windows 実機の WPF / トレイ / 単一インスタンス配送 / Explorer メニュー、Git for Windows の credential helper / SSH / ネットワーク認証は macOS 上では実行できない。macOS の Finder 拡張の登録・有効化はユーザー環境に依存するため、既存の登録をテストから変更しない。公開リモートへの push、署名と公証は検証に含めない。

Windows CI はジョブを残して `if: ${{ false }}` で停止している。実機確認後にその条件を `true` に変更すれば、ビルド・バックエンド・WPF・Explorer メニュー・パッケージの既存チェックを再開できる。

## この作業での検証結果

- macOS: `swift test --package-path Mac` の 38 テストが成功。ようこそと全機能の排他表示、各メニューからの画面とウィンドウ名の切り替え、Cherry-pick / Revert の選択・確認・実行、処理中のホーム要求の待機、Finder 要求の同一ウィンドウ配送、混在選択と初回コミット前の Unstage、初回コミット前・detached HEAD の Push の案内を含む。描画循環の警告は最終実行にない。
- macOS: 実行ファイルを別プロセスで起動し、要求した画面が一つの通常ウィンドウで表示され、プロセスが維持されることを確認。
- macOS: Release ビルドと `Mac/package.sh --unsigned` が成功。ZIP を別の一時フォルダに展開し、アプリと Finder 拡張の存在、plist、`codesign --verify --deep --strict` を確認。出力は `dist/mac/GitNebula-unsigned.zip`（x86_64、ad-hoc 署名）。
- macOS（2026-10-06）: 旧インストールの 0.5.0 をバックアップし、`~/Applications/GitNebula.app` を 0.6.0 に更新した。起動中のアプリがこのパスの新バイナリであること、ZIP 内のバイナリと SHA-256 が一致することを確認。実際の通常起動で「GitNebula へようこそ」を表示し、System Events から専用画面の対象選択・確認・実行を操作して、Cherry-pick の追加、Revert の取り消し、Rebase による祖先とコミット ID の変更を一時リポジトリで検証した。
- macOS: インストール済み 0.6.0 の全 18 機能、4 管理画面、アプリ設定を実際のメニューから順に開き、専用画面・ウィンドウ名・ウィンドウ数 1 を確認。アプリの再表示はようこそへ戻る。ウィンドウを閉じた後も同じプロセスとメニューバーアイコンが残り、開き直すとようこそを表示する。検証後は最近のリポジトリ一覧を元に戻し、通常起動のようこそ画面を表示している。
- Windows ソース: .NET 8 によるバックエンド統合テストが macOS 上で成功。ローカル bare repository の送受信、CRLF 出力の再現、Stash、タグ、リモート、履歴編集、競合・再開・中止、混在選択と初回コミット前の Unstage、初回コミット前・detached HEAD の Push の案内を含む。
- Windows ソース: WPF アプリと WPF UI テストのクロスビルドが成功（警告 0、エラー 0）。WPF UI テストの実行とトレイの実機操作は未検証。
- Linux: 既存の Python 18 テストが成功。GTK GUI は macOS 上では実行していない。
- `git diff --check` が成功。ユーザーが作業開始前から変更していた `.gitignore` は維持。
