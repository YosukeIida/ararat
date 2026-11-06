# Ararat のアーキテクチャ

この文書は `architecture.md`（draft 2）の日本語訳である。内容が食い違うときは英語版に従う。

状態: draft 2、2026-10-30。日本語訳: `architecture.ja.md`。レビューの履歴: `reviews/`。

本文書は、技術の選択、レイヤー、密結合にする部分と分離する部分、状態と同期の仕組み、ロードマップを定める。本文書は次の 3 本の調査ノートに基づく。

- `research/ardia-ledger.md`: Ardia（Chromium fork、React Native の UI）における設計判断と書き直し。
- `research/cra-ledger.md`: Cra（Swift + CEF）における設計判断と、Cra が必要とした CEF の回避策。
- `research/arc-dia-components.md`: 公開されたリバースエンジニアリングから収集した、Arc と Dia のコンポーネントの一覧、データ形式、Chromium の継ぎ目（seam）。

「Ardia ledger 1.4」のような参照は、これらのノートの節を指す。

## 1. 目的と制約

Ararat は、Arc のワークフロー（space、ピン留めタブと Today タブ、favorites、フォルダ、archive、command bar、Little Arc、Air Traffic Control、split view）と Yab の縦タブの挙動を、Chromium 上で Chrome 拡張とともに実現するブラウザである。

オーナーが定めた制約は次のとおりである。

- macOS を最初に対象とし、UI は Swift によるネイティブ UI とする。
- エンジンは Chromium fork とし、Chromium のツリー内に独自のレイヤーを置く。
- Windows、Linux、iPhone は後から対応する。これらを追加するときに構造の書き直しを要してはならない。
- クロスプラットフォームのコアは Rust で実装する。
- 同期は独自のサーバーを経由し、アカウントやログインを一切必要としない。
- ライセンス: GPL-3.0。
- Arc、Dia、Yab はクローズドソースである。公開された分析と、各製品の利用規約が認める静的解析を用い、コードやアセットは一切複製しない。Ardia のコード（GPL-3.0）は出典を明記したうえで再利用してよい。

## 2. 決定の一覧

| 領域 | 決定 | 理由 | 節 |
|---|---|---|---|
| エンジンの組み込み | Chromium fork とし、独自レイヤー `//ararat/core` を `//chrome:chrome_framework` にリンクする（ArcCore / ArdiaCore の方式）。どの段階でも CEF は使用しない | CEF はウィンドウモデル、タブの生成、run loop と衝突する。Ardia のエンジンパッチの行数の 77% は、Chrome のオブジェクトを CEF 越しに受け渡すためだけに存在した（Ardia ledger 1.1）。Cra は約 30 件の CEF 回避策を必要とした（Cra ledger 3.1） | 4 |
| エンジンのベース | Chromium と ungoogled-chromium のパッチセット（オーナーの選択、2026-11-04） | Helium は ungoogled-chromium の上に作られており、追加の変更の多くは Ararat が外すもの（パスワードマネージャーの削除、キーチェーンの名称変更、Sparkle、オンボーディング、!bangs、Web Store のプロキシ）である。コーデックは GN args で得られ、パッケージングは自前のものに置き換える。Ardia は Helium に移った後、Helium と ungoogled の動作を元に戻すパッチを 18 件持ち、移った理由は記録されていない（Ardia ledger 1.2） | 4.2 |
| エンジン ↔ アプリの API | framework からエクスポートする、手書きで型付きの Objective-C API を Swift から呼び出す | Swift は生成したグルーコードなしで Objective-C をインポートできる。Dia も Objective-C を Swift に公開しているが、146 個のクラスを mojom から生成している | 4.4 |
| run loop | Chromium がプロセスとメインループを所有し、AppKit の UI はその内部で起動する | 外部からのポンプに起因するバグを排除する（Ardia ledger 1.1） | 4.5 |
| ウィンドウモデル | アプリのウィンドウ 1 つにつき、Views を基盤とする `NSWindow` を 1 つ置き、そのウィンドウに表示するプロファイルごとに Chrome の `Browser` を 1 つ保持する。タブのビューは独自のビューツリーに配置する | Chrome の bubble とダイアログはウィンドウに付随する。プロファイルの切り替えはビューの差し替えで済む。オーバーレイは通常のサブビューとして実装できる | 4.6 |
| 状態の所有 | Rust のコアが workspace と live-tab coordinator を所有し、Chrome の `TabStripModel` が live タブを所有する。両者は epoch で修飾し、revision を付けたトランザクションを介して接続する | 1 つの事実につき書き手は 1 つとする（Ardia ledger 1.4）。Rust に置いた coordinator はすべてのプラットフォームで再利用する | 5 |
| コア | Rust の crate `ararat-core`、SQLite のストレージ、Swift 向けの UniFFI バインディング、C++ 向けの C ABI | macOS、Windows、Linux、iPhone で同一のコアを使用する | 6 |
| macOS の UI | 動きのある部分はすべて AppKit、設定とオンボーディングは SwiftUI | Cra は SwiftUI から AppKit へ移行した後、space のスワイプ時のメインスレッドの処理時間が 1900 → 440 ms になったことを計測した（Cra ledger 12） | 7 |
| 同期 | エンドツーエンド暗号化とし、アカウントを必要としない。独自サーバーは、認証済みで追記のみの blob を中継するブラインドリレーとする。デバイスはリカバリーフレーズ、または PAKE（パスワード認証鍵交換）で認証したペアリングコードで参加する | 「独自サーバー、ログインなし」の条件を満たす。Chromium の同期エンジンや共有フォルダが存在しない環境（iPhone、Windows）でも動作する | 8 |
| プロセス | スコープ（Opus 5.5）→ 2 席で並列実装（Codex `gpt-6.1-terra`、high、labteam と、OpenCode の GLM-5.3-Flash。2026-11-06 から無料モデル `opencode/glm-5.3-flash-free`）→ レビュー（Opus 5.5）。オーナーの選択、2026-11-04。際どいエッジケースのバグは Codex から始める | オーナーの規則（`AGENTS.md`） | 13 |

## 3. レイヤーとリポジトリの構成

```
ararat/
  core/            Rust workspace: ararat-core (model, rules, coordinator, import, sync client), ararat-ffi (UniFFI + C ABI)
  server/          Rust: the sync relay (phase 8)
  engine/
    build-inputs.toml  the pinned build identity (4.7)
    ararat/        our in-tree layer, copied to //ararat/core
    chrome/        our files under //chrome/browser/ararat
    patches/       series + patches against the base
    scripts/       apply（series のあとでレイヤーを rsync）、series-check、gen、build、smoke
  macos/           one SwiftPM package
    Sources/ararat_ffiFFI/  C module for the core's UniFFI header; links the Rust static library
    Sources/AraratKit/      Swift adapter over the core bindings (generated) and, later, the engine API
    Sources/AraratUI/       AppKit + SwiftUI components (library)
    Sources/AraratHarness/  UI harness: real components on real core data, a placeholder where the page goes
    scripts/build-core.sh   builds the core and regenerates the bindings
    Sources/Ararat/         アプリの起動実行体: framework を読み込み、ChromeMain を呼ぶ
    scripts/bundle-app.sh   エンジンの Chromium.app を Ararat.app に組み、ad-hoc で署名する
  docs/
```

harness はアプリの代替ではなく恒久的な開発ツールであり、UI の作業が Chromium のビルドを待つことはない。Cra の command file と Ardia の dev harness も同じ役割を果たしている。

### 依存の方向

```
macOS App ──► AraratUI ──► AraratKit ──► ararat-ffi ──► ararat-core
                               │
                               └──► engine ObjC API (//ararat/core) ──► Chromium //chrome
```

- `ararat-core` はプラットフォーム固有のものに一切依存せず、エンジンや UI を呼び出さない。コアが判断し、アダプターが実行する。
- `AraratUI` はエンジンを直接呼び出さない。エンジンとコアのハンドルを保持するのは `AraratKit` だけである。
- `AraratKit` は薄いアダプターである。`AraratKit` はエンジンのトランザクションをコアの coordinator へ転送し、coordinator が返すエンジンのコマンドを実行する。規則はコアに置くため、Windows と Linux ではアダプターだけを再実装する。
- macOS では、エンジンはコアをリンクせず、アダプターが同一のブラウザプロセス内で両者を橋渡しする。Windows と Linux では、Views の UI が C ABI を介してコアをリンクする（10 節）。
- Chrome のファイルが参照するのは独自の hook ヘッダー（4.3）だけであり、独自のクラスは参照しない。

## 4. エンジン

### 4.1 密結合にする部分と分離する部分

| 部分 | 結合 | 場所 | 規則 |
|---|---|---|---|
| 独自の `BrowserWindow`、`BrowserDelegate`、UI の seam の実装、セッションの永続化、ObjC API | 密結合、ツリー内 | `//ararat/core`、`//chrome/browser/ararat` | 新規ファイルのみとする。Chrome の GN ルールでビルドする |
| Chrome 自体のファイルへの編集 | 最小限、hook として分離 | `engine/patches/` | 各編集は、1 つの共有ヘッダーで宣言する関数ポインタの hook とする。1 パッチにつき 1 つの関心事とする |
| ベースのパッチセット（ungoogled-chromium） | 取り込み、ガード付き | `engine/patches/series` | スキップリストとガードにより、スキップしたパッチが含まれないこと、およびスキップによって保護している箇所に何も手が入らないことを検査する |
| Rust のコア、同期、インポート | 分離 | `core/` | Chromium の型を使用しない |
| AppKit の UI | 分離 | `macos/` | エンジンとは `AraratKit` を介してのみ通信する |

### 4.2 ベースとパッチの管理

- クリーンな Chromium の revision とベースのパッチセットは、`engine/build-inputs.toml` で別々に固定する。
- ベースは ungoogled-chromium とする（オーナーの選択、2026-11-04。Helium と比べた理由は 1 節）。ungoogled-chromium の全パッチを、維持・スキップ・対抗パッチのいずれかに分け、セキュリティ上の帰結を記した一覧は `docs/research/ungoogled-inventory.md` の 8 節にある。phase 2 では、137 本のうち 25 本と、こちらの 2 本（component updater を保つ対抗パッチは同 8.6 節、もう一方は ScreenAI の sandbox パラメータを除く `ararat/remove-screenai-sandbox-parameter.patch`）をビルドする。評判のソース（14）をオーナーが決めるまで、Google Safe Browsing をビルドに残すので、9 の拡張の kill switch は有効のままである。ドメインの置き換えとバイナリの削除は行わない（我々の規則、暫定）。固定する版は、phase 2 で 1 回計測したリベース（後述）の後の 157.0.8103.39 である。
- それまでは Helium を暫定のベースとしていた。一覧やリベースで ungoogled-chromium の手間が見込みより大きいと分かった場合は、Helium を比較の候補とし、Ardia に倣ってこちらの選択と衝突するものをスキップする（Ardia ledger 1.2）。
- パッチの順序の唯一の正本は `engine/patches/series` である。パッチ名は関心事を表し、順序を示す接頭辞は付けない。
- パッチの実体は、固定した ungoogled のコミットから `engine/patches/ungoogled/{generic,macos}/` に取り込み、両プロジェクトの BSD-3 の LICENSE も合わせて置く。generic のパッチは、ungoogled-chromium の 157 向けの pull request（#4032、2026-11-05 の時点で未 merge。merge されたらそのコミットから取り込み直す）の head からバイト単位で同一のまま取り込む。macOS のパッチは 156 の macOS のコミットから取り込み、`disable-crashpad-handler.patch` だけを手で 157 に当て直した。コミットの一覧は `engine/patches/README.md` にある。`engine/patches/ararat/` はこちらのパッチを置く場所である（我々の規則）。
- `series` 全体を適用・検証するのは `engine/scripts/` の bash スクリプト群である: `env.sh` が共通の環境とユーティリティを担い、`fetch` がタグの取得と DEPS 同期、`apply` がリセットと no fuzz の系列適用に加えてレイヤーのコピー（`engine/ararat/` → `src/ararat/core/`、`engine/chrome/` → `src/chrome/browser/ararat/`）、`series-check` が系列のバイトとコピーされたレイヤーの検証、`gen` が args と GN の生成、`build` がロックと autoninja、`smoke` が headless 確認（我々の規則）。
- `series-check` は、系列が触る全ファイルとコピーされたレイヤーのファイルの SHA-256 を、前回の正常な apply で記録したマニフェスト（`engine/patch-state.sha256`, `engine/` にコミットする）と、読み取り専用で比較し、コピー先のレイヤーディレクトリの余分なファイルも拒否する。リセットも適用もせず、マニフェストが別の series のために記録されたものであるときも拒否する。エンジンのビルドの前に毎回実行する。`build` は自身の前にこれを実行し、1 バイトでも違えば、ツリーに触れずに「`apply` を実行せよ」と言って止まる。`build` はリセットも再適用もしない（我々の規則）。
- `apply` は、パッチ済みのファイルをディスク上のバイトと違うときにだけ書く。ツリーが前回の正常な apply のバイトに一致し、series も変わっていなければ何も書かず、mtime をすべてそのままにする。そうでなければツリーを pristine にリセットし（src と系列が触るすべての DEPS リポジトリ）、series を順に fuzz なしで適用し、マニフェストを書き直す。最初の失敗でパッチ名とファイル名を出して止まり、ツリーを半適用ではなくリセット済みで残す（我々の規則）。
- phase 2 の series は、取り入れた 25 パッチとこちらの 2 パッチからなる（我々の規則）。対抗パッチの `ararat/restore-component-updater.patch` は、`block-requests` の `components/update_client/update_checker.cc` の 1 hunk だけを打ち消すので、apply の後にはこのファイルが素の Chromium とバイト単位で同一に戻る（156 で確認済み）。もう一方の `ararat/remove-screenai-sandbox-parameter.patch` は、ScreenAI サービスの sandbox パラメータ（コンポーネントのバイナリのパスを渡す branch）を `chrome/browser/chrome_content_browser_client.cc` から除く。
- ソースは tarball でなく、固定タグの git + gclient と Chromium 固有の固定ツールチェーンから取り、ungoogled の pruning.list は実行しない（gclient が置くプリビルドのツールチェーンを消すから）（我々の規則）。
- PGO: 156 の固定の `chrome/build/mac-arm.pgo.txt` が指す mac-arm のプロファイル（約 88.9 MB）は公開の optimization-profiles バケットにあり、gclient のフックが取得できる。ただし `.gclient` で `checkout_pgo_profiles` を立てたときだけで、`chrome_pgo_phase=2` のままでは `gn gen` が拒否する。phase 2 は `chrome_pgo_phase=0` で走り、プロファイルは取得していない。約 89 MB の取得を払うかどうかは design の判断である（我々の規則）。
- series の適用は 156 のツリーで 11 秒であった（2026-11-05、リセット込み。計測は 26 本のときの値で、現在の series は 27 本）。mtime を保つ再適用は何も書かず、約 10 秒、すべて検証の時間である。
- 157.0.8103.39 へのリベース（2026-11-05、1 回計測）: 取得と DEPS の同期に 5 分 45 秒かかった。当たらなくなった generic の 14 本は、ungoogled-chromium の 157 向けの pull request（#4032、157.0.8103.38 向け）の版に替えた。`disable-crashpad-handler.patch` は、crashpad の `InitialStart` に `embedder_port` 引数が増えたので、手で当て直した。その後、27 本すべてが fuzz なしで 129 ファイルに当たった。取得の開始からおよそ 8 分である。こちらの 2 本はそのまま当たった。
- Chrome のファイルへの大きな編集は、新しいクラスと小さな hook に書き直す（Ardia は 1,012 行の PiP パッチをこの方法で書き直した）。
- 指標はパッチの数ではなく、Chrome のファイル内の hunk の数とする。

