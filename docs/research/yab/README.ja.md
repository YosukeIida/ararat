# Yab の解析を再現する

この文書は `README.md` の日本語訳である。内容が食い違うときは英語版に従う。解析の結果: `../yab-static.ja.md`。

道具: `~/workspace/github.com/morluto/rea` の REA（commit 8f920bb6。`npm ci && npm run build` を実行済みのもの）と、devshell の Ghidra 12.1.4・OpenJDK 21。`$WORK` は `analysis/yab` の絶対パスで（repo の直下で `WORK=$PWD/analysis/yab`。REA は絶対パスを要する）、git の管理から外してある。解析済みの project と arm64 部分はそこに置いてある。すべて devshell の中で実行する。`xc` は README の関数で、`DEVELOPER_DIR` を Xcode に向ける。REA が Swift の補助プログラムをコンパイルするのに必要である。

## 1. arm64 部分を取り出す

```sh
lipo /Applications/yab.app/Contents/MacOS/yab -thin arm64 -output "$WORK/yab-arm64"
```

## 2. 一度だけ解析し、Ghidra の project に保存する

```sh
GHIDRA_HEADLESS_MAXMEM=48G "$GHIDRA_INSTALL_DIR/support/analyzeHeadless" "$WORK/ghidra-project" yab \
  -import "$WORK/yab-arm64" -scriptPath docs/research/yab -preScript DisableObjcMessage.java
```

Mac Studio で 24 分かかり、1.2 GB の project ができた。効く設定は 2 つある。

- Objective-C Message Analyzer を外す。有効にしたままだと、他の関数がすべて終わった後も、関数 1 つの処理に 1 スレッドが 1 時間以上（CPU 時間 3,940 秒）張り付いた。
- ヒープを上げる。Ghidra の既定の 2 GB では、名前の一覧を取る処理でメモリが足りなくなり、セッションが落ちた。

REA が自分で行う取り込みは、解析したプログラムをメモリ上にしか持たないため、落ちると失われる。必ず先に project へ解析しておく。

## 3. 1 つの REA の MCP セッションで問い合わせる

```sh
xc env GHIDRA_HEADLESS_MAXMEM=48G REA_GHIDRA_STARTUP_TIMEOUT_MS=7200000 \
  REA_GHIDRA_PROJECT_PATH="$WORK/ghidra-project/yab.gpr" REA_GHIDRA_PROGRAM_NAME=yab-arm64 \
  node docs/research/yab/rea-driver.mjs "$WORK/box"
```

driver は REA のツールの一覧を `box/tools.json` に書き出す。続いて `box/req-<n>.json`（`{"name": ツール名, "arguments": {...}}`）を名前の順に実行し、答えを `box/res-<n>.json` に書く。`box/stop` を作ると終わる。依頼のファイルは zsh の `echo` ではなく `printf` で書く（`echo` は JSON のエスケープのバックスラッシュを書き換える）。最初の依頼は `open_binary` で、引数は `{"path": "$WORK/yab-arm64", "provider_id": "ghidra"}` である。保存済みの project を使えば数秒で返る。

使えるツール: `analyze_swift_types`、`search_procedures` と `search_strings`（正規表現）、`xrefs`、`procedure_callers`、`procedure_pseudo_code`。Objective-C のメソッドの呼び出し元を探すときは、次の順に問い合わせを繋ぐ。

1. `search_strings` でセレクタの名前を探す。
2. その `xrefs` を取り、セレクタの参照に辿り着く。
3. その参照の `xrefs` を取り、`objc_msgSend` のスタブに辿り着く。
4. `procedure_callers` でスタブの呼び出し元を取る。

## 4. フローティングサイドバーと設定を観察する

観察の結果: `../yab-observed.ja.md`。2 つの Swift のスクリプトは、実行する端末にアクセシビリティと画面収録の許可を要する。`xc swiftc -O <file>.swift -o "$WORK/<name>"` でコンパイルする。

`yabprobe <winX> <rowY> <stripWidth> <step>...` は、ウィンドウの左端から始まる 1 行のピクセルを最大で毎秒 240 フレーム取り込む（座標は画面のポイントで、原点は左上である。ウィンドウの枠は AppleScript の `bounds of front window` かアクセシビリティ API で得る）。step は `m:x:y`（ポインタの移動）か `w:ms`（待機）である。移動ごとに `m <ms> <x> <y>` を出力し、サイドバーの届く位置が変わるたびに `f <ms> <edge>` を出力する。`edge` は、行の右端のページの色と異なる最後のピクセルである。ページが空白の行を選ぶ。文字にかかると edge が跳ぶ。例として、左端に 330 ms 触れる操作を示す。

```sh
"$WORK/yabprobe" 1147 1300 400 m:1600:700 w:500 m:1150:700 w:330 m:1600:700 w:800
```

計測の前に、メインウィンドウのサイドバーが閉じており、そのウィンドウが最前面にあることを確かめる。他のアプリから開いたリンクは、サイドバーの無い Yab の小さいウィンドウに入る。メインウィンドウのタブは AppleScript の `make new tab` で作る。

`settingstext [pane]...` は、開いている設定ウィンドウの各ペインをアクセシビリティ API で選び、各コントロールの種類とラベルを出力する。出力にはオーナー自身のデータ（space の名前、サイト）が含まれるため、repo に入れない。設定のファイル（`~/Library/Preferences/dev.serafim.fast.plist`）は、キーの名前と型だけを読み、値は読まない。
