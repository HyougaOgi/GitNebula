# 機能の対応状況

TortoiseGit の[日常操作ガイド](https://tortoisegit.org/docs/tortoisegit/tgit-dug.html)を比較対象としています。GitNebula は完全互換ではありません。今回の機能拡張は macOS 版に実装しています。パスの直接入力は全 OS に追加しました。

| 操作 | macOS | Windows / Linux |
| --- | --- | --- |
| ファイル・フォルダ・背景の右クリックから操作 | Finder 拡張。インストールと有効化が必要 | 各 OS の登録スクリプトが必要 |
| パスの直接入力・貼り付け・フォルダ選択 | 対応 | 対応 |
| Clone / Commit / Diff / Log / Fetch / Pull / Push | 対応 | 対応 |
| ブランチ作成・切替・名前変更・削除・Merge | 対応 | 対応 |
| テキスト競合編集・外部で解決・Merge の完了と中止 | 対応 | 対応 |
| Init | 空のリポジトリを既存フォルダに作成 | 未対応 |
| Stage / Unstage / 変更破棄 / Ignore | 選択ファイル単位 | 未対応 |
| Stash | 未追跡ファイルを含める選択、一覧、差分、Apply、Pop、Drop | 未対応 |
| Tag | 軽量・注釈付きタグの作成、一覧、削除、個別 Push | 未対応 |
| リモート設定 | 登録、URL 変更、削除 | 未対応 |
| コミット作成者設定 | リポジトリごとの名前・メール設定 | 未対応 |
| コミット詳細・2 コミットの比較・ファイル履歴・Blame・Reflog | 対応 | 未対応 |
| Cherry-pick / Revert | 単一コミット。競合後の再開と中止 | 未対応 |
| Rebase | 通常の Rebase。競合後の再開と中止 | 未対応 |
| Reset | Soft / Mixed / Hard。変更がある作業ツリーでは実行しない | 未対応 |
| パッチ | HEAD との差分をバイナリ込みで保存、適用確認、適用 | 未対応 |
| Worktree | 一覧、新しいブランチで作成 | 未対応 |
| Submodule | 一覧、追加、記録されたコミットへの再帰的な取得・更新 | 未対応 |

## 制限

- 対話的 Rebase（コミット並べ替え・Squash）、Amend、履歴からの複数コミット選択、部分的な行のステージは未対応です。
- ファイルの状態を示す Finder / Explorer のオーバーレイアイコンは未対応です。アプリと Finder メニューにはアイコンがあります。
- 外部 Diff / Merge ツールの設定 UI、Git LFS、Bisect、Reflog からの専用復元 UI は未対応です。
- Worktree の削除、Submodule の削除・ブランチ追跡設定、メール形式パッチの連続適用は未対応です。
- Pull は fast-forward のみです。強制 Push、リモートブランチ・タグの削除 UI はありません。
- リポジトリ認証には既存の Git credential helper または SSH agent を使います。

## macOS の操作場所

通常起動後、上部のパス欄に `~/Projects/my-repo` などを入力して Enter または「開く」を押します。「参照…」でも選択できます。Finder から起動した場合は対象パスが入力済みです。

Stash、タグ、リモート設定にはそれぞれ専用の画面があります。履歴編集・比較・Blame・パッチ・Worktree・Submodule は「履歴・ファイル・作業ツリー」から選びます。ブランチ作成や Merge は「その他の操作 → 詳細操作」です。Stage・Unstage・Ignore・変更破棄は Commit / 詳細操作の変更一覧にあります。

Rebase / Cherry-pick / Revert が競合した場合は、同じ画面の競合欄で解決し「再開」を押します。中止ボタンは競合解決の作業を破棄する前に確認を表示します。Stash の適用が競合した場合、退避データは残り、通常のコミットとして解決します。