### 4.3 Hook

hook は `ararat_hooks.h` で宣言する `g_ararat_*` の関数ポインタである。パッチを当てた Chrome のファイルはこのヘッダーをインクルードするが、`g_ararat_is_window` は例外であり、`chrome/browser/ui/read_anything/read_anything_side_panel_controller.cc` でヘッダーを使わずに定義するため、宣言とのシグネチャの違いはコンパイル時に検査されない。hook が未設定のとき、Chrome は標準どおりに動作する。今日の一覧: `g_ararat_is_window` は read-anything の viewless 経路で独自ウィンドウを識別する。`chrome/browser/chrome_content_browser_client.cc` の `g_ararat_add_browser_main_extra_parts` は、client が作ったブラウザのメインパーツを独自レイヤーに渡し、レイヤーは `AddParts` を通じて独自の `ChromeBrowserMainExtraParts` を加える。`chrome/browser/ui/browser.cc` の `g_ararat_create_browser_window` は `ARWindowHost` が pending の間だけ設定し、それ以外は標準ウィンドウを生成する。hook は `Browser*` ではなく `BrowserWindowInterface*` を受け取る。upstream は呼び出し側を interface へ移すため `browser.h` の利用を `browser_header` の visibility で制限しており、独自レイヤーには interface だけで足りるためである。エクスポートする名前は、`ararat.exports`（リンカの `-exported_symbols_list`）と、`link-ararat-layer.patch` が `chrome/app/framework.order` に追加するシンボルの両方に並べる。`verify_order.py` は order ファイルにない framework のエクスポートを拒否するためであり、両者の違いはスクリプトが断り、`engine/ararat/` に定義のない名前も断る（我々の規則）。

### 4.4 エンジン ↔ アプリの API

- framework は `//ararat/core` から手書きの Objective-C クラスをエクスポートする（たとえば `ARWindowHost`、`ARTab`、`ARProfile`、`ARExtensions`、`ARDownloads`、`ARAutocomplete`、`ARPasswords`）。Swift はこれらを framework の module map を介してインポートする。
- タブ API は coordinator の ID を受け取る。アプリは `initWithContentView:windowId:` に workspace の window ID を渡す。`openURL:commandId:itemId:` は open が受け付けられたか（完了またはキューに積まれた）を返し、開いたタブは `-tabs` から live ID（command ID）で探す。`activateWithCommandId:`、`closeWithCommandId:`、`setItemId:` はそのタブを操作する。Browser の破棄中の open は FIFO でキューに入る。完了の transaction にその live ID が含まれない open は失敗したと見なす。受け付けた open が失敗したときは transaction として報告する。それは次の revision で、cause は `Command(<その open の ID>)` であり、strip は現状のままで、Browser が無いウィンドウでは空の strip を運ぶ。拒否された open（host が閉じている、epoch が無い、URL が不正など）は `NO` を返し、何も報告しない。Chrome が作成したタブには `chrome-` を先頭に付けた UUID を割り当て、item ID は付けない。`ARWindowHost` は delegate から page card を取得し、`{epoch, rev, cause, strips}` を delegate に報告する（我々の規則）。
- `pageCardForWindowHost:` は値を返すだけの getter とし、KVO の observer はタブコマンドを非同期に dispatch する（我々の規則）。
- feed はエンジンのプロセスごとに、起動時刻に基づく epoch と 1 つの revision を持つ。最初の host に delegate を設定すると、cause が `Engine` の空の rev 0 スナップショットを同期的に報告する。その最初の delegate が設定されるまで、タブコマンドは何もせず、`openURL:` は `NO` を返す。その後の変更ごとに revision を増やす。閉じたウィンドウは空の strip で報告し、省いたウィンドウは変更なしと扱う（我々の規則）。
- すべてのクラスをメインスレッドに固定する（他のスレッドからの呼び出しはプログラミングエラーであり、debug ビルドでは abort する）。Chrome のオブジェクトをラップするオブジェクトは、Chrome のオブジェクトが破棄された時点で無効化する。ラッパーは Swift が所有し、Chrome のオブジェクトはエンジンが所有する。無効化された `ARTab` へのコマンドは何もせず、エラーを返さない。初回のスナップショット以降、delegate への通知は host を弱参照し、メインキューに post する（我々の規則）。
- UI が必要とするサービス（パスワード、autofill、拡張、ズーム、検索エンジン、履歴、ブックマーク、ダウンロード）は、独自レイヤーから Chrome のサービスを直接呼び出す。`chrome://` の WebUI ページをスクリプトで操作することはしない（Ardia ledger 1.4）。
- アプリとエンジンは同時に出荷する。互換性のための分岐は設けない。起動時に API のバージョンを 1 回検査し、不一致の場合は abort する。

### 4.5 プロセスと run loop

- バンドルの起動実行体（`Sources/Ararat`）が framework を読み込む。ブラウザプロセスは独自の `AraratMain` を呼ぶ（ランチャーのコールバックを保存し、extra-parts の hook を設定して `ChromeMain` を呼ぶ）。ヘルパーは標準の `ChromeMain` を呼ぶ。hook は標準の client のパーツに独自の `ChromeBrowserMainExtraParts` を加え、それらが `PostBrowserStart` でランチャーの `started` コールバックを、`PostMainMessageLoopRun` で `will_shut_down` を呼ぶ。`started` は `PreMainMessageLoopRun` の中で、起動ブラウザが開いた後、メインループが回る前に発火する。ハンドラはループが回っていると見なしてはならない。`AraratQuit` はどこからでも呼べる。ループが近づく前の要求は、started の段階で叶う。`--ararat-check=<name>` は、`--user-data-dir` が `$TMPDIR` の下にあり `--use-mock-keychain` があるときだけ実行され、そうでなければ 2 で終わる。`started` は 1 行の JSON `{"check":"started","ok":true,"browsers":N}` を出して終了する。`window` は非表示の host、native window、hit test を検査し、Browser の破棄を待つ。`NSApp` は Chrome の `BrowserCrApplication` である。Chromium の起動前に `NSApp` に触れる処理は存在せず、AppKit の UI は Chromium の起動時のコールバックから生成する（我々の規則）。
- Chrome の `AppController` は、終了、Dock、ログアウトのイベントを所有する独自のオブジェクトに置き換える。このオブジェクトは、キャンセル可能なクローズと終了（beforeunload、ダウンロードの確認）と、ウィンドウが 1 つも開いていないときの keep-alive を実装する（Ardia ledger 1.1）。

### 4.6 ウィンドウ、タブ、および Chrome の UI から引き継ぐ責務

**ウィンドウとプロファイル。**

- アプリのウィンドウ 1 つは、Views を基盤とする `NSWindow`（`NativeWidgetMacNSWindow`）1 つである。これにより、Chrome の bubble、ダイアログ、メニュー、autofill のドロップダウンが子ウィンドウとしてこのウィンドウに付随する。
- ウィンドウに表示する各プロファイルは、それぞれ専用の Chrome の `Browser` を持つ。その `BrowserWindow` は独自のオブジェクトであり、`BrowserView`、フレーム、タブストリップ、ツールバーを持たない。
- 拡張から見たウィンドウの意味論は次のとおりである。プロファイルごとの `Browser` は、それぞれ別個の拡張のウィンドウ id である。アプリがアクティブな間は、キーウィンドウで表示しているプロファイルの `Browser` がフォーカスを持つウィンドウである。他のアプリのウィンドウで表示している `Browser` はフォーカスなしだが最小化はしていないものとし、非表示のプロファイルの `Browser` はフォーカスなし、かつ最小化に相当する bounds を報告する。アプリが非アクティブになると、すべてがフォーカスなしになる。拡張自身のコンテキスト（popup、side panel、タブの content script）の `currentWindow` は、そのコンテキストがある `Browser` とする。background のコンテキストでは、フォーカスを持つ `Browser`、アプリが非アクティブな間は最後にフォーカスを持った `Browser` とする。これらの規則により、`windows.getCurrent`、フォーカスのイベント、`tabs.query({active: true, currentWindow: true})` は、ユーザーが見ているものと一致する。非表示のプロファイルのウィンドウに対する `windows.update({focused: true})` は、アプリのウィンドウをそのプロファイルに切り替える。spike では、2 つのアプリのウィンドウに表示した 2 つのプロファイル、その間でのフォーカスの移動、アプリの非アクティブ化、拡張が生成したウィンドウ、非表示のプロファイルで動作する拡張を用いて、この挙動を検証する。
- 拡張のポップアップウィンドウ（`windows.create({type: "popup"})`）は実際のポップアップウィンドウのままとする（Cra ledger 10）。独自の内部用ヘルパーウィンドウは拡張から隠す（Ardia ledger 1.7）。プロファイルの `Browser` は内部用ではなく、拡張から見える。

現在の `AraratBrowserWindow` は表示、アクティベーション、bounds、タイトル、native window の操作を host Widget に委ね、close は Chromium の unload controller に渡す。toolbar、location bar、dialog など未実装の UI の処理は空の結果を返すか、何もしない。`ARWindowHost` は受け取った `NSView` を `NativeViewHost` に配置し、アプリは Browser の破棄まで host を保持する（我々の規則）。

**タブ。**

- アクティブなタブの `WebContentsViewCocoa` を page card の唯一の subview にする。非アクティブなビューはツリーから外し、対応する `WebContents` を hidden にする。最後のタブを閉じると Browser は破棄されるが host は残り、次の open で同じ epoch の Browser を作る（我々の規則）。

- タブの `WebContentsViewCocoa` は独自のビューツリーに配置する。これらのビューをどの compositor（描画の合成を担う機構）が所有するか（タブのビューごと、プロファイルごと、ウィンドウごとの共有）は spike で決定する。Ardia は、ビューごとの compositor がタブの切り替えのたびに 1〜2 回のリフレッシュ分の遅延を生むこと、および後から変更すると描画の書き直しを要することを見出したためである（Ardia ledger 1.3、1.6）。spike では、各候補について、切り替え時の最初のフレームまでの遅延、バックグラウンドのページの活動、オクルージョン、リサイズ、分割ペイン、ディスプレイの変更を計測する。
- 新しいコンテンツ: renderer が生成したウィンドウは、既存の `WebContents` と保留中のナビゲーションの状態を保持したまま、`AddNewContents` を経由して独自レイヤーに届く。修飾キー付きのクリックやフォームの target は別の経路（`OpenURLFromTab`）を通る場合がある。固定した revision 上のすべての生成経路を列挙し、それぞれ個別にテストする。対象は、POST の target、features 指定の有無それぞれの `window.open`、⌘ クリック、shift クリック、opener の関係、ブロックされたポップアップである。Chrome が自ら生成するウィンドウ（`chrome.windows.create`、シークレット、ドッキングしていない DevTools）は、`Browser` のコンストラクタ内の hook によって独自レイヤーへ回す。
- 1 つのページは 1 か所にだけ表示する。live のページは、ちょうど 1 つのペインにだけ表示する。2 つ目のウィンドウやペインが同じ workspace のタブを選択した場合、key になったウィンドウがページを取得し、もう一方のウィンドウは再び key になるまで、ぼかしたスナップショットのプレースホルダーを表示する（Arc の挙動、Cra ledger 19）。1 つのウィンドウの中では、フォーカスを取ったペインがページを取得し、もう一方のペインはプレースホルダーを表示する。分割ペインの spike でこれを確かめる。ウィンドウを閉じるときは、別のウィンドウがまだ表示しているページを再読み込みせずに移動する（Cra ledger 20）。
- 分割ペイン: 各ペインは 1 つのタブを保持する。フォーカスのあるペインのタブが、その `Browser` における Chrome の active タブである。他のペインは表示されているが非 active である。区切り線のドラッグ中はページのサイズを固定し、ドラッグを離したときに 1 回だけリサイズする（Cra ledger 21）。

**Chrome の UI から引き継ぐ責務。** `BrowserView` を用いないため、`BrowserView` が担っていたすべての責務に所有者が必要である。spike でこの表を完成させる。最初の項目は次のとおりである。

| 責務 | 所有者 |
|---|---|
| exclusive-access context | 画面上での入力前の U7、fullscreen の動作は U15（現在は null で、ページへの入力でクラッシュする） |
| find bar | U16（現在は null で、検索コマンドでクラッシュする） |
| location bar | U16（現在は null で、bubble anchor の取得時にクラッシュする） |
| download bubble controller | download UI の実装時（現在は null で、deep scan のプロンプトでクラッシュする） |
| modal dialog host と autofill bubble handler | U12（現在は null で、ダイアログの位置指定や住所の bubble でクラッシュし得る） |
| accelerator provider と pinned toolbar actions | accelerator は U16、pinned actions は toolbar の実装時（現在は null で、呼び出し側がクラッシュし得る） |
| read-anything の viewless ウィンドウでの close | U5 |
| pinned tab の close における `BrowserView` CHECK（`browser_commands.cc:1521`） | 後続の unit。未修正 |
| 権限のプロンプトとその拒否 | seam の実装（ホスト側の UI） |
| 外部プロトコルの確認 | seam の実装 |
| デバイスの chooser（USB、HID、Bluetooth、シリアル）、Cast | seam の実装 |
| フルスクリーンとポインタロックの解除の警告 | seam の実装（`ExclusiveAccessContext`） |
| 拡張のアクションのポップアップ、インストールのプロンプト、インストール完了の bubble、サイドパネル | seam の実装 |
| パスワードと autofill の bubble | seam の実装。autofill のドロップダウンは Chrome の子ウィンドウのままとする |
| ページ内検索 | Chrome の `FindTabHelper`、ホスト側の UI |
| ページとブラウザのコマンドの間のキーボードイベントの振り分け | ホスト。Chrome の規則に従う: ページを先に処理し、処理されなかったキーはメニューに戻し、予約キーは最初に取得する（Cra ledger 11） |
| フォーカスの受け渡し（⌘L、⌘T の直後の貼り付け） | ホスト。入力欄はメインスレッド上で同期的にフォーカスを受け、command bar の索引は後から届き、それまでに打った文字と Return を再生する（Ardia ledger 1.10） |
| ウィンドウのアクセシビリティツリー | ホストのビューと Chrome の Web アクセシビリティ |
| ダウンロードの UI | ホスト（Chrome の bubble は無効にする） |
| セッションの永続化 | 独自レイヤー（下記） |

