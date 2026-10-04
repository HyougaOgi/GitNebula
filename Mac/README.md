# GitNebula — Mac

SwiftUI と Foundation Process による macOS ネイティブ実装です。
macOS 13 以上と Xcode Command Line Tools が必要です。

```sh
cd Mac
swift build
swift run
```

Git は `/usr/bin/git` を使います。コマンドラインツールが未導入なら `xcode-select --install` で導入してください。
Swift Package の開発用実行ファイルです。`.app` の配布、署名、公証、Finder 拡張は未実装です。
Linux のクラウド環境では SwiftUI をビルド・起動できないため、Mac で検証してください。
