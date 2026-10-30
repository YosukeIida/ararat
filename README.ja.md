# Ararat

Arc の操作感と Yab の縦タブを Chromium の上に作る macOS ブラウザ。設計中。

ライセンスは GPL-3.0（`LICENSE`）。

## 開発

設計は `docs/architecture.md` にある。開発用のシェル（`nix/flake.nix`、direnv が読み込む）が Rust のツールチェーンと、REA 用の Node.js・Ghidra・JDK を提供する（REA は `~/workspace/github.com/morluto/rea` で `npm ci && npm run build` を実行してから使う）。このシェルは `DEVELOPER_DIR` を nix の apple-sdk に向け、Xcode の `swift` と `swiftc` が見えなくなるため、Swift と REA は下の `xc` 関数を通して実行する。

```sh
(cd core && cargo test)                 # 中核のテスト
xc() { env -u SDKROOT DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer "$@"; }
macos/scripts/build-core.sh             # 中核をビルドし、Swift の binding を生成し直す
(cd macos && xc swift run AraratHarness) # 合成した Arc のサイドバーで harness を開く
(cd macos && xc swift run AraratHarness --check path/to/StorableSidebar.json)
xc node ~/workspace/github.com/morluto/rea/scripts/rea.mjs doctor   # devshell の Ghidra で REA を使う
```

この文書は `README.md` の日本語訳である。内容が食い違うときは英語版に従う。