**セッション。** 独自の `Browser` については Chrome のウィンドウの自動復元を無効にするが、永続化の責務そのものは放棄しない。独自レイヤーは、各タブのナビゲーションスタック、選択中のエントリ、セッションストレージの名前空間を、Chrome 自身のセッションのコードでシリアライズし、コアの安定した項目 id をキーとして保存する。保持期間は次のとおりである。live タブと、読み込まれていない workspace のタブは、エントリを保持する。archive したタブは、archive が存続する間エントリを保持する。最近閉じたタブは Chrome の上限に従う。タブを復元するときはエンジンにコアの id を渡し、エンジンは履歴を含めて `WebContents` を再構築する。

### 4.7 ビルドと成果物の同一性

- ビルドはリポジトリ外の `~/chromium-build` に置く。通常の作業中はインクリメンタルビルドのみを行う。
- Ardia の数値: M5 Pro で初回ビルドに約 2〜2.5 時間、インクリメンタルビルドに約 7 分（コンパイルと ThinLTO の再リンク）、ディスクは約 45 GB。こちらの数値（2026-11-04、Mac Studio M3 Ultra、28 コア。素の Chromium 157.0.8103.39 の Release で `symbol_level=0` とプロプライエタリのコーデックを有効にし、ThinLTO と PGO は使わない。テストの席と CPU を分け合っていた）: 浅いソースの取得に 9.5 分、依存の取得に約 9 分（gclient の既定の並列数では googlesource が 429 を返し、`-j 4` で通った）、初回ビルドに 1 時間 16 分（57,508 手順）、`chrome/browser/ui/browser.cc` を変えた後のインクリメンタルビルドに 36 秒、ディスクは 39 GB。エンジンのビルドは nix の devshell の外で行う。devshell の `MACOSX_DEPLOYMENT_TARGET` が Chromium の rustc に渡り、ビルド用のツールのリンクを壊すからである。
- phase 2 の正式なビルド（2026-11-05、同じ機体。`engine/args.gn` は official、ThinLTO、`chrome_pgo_phase=0`、Xcode 27.2、series は 27 件）: 156.0.8078.79 の初回のフルビルドは、リンクエラーで止まるまでに 1 時間 31 分（56,691 手順）であった。series にパッチを 1 本足すと、当たっているファイルをすべて戻して書き直すため、再ビルドに 3,343 秒（50,522 手順）かかった。`chrome/browser/ui/browser.cc` を変えた後のインクリメンタルビルドは 155 秒（6 手順で、ほとんどが ThinLTO の再リンク）、`out/Ararat` は 24 GB である。157.0.8103.39 のフルビルドは 4,821 秒（57,021 手順）であった。`smoke` は両方で通った。157 では、ビルド直後の初回の起動が 1 度失敗し、その後の 4 回は通った（`smoke` が終了コードと stderr を出す前の計測である）。
- phase 3 の日々の作業は out/Dev で行う。`gen --dev` が書き、`build --dev` がビルドする（我々の規則。2026-11-05 に 157 で計測）。`engine/args.gn` に `is_official_build=false`、`use_thin_lto=false`、`symbol_level=0`、`blink_symbol_level=0`、`dcheck_always_on=false`、`enable_precompiled_headers=false` を加える（このツールチェーンでは base の `precompile.h` が module interface unit としてコンパイルされて失敗するため、precompiled header を切る）。フルビルドは 8,154 手順目で 1 度中断し、再開した分が 2,673 秒（36,301 手順）であった。ディスクは 7.2 GB、変更なしのビルドは 6 秒、`chrome/browser/ui/browser.cc` を変えた後は 31 秒（9 手順）である。配る版は `out/Ararat` で作る。こちらの層をリンクした後（2026-11-05）: 層を加えた後の最初の `build --dev` は 205 秒（1,374 手順）、変更なしの `build --dev` は 6 秒であった。`engine/ararat/` の 1 行を変えると、`apply` に 28 秒、`gen --dev` に 3 秒、`build --dev` に 28 秒（5 手順）かかる。
- ビルドが使う CPU は 95 % までとし、ビルド中も機体を使えるようにする（owner の規則、2026-11-05）。siso は `-j` を受け付けないので、`build` は `hw.ncpu` の 95 % を切り捨てた数（28 のうち 26）を `-local_jobs` で渡す。
- エンジンのビルドはロックのもとで一度に 1 つだけ実行する。ロックは `~/chromium-build/.engine.lock` の mkdir(2) ロック（持ち主の pid を `pid` ファイルに置き、exit と INT/TERM で外す）である。`fetch`、`apply`、`gen`、`build` が取り、取れないときは断る。pid が空または読めないロックは奪わずに断り、エンジンコマンドが動いていないのを確かめてから `rmdir "$ARARAT_ENGINE_LOCK"` で手で外す。持ち主が死んでいるロックはアトミックに奪い直す。手でロックを持ちたいときは、ディレクトリを作って `pid` に生きている pid を書く（我々の規則）。
- エンジンの環境は `engine/scripts/env.sh` が整える: `MACOSX_DEPLOYMENT_TARGET` と `SDKROOT` を外し、`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` を置き、`DEPOT_TOOLS_UPDATE=0` を置き、PATH を depot_tools と `/usr/bin:/bin:/usr/sbin:/sbin` に限定する。`/nix` からも呼び出し元の PATH からも何も流さない。nix の xcbuild の `xcrun` は MobileAsset の Metal ツールチェーンを見つけられず、引き継いだ PATH のままでは ANGLE のシェーダーのアクションが "missing Metal Toolchain" で失敗するからである。gclient は `-j 4`（既定の並列数では googlesource が 429 を返す）（我々の規則）。
- `fetch` は shallow にタグを取得して `gclient sync -D --no-history --shallow -j 4 --force` を行い、工程ごとに所要時間を出力する。
- `gen` は `engine/args.gn`（ハッシュを `engine/build-inputs.toml` の記録と照合する）を `out/Ararat/args.gn` に書き、`ararat_engine_version` のスタンプ（ビルドした Chromium のバージョンと、series・パッチ・レイヤーを合わせたマニフェストのハッシュ）を付け加え、`gn gen` を実行する。すべてエンジンのロックのもとで行う（ビルド中に args を書き換えたり `gn gen` を実行したりすると、実行中のビルドの下で ninja が再生成を行う）。スタンプはレイヤーの編集のたびに変わるので、レイヤーの編集は配布用の args を変え、次の `out/Ararat` のビルドは再生成と再リンクを行う。args.gn のスタンプがツリーより古いとき、`build` は「`gen` を実行せよ」と言って止まる（我々の規則）。
- `build` はまず読み取り専用の series-check を実行し、ツリーが記録されたバイトを再現しなければ、ツリーに触れずに「`apply` を実行せよ」と言って止まる（リセットも再適用もしない）。通ればロックを取り、`autoninja -C out/Ararat chrome` を上の CPU の上限のもとで行い、所要時間と手順数を出力し、`~/chromium-build/build-times.jsonl` に 1 行の JSON 記録を書く。
- `smoke` はビルドしたアプリを、`$TMPDIR` の使い捨て profile と `--use-mock-keychain` で `--headless=new --dump-dom`（data: URL）と `--version` の 2 回で実行する。どちらかでも失敗すれば 0 以外で終わる。実の login keychain を使うと、out/Dev のビルドは DOM を出した後に「Teardown watchdog expired」で終了コード 2 になり、keychain に「Chromium Safe Storage」の項目が作られる（我々の規則）。
- GN args は 1 つのファイルに置く: official build、ThinLTO、PGO、DCHECK なし、シンボルの除去、`proprietary_codecs=true`、`ffmpeg_branding="Chrome"`、独自のブランディング。phase 2 の実装（`engine/args.gn`）は ungoogled の `flags.gn` と `flags.macos.gn` にこちらの入力 `target_cpu="arm64"` を加えた形で、`chrome_pgo_phase` は暫定で 0 とし、独占の API キーは設定しない。ブランディングは phase 3 に回す。
- `engine/build-inputs.toml` は、バイナリを決定するすべての要素を固定する: Chromium のコミット、ベースのパッチセットのタグ、解決済みの DEPS のハッシュ、GN args、Xcode と SDK のバージョン、アーキテクチャ。エンジンの成果物のキーは、このマニフェストのハッシュと `engine/` の git tree である。公開する成果物には SHA-256 と provenance の記録を付ける。
- CI ではエンジンをビルドしない。エンジンはローカルでビルドし、このキーのもとで prerelease として公開する。
- 各リリースの Corresponding Source（GPL が定める対応ソース）は、タグ、`build-inputs.toml`、パッチの series、および固定した upstream を取得してツリーを再現するスクリプトである。

### 4.8 初日からのセキュリティとデータの完全性

- Safe Storage のキーチェーン項目の名前は最初のビルドで確定し、以後変更しない。鍵を暗黙に再生成することはしない。新しいプロファイルであることが証明できる場合にだけ生成し、それ以外の場合は再試行したうえで fail closed とする（Ardia ledger 1.8）。
- 復号したパスワードは、エンジンとコアの両方で、解放の前にゼロで上書きする。
- 子プロセスは macOS のサンドボックス内で実行する。
- アプリのバンドルには何も書き込まない。リリースの検査では、起動後に署名を再検証する。
- テスト用の自動操作のチャネルは Web ページから到達できないようにし、テスト専用のスイッチは、配布用でないビルドで、かつスクラッチのデータディレクトリを用いる場合にだけ機能する（Cra ledger 33、Ardia ledger 1.8）。
- WebRTC はローカル IP を公開しない: mDNS を無効にし、`default_public_interface_only` とする（Cra ledger 27）。

### 4.9 セキュリティの保守

- 日次のジョブが、Chromium の新しい stable リリースと、ベースのパッチセットの新しいタグを検出する（Cra ledger 6）。
- パッチの遅延の上限は、upstream の stable リリースの時点から数える。実際に悪用されている脆弱性の修正は 48 時間以内に出荷し、それ以外の High と Critical の修正は 7 日以内に出荷する。
- 同じ Chromium の milestone 上でのセキュリティ修正のみの再ビルドはインクリメンタルとし、事前に承認済みとする。milestone の更新にはフルビルドが必要であり、それを事前承認とするかはオーナーの判断である（14）。
- ベースのパッチセットが上限を超えて Chromium から遅れた場合は、自らより新しい Chromium にリベースし、ベースのパッチを引き継ぐ。
- オーナーを含め、誰かが日常的に使用するには、次の 2 点が必要である: 機能する更新の経路（Sparkle）と、URL とダウンロードの評判の検査（Safe Browsing、または選定した同等のもの、14）。

## 5. 状態の所有

### 5.1 誰が何を書くか

| 事実 | 所有者 | 備考 |
|---|---|---|
| space、ピン留め / Today への所属、favorites、フォルダ、split の項目、archive、ウィンドウごとの表示状態、Air Traffic Control の規則、キーバインド | Rust のコア | Arc のモデルの形（components note 3） |
| どの `WebContents` が、どの `Browser` に存在するか、順序、active タブ | Chrome の `TabStripModel` | Chrome がコミットする。拡張の API は同じ呼び出しの中で結果を読み戻すため、事前にアプリへ問い合わせることはしない（Ardia ledger 1.4） |
| ナビゲーションスタックとセッションストレージ | エンジンのセッションの永続化（4.6） | コアの項目 id をキーとする |
| 履歴、ブックマーク、favicon、閉じたタブ、ズーム、ダウンロード、パスワード、autofill | Chrome のサービス | コアには複製しない |

- 読み込まれていない workspace のタブは `WebContents` を持たない。
- コアの coordinator は id を付けて live タブのコマンドを発行する。エンジンはトランザクション `{epoch, rev, cause, strips}` で応答する。`epoch` はエンジンの起動時に変わる。`rev` は 1 つの epoch の中で単調に増加する。`cause` は、独自のコマンドの id、独自のエンジン呼び出し、Chrome 自身のいずれかである。1 つのトランザクションに複数の cause を混在させない。エコーを抑制する時間窓や、「自分が起こした変更か」を示すフラグは設けない。コマンドは、発行されてから、その id を名指すトランザクションが届くまで飛行中にあり、飛行中のコマンドは新しい epoch の始まりで消去され、飛行中のコマンドを名指さない完了は落とす（我々の規則）。
- Chrome が自ら行う変更（拡張によるタブの移動、クローズ後の後継タブ）は差分を取り、コアの規則によって workspace に適用する。後継タブは、Chrome の選択ではなくコアの規則（split の連続性、折りたたんだタブと読み込まれていないタブのスキップ）に従う。後継は、Arc と同じく、そのウィンドウで表示している space のタブのうち、最も最近に選んだもので、まだ開いていて表示されているものとする（閉じる操作でサイドバーを別の space へ移さない。Arc で計測した）（2026-11-01 に ⌘W と AppleScript で計測した。閉じると選択の履歴をさかのぼり、隣のタブには移らなかった。`docs/research/arc-ardia-observed.ja.md` の 7 節）。該当するタブが無ければ、同じ一覧で閉じたタブより下にある最も近い表示中の開いたタブ、無ければ上、それも無ければ何も選ばない（我々の規則）。split の中のタブの後継はその split とし、split は最後に開いていたタブを閉じると一緒に閉じる。pinned のタブと favorites で ⌘W を押すと、そのタブを読み込んでいない状態にし、行は残し、同じ規則で後継へ移る。選択の履歴はウィンドウごとにローカルに持ち、同期しない。
- トランザクションの strips は、運ぶウィンドウを名指し、coordinator の gone パスはそのウィンドウだけを見る。トランザクションが名指さないウィンドウから消えたタブはそのままにする（我々の規則）。閉じたウィンドウは空の strip として届くので、そのタブは消えたものとして見える。
- strips の active タブは、トランザクションの cause にかかわらずウィンドウごとの選択を更新する。エンジンが確認したコマンドは、Chrome 自身の切り替えと同じように記録される（我々の規則）。Chrome による close でウィンドウの選択が変わったときは、そのウィンドウの strips の active タブは記録せず、規則が選んだ後継を残す（我々の規則）。
- タブの切り替えでは、まずネイティブにページを表示する。表示の経路に UI の状態を経由する往復は含めない。
- Air Traffic Control は規則自身のプロファイルの内側に保つ: 規則は、その routing ファイルの持ち主のプロファイル（呼び出し側が渡す。持ち主を知らないときは、space を名指す行き先はその space のプロファイルを、それ以外の行き先は最初の space のプロファイルを、規則ごとに載せる）に属し、space の行き先はそのプロファイルの space でなければならず、Little window の行き先は workspace が持つプロファイル（組み込みのもの、または帳簿に載っている名前のあるもの）を名指しし、これらを破る編集は断られ、取り込みはその規則を飛ばす。space を消された規則はそれでも当てはまり、まず自分のプロファイルの、最も最近使われた space —— 選択の記録の中で最も新しいタブが順位をつける —— に続き、既定の行き先、既定のプロファイルの最も最近使われた space の順で答え、それも無ければ最も最近の space に送る（我々の規則）。

