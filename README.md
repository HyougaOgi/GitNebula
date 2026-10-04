# GitNebula

宇宙をテーマにした Git GUI。TortoiseGit を参考に、Mac・Linux・Windows のそれぞれに適したネイティブアプリとして開発します。

| プロジェクト | 技術 | 必要な環境 | 起動 |
| --- | --- | --- | --- |
| `Mac/` | SwiftUI / Swift | macOS 13 以上、Xcode Command Line Tools | `cd Mac && swift run` |
| `Linux/` | GTK 4 / Python | Python 3、PyGObject、GTK 4、Git、デスクトップ環境 | `python3 Linux/main.py` |
| `Windows/` | WPF / C# | Windows、.NET 8 SDK、Git for Windows | `dotnet run --project Windows` |

共通バイナリやクロスコンパイルは使いません。GUI の仕様・配色・操作の流れは [shared/DESIGN.md](shared/DESIGN.md) で共有し、実装は OS ごとに分けます。

## 初期版の使い方

「リポジトリを開く」で既存のローカルリポジトリを選択します。変更ファイルをクリックすると追跡ファイルの差分を表示します。コミットしたいファイルにチェックを付け、メッセージを入力してコミットします。選択していないステージ済みファイルはコミットに含めません。

リネーム元と同じパスにファイルを作り直している場合、そのパスも明示的に選択する必要があります。未選択ならステージ状態を変更する前に操作を止めます。作り直したファイルをコミットに含めない場合は、一時的にそのパスから移してからリネームをコミットしてください。

Linux の差分表示では、UTF-8 として読めない文字を `�` に置き換え、画面にその旨を表示します。ファイルの内容は変更しません。

Git の `user.name` と `user.email` は利用者が設定してください。アプリはグローバル設定を変更しません。コミットに失敗すると、選択したファイルのステージ状態が残る場合があります。Git hooks は通常の Git と同様に実行されるので、信頼するリポジトリを開いてください。

## 検証

```sh
python3 -m unittest discover -s tests -v
```

Linux の Git 操作を一時リポジトリで検証します。Mac・Windows の実装は別々のコードなので、この検証だけでは両 OS の動作を保証しません。各 OS の起動・ビルド手順は各フォルダの README を参照してください。

## 今後の機能

初期版はリポジトリ選択、ブランチ名表示、変更一覧、差分、選択ファイルのコミットに限定しています。未追跡ファイルの内容表示、履歴グラフ、clone/fetch/pull/push、ブランチ操作、競合解決、Finder/Explorer の右クリック統合、署名付き配布は未実装です。
