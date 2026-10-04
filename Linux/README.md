# GitNebula — Linux

GTK 4 と PyGObject によるネイティブ GUI です。Debian / Ubuntu では以下をインストールします。

```sh
sudo apt-get install python3-gi gir1.2-gtk-4.0 git
/usr/bin/python3 Linux/main.py
```

リポジトリのルートから実行してください。ディストリビューション付属の Python を使い、GTK のバインディングを読み込みます。
GUI には X11 または Wayland のディスプレイが必要です。
ヘッドレス環境での起動確認には `xvfb-run -a /usr/bin/python3 Linux/main.py --smoke` を使えます（別途 `xvfb` と `xauth` が必要）。
Git 操作のテストは `python3 -m unittest discover -s tests -v`。配布パッケージは未実装です。

GUI 経由の差分表示・選択・コミットを検証するには、GTK 4 をインストールした環境で `xvfb-run -a /usr/bin/python3 tests/gtk_smoke.py` を実行します。