### 5.2 クラッシュ時の一貫性

- すべての live タブはコアの安定した項目 id を持ち、それをエンジンのタブごとのセッションデータに保存する。これにより、対応関係は再起動後も保たれる。
- 起動時、エンジンは新しい epoch の完全なスナップショットを報告し、coordinator はそれを workspace と照合する。正とするのは workspace である。各項目は、ライフサイクルの状態（開いている、読み込まれていない、閉じた、アーカイブした）を、変更と同じトランザクションで記録する。閉じる操作とアーカイブは、coordinator がエンジンに伝える前に commit する。workspace が開いている、または読み込まれていないと記録していてエンジンが知らないタブは、復元するか、読み込まれていない状態として記録する。項目が閉じた、アーカイブした、または削除した状態のエンジンのタブは、取り込まずに閉じ直す。項目が存在しないエンジンのタブ（クラッシュの前の、commit されていない最後の 1 秒に生成されたもの）は Today に取り込む。epoch の途中で届いた item の無いタブ（⌘ クリック、タブへの `window.open`）も、同じ transaction の中で、スナップショットと同じやり方で取り込む。表示中の space の Today の末尾に空の url の open の行として入る。タブの url はエンジンが所有し、Chrome がナビゲーションを報告するまで core 側は空のままとする。採用は、作った項目とともに live タブを名指すので、エンジンはタブのセッションデータに項目の id を保存できる。エンジンが live として報告した読み込まれていない行は open に変わる。どのタブが存在するかはエンジンが所有するからである（我々の規則）。
- 落とされたトランザクションは rev を消費する。同じ rev の後のトランザクションは、再送ではなくエンジンのバグである（我々の規則）。
- コマンドの完了は発行時の epoch を持ち、現在の epoch でなければ捨てる。
- クラッシュ時に失われうる範囲: workspace の変更は、その SQLite トランザクションがコミットされた時点で永続化され、コミットは、ストレージが動いている間はイベントから最大 1 秒後である（メインスレッド外でバッチ処理する）。書き込みが失敗している間（次の項目）は、再試行が成功するまでこの範囲が広がる。クラッシュで失われうるのは、最大でその直近 1 秒分の workspace の変更である。workspace と送信用の同期ログは同じトランザクションで書き込むため、クラッシュによって両者が不整合になることはない。
- ディスクの容量不足や書き込みの失敗の場合は、メモリ上の状態を保持し、バックオフ付きで再試行し、ユーザーに通知する。データベースを切り詰めることはしない。
- バックアップには SQLite の backup API を用いるため、WAL も含まれる。

### 5.3 プライベートブラウジング

off-the-record のプロファイルは、エンジンの契約における属性であり、すべてのトランザクションとタブがこの属性を持つ。コアは off-the-record の workspace の状態をメモリ上にだけ保持し、それに対する永続的な書き込み、archive のエントリ、同期のレコード、command bar の学習を 1 か所でまとめて拒否する。テストでは、プライベートタブを開いた状態でのクローズ、クラッシュ、archive、同期を対象とする。

## 6. Rust のコア

### 6.1 内容

- workspace のモデル: プロファイル、space、コンテナ（favorites はプロファイルごと、または space ごと、14）、項目（タブ、フォルダ、split）、archive のエントリ、ウィンドウの状態。
- ツリーの表現: 各項目は所属のレジスタ `(parent id, fractional order key, HLC, previous parent id)` を 1 つだけ持つ。子のリストは導出するものであり、別に保存しない。修復は、merge したレジスタの上の決定的なビューである。修復の結果は、同期するレジスタに書き戻さない。そのため、同じ移動を異なる順序で受け取ったデバイスも、同じツリーを計算する。修復したレジスタを書くのはインポートだけである。インポートするファイルがそれらのレジスタの出どころだからである。決定的な修復は次のとおりである。循環を生む移動は、HLC（ハイブリッド論理時計）のタイムスタンプが大きいほうの移動を残し、もう一方の項目を以前の親に付け直して解決する。親が存在しない項目は、その space の Today コンテナに移す。space は移動前の親（レジスタに記録する。新しく作った項目、たとえば新しいフォルダや複製の根は、ここに一覧の根を記録するので、親が並行して削除されても別のプロファイルへ移らない）の祖先のコンテナから決め、決まらなければ先頭の space とする。以前の親に戻しても循環が解けない項目は Today に移す。削除と並行する編集とでは、編集が復元である場合を除き、削除を優先する。ツリーの不変条件のテスト（循環がないこと、すべての項目にちょうど 1 回到達できること）と配送順序のテストは、すべての merge のテストで実行する。
- 項目の編集: 移動はコンテナと位置で指定し、並べ替え、ピン留めとその解除（Today ↔ ピン留め）、任意の深さのフォルダへの出し入れ、お気に入りへの出し入れ、別の space のピン留めや Today への移動を扱う。フォルダは中身ごと動き、自分の中への移動は断る。split は 1 つにまとめて動かし、何も変わらない移動は何も書かない。フォルダはピン留めの中にだけ置き、お気に入りにはタブだけを置く（Arc、`docs/research/arc-ardia-observed.ja.md` の 8 節）。Today への移動とピン留めの解除では最後に選んだ時刻を付けるので、自動アーカイブは移動の時点から数える。タブを選ぶと、そのタブを囲む閉じたフォルダを開く。選んでいるタブは移動の後も選んだままとし、別の space への移動では表示中の space を切り替えない。同じ順序のキーの間に落としたときは、キーを付け直す。プロファイルをまたぐ移動は、プロファイルが入るまで断る（我々の規則）。フォルダは指定した位置に作り、1 つの space の項目を包んで作ることもできる（並びは見た目の順。split の構成タブは繰り上げる）。名前の変更と削除もできる。空のフォルダはすぐに消し、タブの入ったフォルダは中のタブをアーカイブし（Arc、8 節）、残る項目はピン留めの直下に移す。タブの名前も変えられ、独自の名前をページのタイトルの代わりに表示する。空の名前にすると独自の名前を消す。複製（Duplicate）は、タブ、フォルダ、お気に入りを元の項目の直後に写し、id は core で新しく作る。写しは読み込んでいない状態で、URL と名前は元と同じとする。フォルダの写しは中の並びと開閉を保ち、中のアーカイブ済みの項目は写さない。split の構成タブを複製すると split 全体を写す（我々の規則）。写しの最後に選んだ時刻は複製した時刻とするので、古い元の項目に引かれて写しがすぐにアーカイブされることはない。選択、表示中の space、履歴は変えない（我々の規則）。
- 規則: Arc 上で計測したとおりの Air Traffic Control の照合（大文字小文字、スキーム、先頭の `www.` を無視する。「Contains」はクエリとフラグメントも検査する。「Is equal to」はホストとパスだけを比較し、末尾のスラッシュは無視する。最初に一致したものを採用する）、自動 archive の閾値、後継タブの規則、split のレイアウトの計算。
- live-tab coordinator: エンジンのトランザクションを適用し、コマンドを発行し、起動時に照合する（5）。
- インポート: Arc（`StorableSidebar`、`StorableWindows`、`StorableArchiveItems`、`StorableKeyBindings`、`StorableLinkRouting`）、後に Dia、Chrome、Safari、Firefox。インポートは Arc のファイルから workspace とインポートの報告を作り、ストアが 1 回のバッチで書き込む。Chromium のデータ（パスワード、cookie、履歴）は、エンジンを介して Chrome のストアに書き込む。Arc のウィンドウの状態（Ararat の規則。ファイルの形は `docs/research/arc-dia-components.ja.md`）: サイドバーのファイルの隣の `StorableWindows.json` は無くてもよく、無い、読めない、UTF-8 でない、形が壊れている、のどの場合もサイドバーの取り込みは止めない（後の 2 つは報告する）。フォルダの状態とタブの日時は最初のウィンドウから取る。その `expandedItems` は、フォルダを `expanded`（開いている）か `peeked`（閉じたものとして取り込み、数える）で示し、載っていないフォルダは閉じる。その `itemLastActiveDates` は 2001-01-01 からの秒数で、Unix のミリ秒にして保存する。報告は、後のウィンドウと食い違うフォルダ（フォルダごとに 1 回）、peeked のフォルダ、最初のウィンドウの未知の id と形の壊れた項目（項目ごとに 1 回。1 つのウィンドウに 2 回載ったフォルダは後の組を採り、2 件になることがある）、未来の日時、タブでない項目の日時を数える。2 回日時が載ったタブは数えない。Arc のキー割り当て（我々の規則）: `StorableKeyBindings.json` は版を先に読む。`userOverrides` が空なら何も取り込まない。空でない一覧は、形を確かめた例がまだ無いので、報告で数えるだけで取り込まない。Arc の Air Traffic Control の規則（Arc の形は Cra の `Sources/Cra/Model/LinkRouting.swift:8-24` による。ほかは我々の規則）: サイドバーのファイルの隣の `StorableLinkRouting.json` は版を先に読む。`contains` は Contains、`matches` は Is equal to にする。行き先が `space` で `mostRecent` のものは最近の space、知っている space の id のものはその space にする。`littleArc` は、routing ファイルの持ち主のプロファイル（呼び出し側が渡す。知らないときは最初の space のもの）の Little window にする。プロファイルの行き先、知らない照合の種類や行き先や space の id（持ち主のプロファイルに属さない id は知らないものと同じに数える。持ち主を知らないときは、生きている space の id ならどのプロファイルでも残し、規則にはその space のプロファイル——most-recent と Little window は最初の space のもの——を載せる）、形の壊れた項目、重なった id（最初のものを残す）は、飛ばして数える。ファイルが無いときは無いと報告し、形の確認に通らないファイルは断って報告する。どちらの場合もサイドバーの取り込みは止めない。規則はファイルの順に入れ、空や空白だけの条件は何にも当てはまらない（Cra の `LinkRouting.swift:37`）。
- エンジンが供給するソース（Chromium の `AutocompleteController` の結果、開いているタブ、workspace の項目、コマンド）に対する command bar の順位付け。エンジンの無い今の形（Cra の点数。file:line は各 unit の報告にある）: 開くたびに、workspace を修復した写しから索引を 1 つ作り、閉じると捨てる。候補は、開いているタブと読み込んでいないタブ（今のタブは除き、お気に入りには印を付ける）、アーカイブ（400 件まで、点数は 0.85 倍）、コマンド（割り当てたキーを添える）、表示中以外の space への Switch to、フォルダへの Go to、Move Tab to である。Move Tab to は、同じプロファイルの別の space（その Today の末尾）か、タブが今入っているもの以外の同じプロファイルのフォルダ（そのフォルダの末尾）へ移す。URL で重複を除き、安定に並べる。空の問い合わせは最近のタブを並べる。スキーム、`localhost`、`about:`、`file:`、IPv4 のアドレス、host.tld[:port][/path] のどれかで空白を含まない問い合わせは URL として開く（localhost と IP は http、ほかは https）。それ以外は `https://www.google.com/search?q=` で検索する（エンジンの検索エンジンが入るまでの定数）。打った文字そのものも 1 行とし、URL として開くとき、またはほかに候補が無いときは先頭に、それ以外は最もよい候補の次に置く。表示は 5 行までとし、コマンド、space、フォルダは 2 文字から当てはめる。入力中の補完は、点数が 90 以上の候補のうち、小文字にした問い合わせが前方一致するホストとし、問い合わせに `www.` が無ければ `www.` を除く。2 文字未満、空白を含む、パスを含む問い合わせと、最初のキーの前には出さない。Chromium の結果は、ソースの 1 つとして加わる。`create_tab` は表示中の space の Today の先頭にタブを作って選び、`set_tab_url` は開いているタブか読み込んでいないタブの URL を変え、それ以外は断る。
- 同期クライアント（8）。

### 6.2 ストレージ

workspace、archive、同期のジャーナルには SQLite（WAL）を用いる。書き込みはメインスレッド外で実行する。Cra の JSON ファイルは、書き込みをメインスレッド外に移す前、2,000 項目の archive の書き込み 1 回あたりメインスレッドで約 30 ms を要した（Cra ledger 16）。SQLite は 5.2 が必要とするトランザクションを提供する。

各レコード（space、item、favorites のコンテナ、キー割り当ての変更、プロファイルのアーカイブの閾値、Air Traffic Control の規則と既定の行き先）は 1 行 `(kind, id, JSON の本体)` として保存する。space も item と同じく fractional order key を持ち、一覧は保存しない。各変更は同じトランザクションでジャーナルの表にも追記する。ただし次の 3 種類は端末の中だけに置き、ジャーナルにも同期にも載せない: `Window`（ウィンドウの位置と大きさ、サイドバーの状態）、`LastSelected`（各タブを最後に選んだ時刻。自動アーカイブが読む）、`FolderState`（閉じているフォルダ。ある Mac で閉じても別の Mac では閉じない）。Arc のインポートは、そのバッチの中で `FolderState` と、タブに限って `LastSelected` を作る。この版が知らない kind の行は変更せずに残す（8.3）。writer スレッドは、バッチの最初の変更から 1 秒以内に `synchronous = FULL` で commit する。

### 6.3 バインディング

- `ararat-ffi` は、UniFFI（macOS と iPhone の Swift 向け）と C ABI（Windows と Linux 向けの、Chromium のツリー内の C++ 向け）を介してコアを公開する。
- コアは同期的であり、ストレージの書き込み用スレッドと同期のワーカー以外のスレッドを所有しない。Swift のアダプターは 1 つの serial queue からコアを呼び出し、スナップショットを UI に公開する。
- 秘密情報は、コアがゼロで消去するバイトバッファとして境界を越える。秘密情報を Swift の `String` に変換することはしない。

## 7. macOS の UI

