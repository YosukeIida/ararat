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
(cd macos && xc swift run AraratHarness --db "$TMPDIR/ararat.sqlite")
printf 'space 1\nselect tab-a\nstate\n' | (cd macos && xc swift run AraratHarness)   # ポインタを使わずに harness を動かす
xc node ~/workspace/github.com/morluto/rea/scripts/rea.mjs doctor   # devshell の Ghidra で REA を使う
```

harness は標準入力から `space <index>`、`select <row id>`、`state`、`width`、`reset-width`、`sidebar`、`toggle-sidebar`、`close <row id>`、`create-space <name>`、`archive-search <text>`、`archive-delete <id>`、`library [close]`、`restore <id>`、`quit` を読み、それぞれに標準出力で答える。拒否された `select` と `close` にはエラーの行を返す。入力の終わりでは終了しない。`--headless` を付けると、ウィンドウもメニューも出さず、アクティブにもならずに標準入力のコマンドだけを受け付ける（テストで使う）。⌘W は選択中の Today のタブか split を閉じ、`--db` を付けたときは閉じたことを保存する。`--db` を付けないときは `TMPDIR` のデータベースを使い、終了、SIGINT、SIGTERM のときに消す。`width` は現在のサイドバー幅を pt 単位で `ok <width>` と返し、`reset-width` は幅を 240 pt に戻して `ok 240` と返す。サイドバーの右端をドラッグすると、幅を 164〜500 pt の範囲で変更できる。View → Reset Sidebar Width でも 240 pt に戻せる。pointer を window の左端から 81 pt 未満までドラッグすると、幅を 164 pt にしてサイドバーを隠す。幅は window ごとにメモリ内だけで保持する。`sidebar` は `ok docked`、`ok hidden`、`ok floating` のいずれかを返す。`toggle-sidebar` は docked と hidden を切り替え、切り替え後の状態を返す。View → Toggle Sidebar（⌘S）でも同じ操作ができる。hidden のときに pointer を window の左端に置いて待つと、floating sidebar が現れる。行が未選択の間は floating sidebar を表示し続け、行を選ぶと pointer とアプリの非アクティブ化による非表示の規則を適用する。サイドバーの状態は永続化しない。メインスレッドが 100 ms を超えて止まると、標準エラー出力に `hitch <ms> ms` と書く。

`--db <path>` は harness が使う SQLite の workspace を指定する。space がなければ、同梱の合成 fixture、または追加の引数で指定されたサイドバーファイルをインポートし、ディスクに flush する。次回以降は再インポートせず、保存済みの workspace を読み込む。harness は終了時にも flush し、エラーを標準エラー出力に報告する。`--db` を省略すると、harness は `TMPDIR` の一時データベースを使い、終了時に削除する。編集は `WorkspaceAdapter` を通ってそのデータベースに書かれるので、`--db` があれば次回の実行でも残る。

この文書は `README.md` の日本語訳である。内容が食い違うときは英語版に従う。