- サイドバー、space のページング、favorites のグリッド、リストの行、dock、command bar、Little window、ウィンドウの chrome、ツールチップには AppKit を用いる。行は layer を基盤とするビューであり、キーごとに再利用する。space のページングでは layer だけを移動する（Cra ledger 12、4）。行の一覧のスクロール（Arc では計測していない。Cra と Yab の最近の修正をもとにした我々の規則、`analysis/peers/2026-11-02-recent-updates.md` の 2.2）: スクロールするのは行の一覧だけで、お気に入りとヘッダーは固定し、ピン留めの行は Today と一緒にスクロールする。1 pt の細い線（Cra による Arc の計測: ライトは黒 5 %、ダークは白 7 %）を、先頭から離れてスクロールしている間は上に、下に隠れた行がある間は下に出し、0.25 s かけて現し消す。クリック、キーボード、標準入力で行を選んだとき、行を戻したとき、dock から space を切り替えたとき、space を作ったときは、選んだ行の全体が見える最小のスクロールで表示し、中央には寄せない。0.22 s の ease-out cubic で動かす。すでに見えている行では一覧を動かさず、裏での変化では表示しない。行の挿入と削除では、最初に見えている行の位置を保つ（先頭にいるときは保たない）。overlay のスクロールバーは、ジェスチャーが縦と分かるまで出さないため、横の space のスワイプでつまみが光らない。スクロールバーはシステムのものを使う。スワイプまたはホイールで space に着地したときは、横の動きが落ち着く前に、選んだ行をすぐに表示する。スワイプや space の切り替えは、それより前の表示の動きを止める（Yab の修正をもとにした我々の規則）。space ごとに一覧のスクロール位置を持つので、スワイプ中と着地後でページに同じ行が見える。視差効果を減らす設定（Reduce Motion）では、表示と線の動きを省く。行の操作（記載のないものは我々の規則。他のブラウザの出典は `analysis/peers/2026-11-02-recent-updates.md` の 2.1 と 2.10）: Today の行または split に中クリックすると、⌘W と同じ動きで閉じる。ピン留めのタブでは下記のピンの操作を行い、ピン留めの split、フォルダ、お気に入りでは何もしない。タブの行に重ねると、4 pt 内側に 28 pt のボタンを出す（フォルダと split の行には出さない）。選択中のピンでは − がタブを unload してピンを残し（MRU の次のタブを表示し、⌘W を続けると unload 済みのピンは飛ばす）、ほかのピンでは ✕ がアーカイブし、Today のタブでは ✕ が ⌘W と同じく閉じる。いずれもアクセシビリティの操作としても提供する。タイトルは重ねても枠を変えず、ボタンと重なる部分だけを 12 pt かけて薄くする。止まったポインタの下で行が動いたとき（閉じる、挿入、スクロール、表示、space への着地）は、hover と押下の状態を計算し直す。行は押した時点で選ぶ（Arc、`docs/research/arc-ardia-observed.ja.md` の 8 節）。ただし − と ✕ のボタンの上と、中クリックでは選ばない。行とサイドバーのボタンのツールチップは Cra の値を用いる（Arc では計測していない）: ポインタが止まってから 1.6 s で出し、表示中に別の部品へ移ると即座に切り替え、出すときはフェードせず、消すときは 2 フレームでフェードし、クリックで消して待ち時間を最初からにする。12 pt medium の文字の 28 pt のカプセルを、カーソルから (13, 14) ずらして出す。行のドラッグ（断りの無いものは 8 節の Arc の動き）: 3 pt 動かすとドラッグを始める（我々の値。AppKit は閾値を公開していない）。元の行は塗りを付けたまま残り、行の写しがポインタに付いて動き、他の行は動かない。落とす位置は、入れ先の下げるところから始まる 2 pt の線で、根元では 16 pt、一段下がるごとに 16 pt 深くなり、サイドバーの幅 − 12 までの線に、左端に直径およそ 7 pt の中空の輪を付け、行の境目に置く。色はラベルの色の 95 % とする（我々の値）。フォルダの行の上では線を出さず、落とすと中に入れてフォルダを開く（開くのは同じ一括処理の中の端末の状態の変更で、ジャーナルには移動だけを書く）。フォルダの行の上下 2.5 pt は、その前後に置く（我々の値）。一つ以上の開いたフォルダが途切れる境目——その上の行がそれぞれの最後に見える子であるところ——では、ポインタの x が深さを選ぶ。上の行の下半分、Today の区切りの前の隙間、最後の行のあとは、途切れるそれぞれのフォルダと、ピン留めが終わるところ（次の行が Today の最初の行、または行が無い）ではピン留めの根元が候補になり、内容の始まりがポインタの x より左にある最も深い候補を使う。内容はサイドバーの左端から 16 + 16·depth pt 始まり、外の段はその段のフォルダの直後（並び順 + 1）に入る。フォルダの最後の子の下側でも、Today の区切りの隙間でも、フォルダに入る代わりにピン留めの末尾へ落とせる。閉じたフォルダは深さを選ばない（我々の規則。Arc は計測していない）。閉じたフォルダの上に 0.6 秒止まると開く（Arc を計測するまでの我々の値）。お気に入りの上では、落とす場所に空のタイルを出してグリッドを並べ直す。お気に入りに入れられるのはタブだけで、フォルダはお気に入りにも Today にも落とせず、断ったドロップは元に戻る。space の dock のセルに落とすと、Today から来た項目はその space の Today に、それ以外（お気に入りを含む）はピン留めに移し、space は切り替えない。別のプロファイルのセルには落とせない（我々の規則）。空の Today への落とし先は、最後のピン留めの行の 20 pt 下から数える（我々の値）。ドラッグ中も一覧は縦にスクロールでき、端から 24 pt 以内では 240 pt/s で自動でスクロールする（我々の値）。離した後、写しは 100 ms のイーズアウトで収まる。Esc で取り消し、視差効果を減らす設定（Reduce Motion）では収まる動きを省く。ドラッグの状態はイベントの出どころに依存しないので、ポインタがウィンドウの外に出たら、システムのドラッグに引き継げる（タブをウィンドウの外へ出す操作はエンジンと一緒に入れる）。フォルダと行のメニュー（断りの無いものは 8 節の Arc の動き）: フォルダの行をクリックすると、離した時点で開閉する。ドラッグで開閉しないためである（Arc は押した時点で開閉する）。アイコンは開いたフォルダと閉じたフォルダを描き分け、VoiceOver には Expand と Collapse の操作を出す。New Folder は + のメニューとサイドバーの空いた所のメニューに置き、ピン留めの末尾に「Untitled」を加えて、タイトルを名前の変更の状態にする。New Nested Folder は、閉じた親を開いてから、その末尾に名前の変更の状態で加える（我々の規則）。タブとフォルダの名前は、その場で変えられる。メニューの Rename… か、ピン留めのタブのダブルクリックで始める。同じ space の中でタブを Today からピン留めにした直後（ピン留めかその中のフォルダへのドラッグ、または Pin Tab ⌘D）だけ、その選ばれた行のタイトルの下に「Double-click to rename」を 3 s 出し、0.2 s で消す（Arc はこのときだけ出す。`docs/research/arc-ardia-observed.ja.md` の 8 節。3 s はオーナーの選択、2026-11-04。消え方は我々の値で、視差効果を減らす設定では消え方を付けない）。タイトルは 13 pt の 1 行にして上に寄せ、その下に 10 pt の副次の色で出す。別の行を選んだとき、名前の変更を始めたとき、space を変えたときは消し、前からあるピン留めでは出さない。入力欄は 14 pt の文字とし、行では 22 pt の行に、お気に入りではタイルの幅に置き、Arc と同じくフォーカスリング、枠、背景を付けない（大きさは我々の値）。Return かフォーカスが外れると確定し、Esc で取り消す。名前を変えずに確定したときは何も書かない。タブで空にすると独自の名前を消し、フォルダでは空の名前を断る。名前の変更の間は、その行のタイトルを隠して入力欄がその場所を取り、名前の変更を始めると開いていたツールチップを閉じて、入力欄がある間その行の上ではツールチップを出さない（Arc、2026-11-05、`docs/research/arc-ardia-observed.ja.md` の 8 節）。確定でも取り消しでも、二つとも戻る（我々の規則）。行のメニューには、できる項目だけを Arc の順に置き、ほかは省く。Today のタブは Copy Link、Rename…、Duplicate、Move to › space の一覧、Archive Tab とする。ピン留めのタブは Copy Link、Rename…、Duplicate、Move to ›、Remove Pin とし、Remove Pin は Today の先頭に移す（我々の規則）。お気に入りは Copy Link、Rename…、Close Tab ⌘W、Remove Favorite とする。Close Tab は unload してタイルを残し、Remove Favorite はアーカイブする（Arc は閉じる。アーカイブするのは我々の規則）。フォルダは New Nested Folder…、Rename…、Duplicate、Move to ›、Delete とする。Move to › には同じプロファイルのほかの space を並べ、項目を元の場所に合わせて、その space のピン留めか Today の末尾に移す。space は切り替えない。どの深さにもタブの無いフォルダはすぐに消し、タブの入ったフォルダは、先に Arc と同じシート（「Delete your “<名前>” folder?」、「Deleting this folder will archive the tabs inside it.」、Cancel Esc、赤い Delete Folder ↩）で確かめる。Duplicate はお気に入りのメニューには置かない（Arc の一覧）。command bar（大きさは Cra による Arc の計測、ほかは我々の規則）: ⌘T で新しいタブ用に開き（「Search or enter URL…」）、⌘L で選んでいるタブ用に（「Edit URL or search…」）、その URL を入れて全体を選んだ状態で開く。タブが無ければ新しいタブ用になる。どちらもキー割り当ての表のコマンドである。パネルは幅 766 pt（ウィンドウの幅 − 80 まで）で、高さ 60 pt の入力欄の下に、高さ 50 pt の行を 5 行まで垂らす。角丸は 14 で、現すときも消すときも 1 フレームで切り替える。↑ と ↓ は端で折り返し、その行の文字を入力欄に示す。Return で選んだ行を確定し、Open URL か Search の行では、⌘Return で ⌘L から開いたときも新しいタブに開く。Esc で閉じ、Tab、→、⌘→ で灰色の補完を受け入れ、⌫ で補完を消す。IME の変換中は Return、↑、↓ を IME に渡す。外を押すとすぐに閉じる。ただし開いてから 0.6 秒以内にキーウィンドウでなくなったときは、パネルがキーを取り戻す（Cra の猶予）。入力欄はすぐにキーを受け、索引ができる前に打った文字と Return は、索引ができた時点で再生する。space の dock（記載のないものは Cra による Arc の計測、Arc 1.171）: セルはスクロールさせない。セルどうしは隙間なく接し、Library のボタンと + の間で中央に寄せる。各セルの幅は最大 34 pt、開いている space のセルは最小 22 pt とし、ほかのセルは残りを 0.5 pt 単位で分け合う（Cra をもとにした我々の規則。Cra の追加の下限は採らない）。押してもウィンドウは動かず、セルの中で揺れたクリックでも切り替え、セルの外で離したときは取り消す（我々の規則）。最後の dock のクリックは、落ち着く途中のスワイプやホイールの動きに優先し、Library と space の作成を閉じる。アイコンの無い space は頭文字を表示する。狭いセルで Arc が描く点は、space のアイコンが入るまで待つ。浮いたサイドバーを保つ条件（Cra PR #19 と Ardia 0.2.40 をもとにした我々の規則）: サイドバーのメニューを操作している間はツールチップを出さず、メニューが閉じたら待ち時間を最初からにする。サイドバーのいずれかのメニューを操作している間と、マウスのいずれかのボタンを押している間は隠さない。メニューが閉じたとき、またはボタンを離したときに、その時点のポインタの位置から隠す規則を 1 回適用する。アプリが非アクティブになったときと、キーウィンドウでなくなったときは、従来どおり隠す。浮いている間は、ページのカードからパネルの占める範囲を除き、パネルと同じスプリングと曲線で動かすので、角の丸みからページが見えない。信号のボタンはサイドバーに属する（オーナーの選択、2026-11-03、Arc に合わせる。Cra と Ardia 0.2.29 も同じ）: サイドバーのパネルが持つ 1 組の標準のボタンを、Arc で計測した中心（x 19.5、42.5、65.5、y 23.5）に置き、パネルと一緒に動かすので、浮いているときはパネルの 5 pt の余白が加わる（我々の値。Arc のこの位置は誰も計測していない）。ウィンドウ自身のボタンはフルスクリーンのときだけ出し、AppKit の動作に任せる。隠しているときは表示せず、ウィンドウの角にも押せる範囲を残さない。⌘M などのウィンドウの操作は効く。このボタンは、サイドバーが現れるときは 100 ms、隠れるときは 90 ms の ease-out で現れ、消える。サイドバーの上端の行には、信号のボタンの右に、戻る、進む、… のボタンの場所を空けておく（中心は幅 − 76、− 48、− 20、y 23.5、押せる範囲は 24 pt）。これらはエンジンと一緒に加える。キーの割り当てのある部品のツールチップには、タイトルの後に、キーごとに 1 つのキーの形を、メニューの項目から読んで出す（Arc の見た目をもとにした我々の値: 最小 18 × 18 pt、11 pt medium、半径 4、間隔 3 pt、修飾キーは ⌃⌥⇧⌘ の順。タイトルとの間はおよそ 12 pt で、Arc では計測していない）。修飾キーを押している間は、そのキーの形を押し込んだ見た目（濃い塗り、1 pt 下げる）にする。
- 設定とオンボーディングには、`NSHostingView` 内の SwiftUI を用いる。
- 動きとサイズの値は、オーナーの機器で計測した Arc の値とする（`docs/research/arc-ardia-observed.ja.md` の 4〜6 節）。フローティングサイドバーは、response およそ 0.15 s、damping およそ 0.84 の spring で現れ（5 pt の inset）、およそ 90 ms の ease-out で隠れる（components note 5 は 0.185 s と 0.77 とするが、その値は計測への当てはまりが悪い）。ドックしたサイドバー（⌘S）は、およそ 90 ms の ease-out cubic で隠れ、およそ 100 ms の ease-out cubic で現れる。Arc はキーのおよそ 560 ms 後に表示を始めるが、この遅れは計測しただけで理由が分かっておらず、写さない。タブを閉じると、下の行がおよそ 120 ms の ease-out cubic で上へ動く。末尾の行を閉じると、その行はおよそ 110 ms で消える。タブを開くと、Today の先頭に入り、下の行が下へ動く。この動きは閉じるときと同じ速さで始まる（動きの終わりは追跡できなかったため、閉じるときの曲線を使う）。公開されている Dia の値（components note 5）と一致する点は研究の文書に記した。Dia の値だけを根拠にした値は使わない。
- サイドバーのレイアウトは、計測した Arc の寸法を使う（`docs/research/arc-sidebar-layout.ja.md`）。URL 欄は高さ 36 pt で inset 8 pt、favorites のタイルは高さ 47 pt で間隔 8 pt、行は 41 pt 間隔で選択中の背景は 36 pt、favicon は 16 pt で x 18、タイトルは x 44、入れ子の字下げは 16 pt とする。入れ子の行の選択中とホバー時の背景は、1 段ごとに左端を同じ 16 pt だけ右へずらし、右端は変えない。サイドバーは、Arc と同じく 2 つの形を持つ。ページのカードの横にドックした形と、隠しているときにページの上に重なる形（後述のフローティングサイドバー）である。フローティングの形は、ドックしたときと同じ幅のパネルを、ウィンドウの左端、上端、下端から 5 pt 内側に置き、1 pt の明るい縁と continuous の半径 11 の角を付ける。ページのカードは、ウィンドウの上端・右端・下端から 10 pt 内側に置き、サイドバーを隠している間は左端からも 10 pt 内側に置く（Arc で計測した）。幅はウィンドウごとに縁のドラッグで変え、ドラッグ中はポインタに追従させる（Arc では計測していない）。「幅を既定に戻す」コマンドで既定の 240 pt に戻す（オーナーの選択、2026-10-31）。Arc と同じく、ページのカードの左端はウィンドウの幅によらず 164〜500 pt にとどまり、ポインタをウィンドウの左端から 81 pt より左（下限のおよそ半分。Arc は 81 で保ち、80 で隠した）へドラッグするとサイドバーを隠し、再び表示すると下限の幅に戻る（Arc で計測した。`docs/research/arc-sidebar-layout.ja.md`）。角は continuous で、欄・タイル・行の背景の半径は 11 とする。入れ子の形は、Apple のデザインの指針のとおり同心の半径（容器の半径から余白を引いた値）とする。
- サイドバーの上のスクロールによる space の切り替えは、計測した Arc の振る舞いとする（`docs/research/arc-ardia-observed.ja.md` の 5 節。オーナーの選択、2026-10-31）。イベントはフェーズで分ける。スクロールのフェーズか慣性のフェーズを持つイベントはトラックパッドのジェスチャーに属し、どちらも持たないイベント（`phase == []` かつ `momentumPhase == []`）はホイールの入力とする。トラックパッド: `began` から、サイドバーはジェスチャーに `scrollingDeltaX × 0.5` で追従し、隣の space は 1 ページ離れて並ぶ。1 ページはサイドバーの幅とする（Arc では、幅およそ 178 pt のサイドバーでおよそ 180 pt と計測した。他の幅では計測していないため、ページを幅に結び付けるのは推定である）。各ページの中身はサイドバーの内側の領域で切り取るため、隣どうしの中身はサイドバーの左右の余白の分、16 pt 離れる。`ended` では、直前 100 ms の速度で決める。動きがあれば、その向きで最も近いページの境目を選ぶ（そのため、今の space の方へ向きを戻したフリックは今の space に戻る。Arc は同じ向きのフリックだけを計測した）。動きが無ければ近い方のページを選ぶ（半ページを超えていれば切り替える）。そのジェスチャーの慣性のイベントは無視する。選んだページへの静止は、response およそ 0.25 s、damping およそ 0.88 の spring とする。切り替えずに戻るときは、およそ 0.19 s、0.98 とする。最後の space より先では、追従した変位 `x` に対して `255·(1 − 1/(0.15·x/255 + 1))` だけ動き、そこで閾値を超えて離すと space の作成を開く。最初の space の手前には Library の画面がある。Library は開いている間サイドバーを置き換え、幅を 70 pt 広げる（Arc は 347 から 417 pt）。そのため、ドラッグの上限の 500 pt を超えることがある。下のバーの Library のボタン、最初の space より手前でトラックパッドを離すこと、またはそこへのホイールの切り替えで開き、同じボタン、Escape、スクロールで戻ると閉じる。最後に開いたページを覚える。今は Archive のページだけを持ち、Arc と同じ配置にする（計測した）。入力に合わせてタイトルと URL で絞る検索欄、閉じた時刻による日の見出し、タイトルの下に URL を置いた 56 pt 間隔の行、ホバーした行の削除と元に戻すのボタンを置く。戻したタブは、元のフォルダがまだあるときは、そのフォルダの元の隣どうしの間に戻し（畳まれた祖先は同じ core のトランザクションで開く）、無いときはその space の Today の先頭で開き直す。そのため、ピン留めの直下からアーカイブしたタブと、フォルダが削除されたタブは、当面 Today に戻る。戻る矢印で Library を閉じる。タブを戻すと、そのタブを選び、元の space を表示して Library を閉じる。⇧⌘L（View メニュー）で、最後に開いたページの Library を開閉する。Escape と戻る矢印で閉じ、ほかの場所のクリックでは閉じない。検索欄は、ボタンまたはスワイプやホイールで Library に着地した後にだけフォーカスを受け取り、動きの途中やスプリングで戻ったときには受け取らない。サイドバーが隠れていて浮いてもいないときに開くと、閉じるまでサイドバーをドックした形で出し、閉じたら再び隠す。浮いたパネルから開くと、そのパネルの中に出す。開いている間に ⌘S を押したときは、⌘S に従う。Library を開いている間は、浮いたサイドバーのポインタによる隠しを止める。アプリが非アクティブになったときと、キーウィンドウでなくなったときは隠す。アーカイブや検索の結果が空のときは、中央に 1 行の文を出す（我々の文言:「No archived tabs」「No matching tabs」）。space の作成（Arc の「Create a Space」、計測した）: 下のバーの + のメニューに New Space と New Folder を置き（Arc のほかの項目は、まだ無い機能が要るため、無効の表示もせずに省く）、最後の space より先でトラックパッドを離しても開く。最後の space より先へ引くと、Arc の印を出す（計測した。`docs/research/arc-sidebar-layout.ja.md`）。直径 30 pt のアクセント色の円に白い + を置き、サイドバーの右端の下から入って、端から 12 pt 内側で止め（追従した変位 1 pt につき 0.4 pt 入るため、105 で止まる）、縦はサイドバーの中央（どちらの形でもウィンドウの中央）に置く。円の周りの白い輪は、追従した変位が 75 から 162 までの間に、12 時の位置から反時計回りに伸びる。閾値の 165 で、円は白になり、+ はアクセント色になる。閾値を超えて離すと、すぐに space の作成を表示し、円は約 70 ms で右へ抜ける（視差効果を減らす設定では抜ける動きを省く）。手前で離すと元に戻る。ドック時の幅のサイドバーを埋め、ページのカードは空にする。見出しと我々の説明文「Keep related tabs together.」、高さ 36 pt の名前の欄（枠とフォーカスリングを付けず、Profile のカードと同じ塗りと角丸のカードに置き、文字を 10 pt 内側に置く。カードのどこを押しても欄にフォーカスが移る。見た目は Arc、大きさは我々の値）、高さ 59 pt の読み取り専用の Profile のカードを、両側 14 pt、間隔 6 pt で置き、下端に、名前が空の間は無効の Create Space のボタンと Cancel を置く。Return で作成して新しい space を表示し、Escape か Cancel で戻る。Arc のイラスト、テーマの選択、名前のアイコンは、テーマとアイコンができるまで省く。Library の開閉の動きは Arc で計測していない。スクロールでは space の切り替えの spring を、ボタンでは ⌘S の曲線を使う（我々の選択）。ホイール: `isDirectionInvertedFromDevice` が立っているときに符号を反転した `scrollingDeltaX` を 49 ms の間合計し、1 を超えたら 1 つの space を切り替え、その切り替えから 250 ms のあいだホイールの入力を無視する。この休止は延長しない（計測した範囲は 40〜50 ms と 230〜260 ms であり、その範囲に入る Dia の値を使う）。ホイールでの切り替えは、トラックパッドでの切り替えと同じく隣の space を見せながら、同じ spring で隣へ滑らせる。続く切り替えは、その時点の変位から続ける（オーナーが Arc で見た振る舞い、2026-11-01。その曲線は計測していない）。ホイールで滑らせている途中に始まったトラックパッドのジェスチャーは、その時点の変位から引き継ぐ。最初の space より手前へのホイールの切り替えは、ほかのページと同じく Library を開く（オーナーの選択、2026-11-02。マウスでも行けるようにするため。Arc のホイールでの挙動は計測していない）。最後の space より先へのホイールの切り替えは、引き切る動きを再生する。ページを印とともに閾値まで切り替えの spring で伸ばし、そこで離したときと同じく space の作成を開く（オーナーの選択、2026-11-02。マウスでも space を作れるようにするため。Arc はホイールでは作らない）。Library では、左の列の上での横の入力（トラックパッドかホイール）で最初の space へ戻り、archive の一覧の上での入力は一覧を縦にスクロールするだけで space を切り替えない（オーナーが Arc で見た振る舞い、2026-11-02）。space の作成の画面からは、space の方へのホイールの切り替えで、最後の space へ切り替えの spring で戻る（オーナーの選択）。space を切り替えるのは横の入力だけとする。`|scrollingDeltaX| > |scrollingDeltaY|` のイベントを横とし、トラックパッドではジェスチャーの最初の 0 でないイベントでジェスチャー全体を決め、ホイールではイベントごとに決める。それ以外の入力は行の一覧をスクロールする（我々の規則。Arc の規則は計測していない）。どちらでも、値が負なら次の space へ進む。トラックパッドのイベントは符号をそのまま使う。そのため、ナチュラルなスクロールのもとでは、Arc と同じく、同じ向きの手の動きでもトラックボールとトラックパッドで逆に動く。未計測: Arc のページと半ページの閾値がサイドバーの幅に比例するか。
- フローティングサイドバーは、計測した Arc の挙動に従う（`docs/research/arc-ardia-observed.ja.md`。オーナーの選択、2026-10-31）。サイドバーは、ポインタが、ウィンドウの高さの範囲で、ウィンドウの左端から 5 pt 以内またはウィンドウの左外側（後述の 250 pt の限界まで）におよそ 150 ms とどまった後に現れ、動き始めてからおよそ 110 ms で全幅に達し、およそ 1% 行き過ぎる（上記の動きの値のフローティングサイドバーの spring）。ポインタがウィンドウの左外側にある間は、ウィンドウの左端からおよそ 250 pt までは表示を維持する。この限界はウィンドウの幅で変わらなかった。サイドバーは、ポインタがウィンドウからおよそ 250 pt より左へ離れたとき、ウィンドウ内でもウィンドウの右端より右でもサイドバーの端からおよそ 72 pt より右へ移動したとき、またはウィンドウの上へ出たときに、およそ 90 ms で減速しながら隠れる。ウィンドウ内では tracking area を用いる。ウィンドウの外では tracking area は何も報告しないため、アプリがアクティブな間はウィンドウの外でもポインタを追う。サイドバーが隠れている間は、ローカルとグローバルの mouse-moved の `NSEvent` の監視（Yab の `LightsRow` と同じ）で左端の領域ととどまる時間のタイマーを動かし、ポインタが領域を出たらタイマーを取り消す。サイドバーの表示中は、ポインタの位置（`NSEvent.mouseLocation`）をディスプレイのリフレッシュレートでサンプリングする。対象はキーウィンドウのサイドバーだけである。Arc と同じく、アプリが非アクティブになったときにサイドバーを隠し、どちらの追跡も止める。Arc と同じく、タブを 1 つも選んでいない間は、サイドバーを表示したままとし、隠す規則はどれも適用しない。⌘S はドックした形と隠した形を切り替え、隠した形ではフローティングのパネルを表示する（オーナーの選択、2026-10-31。計測の途中に Arc で見たもので、Ardia、Cra、Yab では確かめていない）。Yab の異なる値は `docs/research/yab-observed.ja.md` にある。
- テーマ: Arc の `blendedGradient`（2 つの基調色、オーバーレイの色、ノイズと強度、類似色または補色の色相環、ライトまたはダークの半透明）を、`NSVisualEffectView` とグラデーションの layer に対応付ける。非公開 API の `CABackdropLayer` は、計測した差がその使用を正当化しない限り使用しない（Cra ledger 34）。
- 設定ウィンドウ: unified toolbar を持つ `NSSplitViewController` とし、各ペインは SwiftUI で実装する。1 つのウィンドウにすべての space の設定を置き（Yab の Spaces のペインと同じ）、space から設定を開いたときは、そのウィンドウでその space の設定を開く（オーナーの選択、2026-10-31）。ウィンドウは Yab の形とし、Yab で計測した寸法と色を用いる（`docs/research/yab-observed.ja.md` の 2 節。オーナーの選択、2026-11-02）: 760 × 540 pt、幅 180 pt のペインの一覧（両端の丸い検索欄、28 pt 間隔の 26 pt の行）、戻る・進むを 1 つのカプセルにした高さ 52 pt のツールバー、半径 12・間隔 10 pt のカード、スクロールするとツールバーのタイトルに変わるページの見出し（56 pt のアイコン、タイトル、1 行の説明）。灰色は中立とし、space の色に寄せない（我々の規則）。一覧には、作ったペインだけを Tabs、Shortcuts、Air Traffic Control、Spaces の順に出す。検索では、ペインの一覧を、ペインごとにまとめた結果に置き換える。結果を押すと、そのペインを開いて目的の行までスクロールし、その行を選択の灰色で塗る。Spaces のペインには、サイドバーと同じ順に space を並べる（44 pt の行: 並べ替えのつまみ、アイコン、名前、タブの数、⌃N、›。ドラッグで並べ替える）。行を押すとその space のページを積み、そのページでは、矢印、点、スワイプ、ホイールで前後の space のページへ、サイドバーの切り替えと同じスプリングで横に移る（オーナーの選択、2026-11-03）。space のページには、Name、Icon、Look、Profile（プロファイルが入るまでは表示のみ）、Delete Space を置く。Look は Yab のポップオーバーを開く: space ごとの自動・ライト・ダーク、横に色相・縦に明るさを並べた面と、− と + で 1〜3 個に増減する色のつまみ、面の背景はダークの外観では #2A2A2A、ライトではコントロールの背景の色（Arc の Edit Theme Color、2026-11-05、`docs/research/arc-ardia-observed.ja.md` の 8 節。ライトは計測していない）、1 ページ 9 色のプリセット、端に Glass（macOS の Liquid Glass）を置いた % 表示の Transparency のスライダー、Grain のスライダー、… のメニューの Use for All Spaces。Arc から取り込んだ Look をそのまま編集できるよう、値は Arc の形で保存する: 1〜3 色、色の層の不透明度（Cra と Ardia による Arc の計測では、Arc の intensity i は α ≈ 0.19 + 0.55·i の不透明度になる。画面では透明度 = 1 − α として示す）、粒、Glass、明暗のモード。Drawings、Take the site's color、Shift with tabs は後に回す（後の 2 つはページが要る）。Look の無い space は、サイドバーの通常の vibrancy のままとする。space を削除すると、開いているタブと unload したタブ（ピン留めと Today）を、親を保ったままアーカイブし、表示中の space なら隣の space を表示する。最後の 1 つの space は削除できない。Arc の取り込みでは、`customInfo.windowTheme` の基本の色（最大 3 色）を読み、intensity を上の式で不透明度に、noise を粒に、ウィンドウの appearance を明暗のモードに対応づける（無いときは自動）。当面は space ごとに Look を 1 つだけ持つので、Arc の自動の space が別に持つダークの色は取り込まない。`isVibrant` と `contentOverBackgroundAppearance` は読まず、sRGB の範囲外の色は範囲内に収める。混ぜた単色（`blendedSingleColor`）は同じ対応で 1 色として、基本の色（`basicColor`）は粒の無い不透明な 1 色として取り込み、ほかの背景の形では Look を付けない。core にはまだ取り消しが無いため、Look の変更は取り消せない。Look の描き方（我々の規則。Arc がつまみをグラデーションにどう対応づけるかは分かっていない）: 色の層を、保存した不透明度で vibrancy の上に重ねる。1 色なら単色、2〜3 色なら 0、0.5、1 に色を置いた縦のグラデーションとする。粒は生成したノイズのタイルで、不透明度は最大 10 % とする。Glass は macOS 26 以降で `NSGlassEffectView` を使い（ドックしているときはサイドバーの後ろのウィンドウを写すので、浮いているときより平板に見える）、それ以外では vibrancy に戻す。明暗のモードはサイドバーに当て、自動のときは、重ねた背景の輝度で行の文字を明るくするか暗くするかを決める（閾値 0.179、黒と白でコントラストが等しくなる値）。スワイプやホイールで動かしている間は、色と粒をページの位置に比例して混ぜ、Glass と明暗は半ページで切り替える。透明度を下げる設定（Reduce Transparency）では、AppKit の不透明な代わりの背景の上に色の層を描き、Glass は使わない。設定ウィンドウの細部（断りの無いものは我々の規則）: ⌘, とアプリのメニューの Settings… は、表示中の space のページでウィンドウを開き、開いていれば前面に出す。最初に開くときは画面の中央に置き、ブラウザのウィンドウを閉じるとアプリが終了して一緒に閉じる。⌃1〜⌃9 は View › Show Space 1…9 とし（Arc と Yab が割り当てている）、Spaces のペインの行の ⌃N はこれを表示する。space のタブの数は Today のタブの数とし、split は 1 つと数える（お気に入りはプロファイルに属する）。ページの見出しは「N tabs · プロファイル」（1 つのときは「1 tab」）とし、100 pt のスクロールでツールバーのタイトルに変わる。ペインの一覧との間には細い標準の区切り線を引く（Yab には無い）。ダークでは中立の灰色を使い、文字は 35 と 235 とする。Delete Space は「This cannot be undone」で確認する。Tabs のペインではサイドバーの幅を 240 pt に戻すこともでき、⌘W で設定ウィンドウを閉じる。Shortcuts のペインは、すべてのコマンドを、そのキーと、説明としてメニューの項目のツールチップとともに並べ、割り当てを変えられる（印の無いものは我々の規則）。行のキーの表示をクリックすると、次に押したキーの組み合わせを記録する。Esc で取り消し、⌫ か ⌦ で消す。記録中は ⌘W、⌘,、⌘Q を実行せずに記録する。ほかの所を押すと取り消す。断られたキーは core の理由を示し、前のキーを残す。別のコマンドが持つキーは持ち主の名前を示し、もう一度押すと奪う。検索は名前、説明（持ち主を含む）、キーの表示を対象にし、Customized と Conflicting の絞り込みは組み合わせられる。各行の右クリックのメニューに Reset to Default（変えたときだけ有効）と Remove Shortcut を、… のメニューに Reset All Shortcuts を置く。キーは、使っているキー配列で Shift を除いた文字と、Shift の有無として保存する。そのため、キーの位置が変わる配列（⌘ だけ QWERTY の Dvorak）やデッドキーでは、キーの刻印と違う文字が記録されることがある。予約して断るキー: ⌘Q、⌘H、⌥⌘H、⇧⌘3/4/5（キーコードでも判定する）、⌘Tab、⇧⌘Tab、⌘Space、⌘`、⇧⌘`、⌥⌘Esc、⌃⌘Q。ただし、そのコマンド自身の既定のキーは除く。各行のキーは、カードの右の余白に置いた幅 140 pt ほどのキーの列に右寄せで置く。キーを消した行は「None」とし、「Conflicting」の表示はキーの下に置く。記録中の欄はその列だけを占め（角丸 6、アクセントの色の枠と薄い塗り、キーを押すまで「Type shortcut」）、知らせは行の説明の下に 11 pt で出す。断られたキーは赤、持ち主の名前は副次の色とし、行は知らせに合わせて伸び、記録が終わると元の高さに戻る。検索や絞り込みで行が隠れたときの断りの知らせは、ペインの上部に出し、検索や絞り込みを変えると消す（我々の規則）（design の値。最初の行全体を塗る記録の欄は読みにくいとオーナーが指摘した、2026-11-04）。メニューはすぐに変わる。⌘ を含まないキーのコマンドは、既定の ⌃1〜9 の Show Space も含め、我々の入力欄（名前の変更、Create a Space の名前、設定の検索）に譲る。AppKit のメニューは、無効の項目でもキーを取ってしまうからである。Tabs › Pin Tab ⌘D（Arc のメニューバー）は、選んでいる Today のタブをピン留めの先頭に置き、名前の変更のヒントを出す。ピン留めのタブでは Unpin Tab と表示し、タブを Today の先頭に移す。Look のポップオーバー（我々の規則）: 色の面は彩度 0.65 の 21 × 15 個の点で、横に色相、縦に明るさを 0.95 から 0.05 まで並べる（保存する y = 0.05 + 0.9 × 面の y。Arc から取り込んだ位置は、動かすまでそのまま）。選んだつまみから 48 pt 以内の点は 半径 2 pt から 5 pt に大きくなる。つまみは 30 pt で、3 pt の白い縁を付ける。+ は色相を 3 分の 1 回した中間の明るさの位置につまみを足し、− は 1 つ前のつまみを選ぶ。プリセットは、1 ページ目が単色 9 個、2 ページ目が 2 色の組 9 個である。Look の無い space を初めて編集すると標準の Look から始め、Reset Look で Look の無い状態に戻す。Transparency は % で表し（不透明度 = 1 − t/100）、値の表示はドラッグ中だけ出す。Glass は不透明度を保ったまま切り替えるスイッチで、Transparency を動かすと切れる。Yab の波線と点のスライダーの代わりに、標準のスライダーを使う。変更はすべてその場でサイドバーに映し、core には操作の終わりに 1 回だけ書く。操作の途中でポップオーバーを閉じると、その操作は捨てる。Use for All Spaces は space ごとに順に書く。自動アーカイブは Arc の選択肢に従う（12 時間、24 時間、7 日、30 日。既定は 12 時間。プロファイルごと。「しない」は無い。Arc のヘルプセンターの記事 19228855311127 と Archive のページ）。Today のタブは、最後に選んでからの時間が閾値を超えるとアーカイブする。ピン留めのタブ、お気に入り、いずれかのウィンドウで選んでいるタブはアーカイブしない。split の構成タブは、それぞれの時刻で期限が切れて split から抜け、最後の構成タブと一緒に split をアーカイブする。split を選ぶと、すべての構成タブに時刻を付けて守る（我々の規則）。古いストアから来た、時刻の記録が無いタブは、次の実行で時刻を付けて残すので、さらに閾値の分だけ後に期限が切れる（我々の規則）。Arc のインポートは各タブの取り込んだ日時を残すので、古い Today のタブは最初の実行でアーカイブされうる。使える日時の無い取り込んだタブには、取り込みの時点で時刻を付ける（我々の規則）。復元と、閉じたときの次のタブになることでも時刻を付ける。規則は起動時と 60 秒ごと（許容 20 秒）に実行する。何も変わらない実行は何も書かない。サイドバーのジェスチャ、ページの移動、引っ張り、表示の動き、行のドラッグとドロップの収まり、名前の変更、サイドバーのメニューの間は、反映だけを待たせ、それが終わったとき、または次の実行で反映する。終わりのイベントを取りこぼしたジェスチャは、スクロールのイベントが 2 秒来ないとき、またはサイドバーが別のウィンドウに移ったときに終わったものとみなす。スクロールのジェスチャが終わった後は、待たせていた公開を、慣性スクロールが終わるまで、または慣性スクロールが 0.15 秒来ないときまで遅らせる。リストが惰性で動いているあいだに行が動かないようにするためである（我々の規則）。アーカイブした行はアニメーションなしで消す。Tabs のペインの「Archive Today's tabs after」は、表示中の space のプロファイルの値を変え、説明にそのプロファイルを示す。Air Traffic Control のペイン（行とメニューは Cra の `UI/Settings/AirTrafficControlView.swift`（MIT）をもとにし、ほかは我々の作り）は、既定の行き先を決め、規則を順に並べる。順はドラッグで変える。各規則は Contains か Is equal to、その文字列（Return か編集の終わりで確定する）、行き先（Most Recent Space、space、Little Window）を持つ。画面では規則を route と呼び（Arc と Cra の語で、New Route と同じ）、読み上げでは route を並びの位置で呼ぶ。各 route には削除のボタンを置く。New Route は、空の Contains の route を末尾に加え、行き先は既定と同じにする。既定がペインのプロファイルと別の space を名指すときは、最も最近の space にする。既定の行き先は最初は Little Window で、それを選び直すと保存した既定を消す。既定の Little Window を選ぶと表示中の space のプロファイルで開き、route の行き先で選ぶ Little window はその route 自身のプロファイルで開く（すでに Little window に送る route はそれを保つ）。行で変えるのは route の最初の条件だけである。条件を複数持つ取り込んだ route はほかの条件も残し、どれかの条件に当てはまれば当てはまったとする（Arc の意味が分かるまで）。試しの欄に URL を打つと、打つそばから、どの route が受け持つかを core の照合で示す。説明には、ほかのアプリからのリンクは、エンジンが入ってからこの規則に従うと書く。行き先の space が消えた規則や既定は、行き先に無効の「Deleted space」を示す。その規則は当てはまったままで、リンクは core の答えに従って開く: まずその規則のプロファイルの中（最も最近使われた space）、次に既定の行き先、既定のプロファイルの最も最近使われた space の順（5 節）。文字列と照合の種類は変えられ、存在しない space を行き先に選ぶこと、規則が属するプロファイルと別の space を選ぶこと、workspace が持たないプロファイルの Little window を選ぶことは、ペインに示せる誤りとともに断る（我々の規則）。
- 拡張機能は、設定ウィンドウの Extensions のペインからプロファイルごとに追加・管理する予定である。このペインはエンジンと一緒に入れ、まだ無い。Arc に入っていて未導入の拡張機能を一覧して追加する経路を持たせ（Yab と同じ。オーナーの選択、2026-10-31）、§9 のインポートの規則に従わせる。

## 8. 同期

### 8.1 モデル

- アカウントは存在しない。同期グループは 1 台のデバイスで作成し、256 ビットのグループ秘密を基盤とする。グループ秘密は 24 語の BIP-39 リカバリーフレーズとして表示する。
- サーバーは平文、名前、秘密情報を一切見ない。サーバーは不透明な blob を保存し、それを返すだけである。

### 8.2 プロトコルの要件

同期のコードを書く前に、バージョン付きのプロトコル仕様（`docs/sync-protocol.md`）を作成し、レビューする。プロトコルは次の要件を満たさなければならない。

- 鍵スケジュール: 現在の epoch の秘密（最初の epoch ではグループ秘密、それ以降の epoch では新しいランダムな秘密）から HKDF でコンテンツ鍵、名前鍵、リレー鍵を導出し、それぞれに別のラベルを用いる（ドメイン分離）。
- 暗号化: ランダムな 192 ビットの nonce を用いた XChaCha20-Poly1305。これにより、独立したデバイスの間で nonce を調整する必要がない。AAD は、グループ、epoch、デバイス id、シーケンス番号、オブジェクト名を束縛する。
- デバイスの識別: 各デバイスは専用の署名鍵ペアを持つ。すべての blob に署名する。デバイスは署名付きのメンバーシップのレコードに列挙する。
- ペアリング: 新しいデバイスは、リカバリーフレーズを入力するか、既存のデバイスが表示する短いコードを PAKE（たとえば CPace）に通して参加する。これにより、推測または傍受されたコードから秘密が漏れることはない。
- リレーの認可: リレーは、グループに登録されたデバイス鍵からの書き込みだけを受け付け、リレー鍵から導出したリレー用の資格情報による読み出しだけを受け付ける。リレーはコンテンツ鍵を保持しない。
- リプレイ: 各デバイスはデバイスごとのシーケンスのチェックポイントを保持し、チェックポイント以下の blob を拒否する。
- 削除: デバイスを削除すると、新しいランダムな epoch の秘密から新しい epoch を開始する。この秘密は、削除の操作をしたデバイスが残りの各デバイスの鍵で封緘して送り、group secret だけからは導かない。そのため、削除されたデバイスは新しい鍵を導けない。古い epoch の relay の credential は失効させ、membership のレコードからそのデバイスを外し、残りのデバイスは新しい epoch のもとでスナップショットを封緘し直す。削除ではグループ秘密も置き換える。オーナーには新しい recovery phrase を示し、古いフレーズではグループに参加できなくなる。フレーズでの参加には現在のグループ秘密が要るからである。各 epoch の秘密は、現在のグループ秘密から導いた復旧用の鍵で封緘して relay にも置く。そのため、残る端末が無くても、現在のフレーズだけで現在の鍵を取り戻せる。グループ秘密を先に置き換えるので、削除された端末はそれを開けない。復旧は、取り戻す対象の epoch の秘密に依らない。グループ秘密からは、別のラベルで、復旧用の読み出しの credential と、復旧用の署名鍵の対も導く。relay は、前者ではその封緘した blob だけの読み出しを受け付け、後者の公開鍵をグループについて保持する。フレーズで復旧する端末は、この credential で blob を読み、復旧用の鍵の署名を付けて自分の新しいデバイス鍵を登録する。グループ秘密を置き換えると、relay の側でも両方を置き換えるため、古いフレーズでは blob を読むことも、端末を登録することもできない。
- 最初のリリースからの復元の安全性: バックアップから復元したデバイスは新しい incarnation を得て、incarnation やシーケンス番号を再利用しない。

### 8.3 データの経路

- 各デバイスは追記だけを行う: シーケンス番号付きのデバイスごとのログと、version vector 付きの定期的なスナップショット。どのデバイスも他のデバイスの blob を書き換えない。
- merge は、ハイブリッド論理時計に基づくレコードごとの last-writer-wins とし、merge の後に 6.1 のツリーの規則を適用する。
- blob は 1 KiB 単位にパディングし、圧縮しない。
- ローカルのジャーナルは、アップロードの前に、workspace の変更と同じトランザクションで書き込む（5.2）。
- tombstone（削除を表す記録）は、デバイスの退役、epoch、長期間不在だったデバイスに対するスナップショットによる再参加の義務付けが実装されるまで無期限に保持する。これらが実装されて初めて回収を許可する（Ardia ledger 3 は、取り消した試みから判明した要件を列挙している）。
- 新しいレコードの種類は、古いバージョンが読み取らず、そのまま保持するキーのもとに追加する。これにより、古いクライアントが新しいレコードを損なった状態で書き戻すことはない。iPhone のクライアントは、使用できないレコードの種類（たとえば拡張）も保持する。

### 8.4 同期の対象

workspace、Air Traffic Control の規則、キーバインド、設定、パスワード、Web Store の拡張を同期する。Air Traffic Control の規則は workspace ごとに持つ。規則ごとに、fractional order key を持つ同期の `routing_rule` のレコードを 1 件置き、item と同じく上書きだけで merge する。既定の行き先は、変えたときだけ `routing_default` のレコードを置き、消すと既定に戻る。キー割り当ての変更はコマンドごとに全体で 1 つとし、同期する `key_binding` のレコード 1 件に置く。既定は導くもので保存しない。null はそのコマンドを無効にし、レコードを消すと既定に戻る。キーを割り当てると、同じバッチで、そのキーを持つほかのコマンドから外す。merge したレコードが 1 つのキーを複数のコマンドに与えたときは、core のコマンド表で先にあるコマンドが持ち、ほかのコマンドはキーを示さずに Conflicting とし、求めたキーは報告する。持ち主が後でキーを外す、移す、戻すと、Conflicting のコマンドは自分のキーを取り戻す。読むだけの操作は何も書かない。パスワード: エンジンはレコードをゼロで消去するバッファとしてコアに渡し、コアがそれを封緘する。平文がブラウザプロセスの外に出ることも、UI のレイヤーに届くこともない。拡張は、バージョンと権限が承認済みのものと一致する場合にだけ、別のデバイスで有効にする（Ardia ledger 1.5）。履歴の同期は後で対応する。

### 8.5 サーバー

小規模な Rust のサービスである: グループごとの blob の put/get/list、デバイス鍵の検証、レート制限、サイズの割り当て。ストレージは SQLite または S3 互換のストアとする。ホスティングはオーナーの判断である（14）。

### 8.6 採用しなかった案

- Chrome Sync: Google を必要とする。
- セルフホストの Chromium 同期サーバー（Brave の `go-sync`）: Chromium のデータ型しか扱えないため、workspace には第 2 の仕組みが必要となる。また、iPhone のアプリには Chromium の同期エンジンが存在しない。
- ユーザーが選択するフォルダ（Ardia）: iPhone と Windows に同じ方法で届くフォルダは存在しない。オーナーはサーバーを選択した。

## 9. 拡張、コンテンツブロック、DRM、Safe Browsing

- 拡張は実際の `Browser` と `TabStripModel` のオブジェクト上で動作する。このため、`chrome.tabs`、`chrome.windows`、アクションのポップアップ、サイドパネルは Chrome の実装を用いる。
- インポート: Web Store の拡張は Web Store から再インストールし（検証済みのパッケージ）、ツールバーの順序は移行元のブラウザのピン留めリストから取得する（Cra ledger 8b）。パッケージ化されていない拡張は、拡張ごとに明示的な承認を得た後にだけインポートする。Chromium の権限、ブロックリスト、シークレットの検査は変更せずに適用する。
- ネイティブメッセージング: 他のブラウザ向けに登録されたホストのマニフェストは、マニフェストと実行ファイルのコード署名を検証した後にだけ独自のプロファイルにリンクする。Chrome 自体を操作するホストはリンクしない（Cra ledger 29）。
- Web Store からのインストールと更新は Google に直接接続し、Google の拡張の kill switch は有効のままとする（Ardia ledger 1.7）。
- コンテンツブロッカー、DRM、Safe Browsing はオーナーの判断である（14）。第 2 のページエンジンを採用するとページの API が変わるため、DRM は phase 6 の API 凍結の前に決定する。

## 10. 他のプラットフォーム

- **Windows と Linux。** エンジンのツリーとレイヤーは同一である。UI は Chromium の Views（C++）で実装し、C ABI を介してコアをリンクする。coordinator、規則、同期は変更せずに再利用する。Wayland ではクライアントがグローバルなポインタの位置を読み取れないため、フローティングサイドバーのウィンドウ外の規則は Wayland では制限される。
- **iPhone。** App Store のブラウザは WebKit を使用する。例外は日本（iOS 26.2 以降）と EU（iOS 17.4 以降）であり、これらの地域では Apple のブラウザエンジンの entitlement のもとで別のエンジンを使用できる。この entitlement は、適時のセキュリティ更新を含む Apple の基準を満たすことを要求する。iPhone のアプリは、WKWebView と SwiftUI/UIKit の UI、および同一の Rust のコアと同期で構成する計画である。iPhone では Chrome 拡張は使用できない。iOS 向けの Blink のビルドは計画していない。

## 11. テストと計測

- コア: 誤っているとデータを失うか漏らすもの（merge、ツリーの不変条件、クラッシュ時の照合、インポート、ATC の照合、archive の規則）と、出荷済みのバグ（Ardia ledger 1.9）に対するユニットテスト。
- UI: harness は fixture のデータでコンポーネントを実行する。コマンドのチャネルにより、ポインタを使わずに harness を操作する。
- エンジン: 広い範囲を網羅するための非表示のインスタンスと、非表示の実行では確認できないもの（フォーカス、passkey、フルスクリーン、アクセシビリティ、compositor のタイミング）を確認するための表示ありの検査。
- クラッシュと再起動のテスト: 選んだ時点でプロセスを kill し、照合を検査する。
- 同期: 編集の後にオフラインから復帰するデバイス、デバイスの削除と鍵の更新、バックアップからの復元。
- 最初のビルドから、メインスレッドの引っかかりの監視を行う（Cra ledger 13）。
- 性能の関門: 1 つのベンチマークコントローラーが、分離した対照（前回のリリース）と候補のプロセスを、同じ fixture で交互に実行し、実時間だけでなく回数（レイアウトのパス、ストアの更新、エンジンとの往復）に上限を設ける（Ardia ledger 1.9）。
- 速度に関する変更は、所有者と削除日を定めた kill switch の背後に置いて出荷する。

## 12. 配布

- Developer ID による署名と notarization。Sparkle 2 と EdDSA 署名付きの appcast、stable と nightly のチャネル（macOS）。
- bundle id、team id、entitlement（passkey 用のキーチェーンのアクセスグループ、Bluetooth の使用）、ヘルパーの署名は、資格情報の保存がこれらに依存するため、phase 3 の spike で確定する。
- phase 3 のバンドルは ad-hoc で、内側から署名する（`bundle-app.sh`）: framework の dylib、裸のヘルパー実行体、各ヘルパー app、framework、最後に app。Renderer と GPU のヘルパーはエンジンの allow-jit entitlement を、app はエンジンのデバイス系 entitlement を持つ。team を必要とするもの（`keychain-access-groups`、`com.apple.application-identifier`、`com.apple.developer.associated-domains*`、`com.apple.developer.web-browser.public-key-credential`、値に team の接頭辞を含むものすべて）は、スクリプトの stderr に名前を出して落とす。値が team の接頭辞を持ち、ad-hoc の署名には team がないからである。ad-hoc の下では hardened runtime を使わない。bundle id は `net.iodine2.ararat` で、製品名とヘルパー名は Chromium のままとする。バンドルの実行はすべて `CFFIXED_USER_HOME` を使い捨ての home に置き、bundle id が作る `NSUserDefaults` のドメインの書き込みが `~/Library` に届かないようにする（我々の規則）。
- CI では署名のフェーズをビルドのフェーズから分離する。action はコミットの SHA で固定する。
- すべてのリリースに Corresponding Source を付ける（4.7）。
- Windows と Linux のアップデーターは、それぞれの phase で決定する。

## 13. 開発プロセス

各作業単位は次の順で進める: Opus 5.5 がスコープを決め → Codex `gpt-6.1-terra`（effort high、labteam アカウント）と OpenCode の GLM-5.3-Flash が 2 席で並列に実装し（オーナーの選択、2026-11-04。2026-11-06 から無料モデル `opencode/glm-5.3-flash-free`）→ Opus 5.5 がレビューし、指摘ごとに修正するか否かを判定する。際どいエッジケースのバグは逆順で進める（Codex が調査し、Opus がセカンドオピニオンを出し、Codex が実装し、Opus がレビューする）。計測と設計段階の作業は、オーナーが求めない限りレビューを要しない。タスクは orca-agent-team または herdr-agent-team の席で実行する（`AGENTS.md`）。レビューと判定は `docs/reviews/` に保存する。

## 14. オーナーが決める未決の事項

| 項目 | 選択肢 | 現時点の方向 |
|---|---|---|
| favorites をプロファイルごと（Arc）に共有するか、space ごと（Cra）に共有するか | プロファイル / space | Arc と同じくプロファイル。モックの後に再検討する |
| セキュリティのための Chromium の milestone の更新（フルビルド）を事前承認するか | する / 毎回確認する | する。4.9 のパッチの遅延の上限の範囲内で |
| DRM | Google の VMP 署名付きの Widevine / DRM を要するサイト向けに第 2 のエンジンとして WebKit（Ardia）/ 当初はなし | phase 6 の前に決定する |
| コンテンツブロッカー | uBlock Origin（MV2、Ardia）/ uBlock Origin Lite（MV3）/ 寛容なライセンスのリストを用いた Chromium の subresource filter | Chromium がサポートする経路にとどまるため、uBO Lite |
| Safe Browsing | API キーを用いた Google Safe Browsing / 別の評判のソース | 日常的な使用の前に必須（4.9）。ソースは未決 |
| 同期サーバーのホスティング | 自前の VPS / Cloudflare（Workers + R2）/ その他 | phase 8 で決定する |

## 15. ロードマップ

各 phase は、動作するビルドとサンドイッチ型のレビューで終える。

| Phase | 内容 | 完了の条件 |
|---|---|---|
| 0 | リポジトリ、devshell、調査の取り込み、本文書 | レビュー済みの設計 |
| 1 | エンジンなしのコアの基礎: 所属のレジスタを持つモデル、ATC、Arc のインポート、クラッシュに対して安全な書き込みを行う SQLite、UniFFI バインディング。harness 上でコアのデータを用いる `AraratUI` の最小限のサイドバー。これと並んで、`morluto/rea` の clone、Yab の利用規約の範囲内での Yab の静的解析（レイアウト、クラス名、設定の構造）、Yab のフローティングサイドバーと設定の観察、仕様の作成を行う | harness が実際の Arc のインポートを表示する。ツリーの不変条件とクラッシュに対して安全な書き込みに関するコアのテストが通る |
| 2 | Mac Studio 上のエンジンのビルド基盤: Xcode、固定した Chromium、ungoogled-chromium のパッチの一覧作成、GN args、ロック、初回ビルドとインクリメンタルビルドの計測、`series-check`、1 回のリベースの計測 | 独自のスクリプトによる、選んだベースの標準ビルド |
| 3 | 縦断スライスの spike: コアの coordinator と最小限のサイドバーを備えた `//ararat/core` を、署名済みのアプリ（bundle id、team、entitlement、ヘルパーの署名）で動かす。受け入れ条件（非表示と表示あり）: 1 つのウィンドウ内の 2 つのプロファイルと拡張から見たウィンドウの意味論、すべての生成経路によるポップアップ、拒否を含む autofill・passkey・権限のプロンプト、外部プロトコルの確認、フルスクリーンの解除、ドッキングした DevTools、ポップアップ付きの MV3 拡張、Chromium が run loop を所有した状態での正常な終了とキャンセルされた終了、ウィンドウ間のページの移動と 2 ペインの split、compositor の計測と決定、⌘L の後の IME と貼り付け、クラッシュと再起動の照合、1 回の練習のリベース。責務の表（4.6）を完成させる。U3 から実行可能: エンジン起動の検査（`--ararat-check=started`）、スクラッチ profile の拒否、独自バンドルの標準デリゲートのヘルパー。U4: `--ararat-check=window` で非表示の host、native window の一致、hit test を検査し、Browser の破棄を待つ。U5: `--ararat-check=tabs` で transaction feed と page card を検査する（我々の規則） | すべての受け入れ条件の検査が通る。compositor のモデルを選定済み |
| 4 | UI の構築: 完全なサイドバー、favorites、フォルダ、space のページング、Arc の規則によるフローティングサイドバー、テーマ、Chromium の autocomplete を用いた command bar | オーナーが Arc のレイアウトでブラウジングできる |
| 5 | Little window、既定のハンドラーとしての Air Traffic Control、split view、archive、ダウンロード、セッションの復元 | 日常の使用において Arc のワークフローと同等 |
| 6 | 配布とセキュリティの関門: Developer ID、notarization、Sparkle、CI での署名、Corresponding Source、4.9 の保守のジョブ、評判の検査。DRM を決定し、ページの API を凍結する | 自己更新する署名済みのビルド。オーナーが日常的な使用を開始する |
| 7 | 設定（オーナーによる space ごとの設計を含む）、パスワード・cookie・拡張のインポート、キーバインド | オーナーが Arc から移行する |
| 8 | 同期: レビュー済みのプロトコル仕様、クライアント、リレーサーバー | 2 台の Mac がアカウントなしで同期する。オフラインからの復帰、削除、復元のテストが通る |
| 9 | Windows: 同一のエンジンのレイヤーとコアの上に Views の UI を置く | space と同期を備えた Windows のビルド |
| 10 | Linux: Views の UI、Wayland と X11 | space と同期を備えた Linux のビルド |
| 11 | iPhone: コアと同期を備えた WKWebView のアプリ | iPhone に同期された workspace |

Cra はオープンソースであるため、Cra の挙動はソースから読み取る。Cra のバイナリに REA を実行しても、コードから得られる以上の情報は得られない。REA は Yab に対して使用する（phase 1）。使用は 2026-09-30 付の Yab の利用規約の範囲内で行う。この利用規約はあらゆる合法的な利用を認めており、解析を禁じる条項を含まない。
