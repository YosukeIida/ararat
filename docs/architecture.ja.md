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
| エンジンのベース | 暫定: Chromium と Helium のパッチセット。phase 2 で Chromium と ungoogled-chromium の組み合わせと比較して決定する | Helium は脱 Google 化、コーデック、マルチプラットフォームのパッケージングを提供し、GPL-3.0 とも整合するが、保守上の正味の利点は実証されていない（Ardia ledger 1.2 は、Ardia 自身が Helium へ移行した理由を推測と記している） | 4.2 |
| エンジン ↔ アプリの API | framework からエクスポートする、手書きで型付きの Objective-C API を Swift から呼び出す | Swift は生成したグルーコードなしで Objective-C をインポートできる。Dia も Objective-C を Swift に公開しているが、146 個のクラスを mojom から生成している | 4.4 |
| run loop | Chromium がプロセスとメインループを所有し、AppKit の UI はその内部で起動する | 外部からのポンプに起因するバグを排除する（Ardia ledger 1.1） | 4.5 |
| ウィンドウモデル | アプリのウィンドウ 1 つにつき、Views を基盤とする `NSWindow` を 1 つ置き、そのウィンドウに表示するプロファイルごとに Chrome の `Browser` を 1 つ保持する。タブのビューは独自のビューツリーに配置する | Chrome の bubble とダイアログはウィンドウに付随する。プロファイルの切り替えはビューの差し替えで済む。オーバーレイは通常のサブビューとして実装できる | 4.6 |
| 状態の所有 | Rust のコアが workspace と live-tab coordinator を所有し、Chrome の `TabStripModel` が live タブを所有する。両者は epoch で修飾し、revision を付けたトランザクションを介して接続する | 1 つの事実につき書き手は 1 つとする（Ardia ledger 1.4）。Rust に置いた coordinator はすべてのプラットフォームで再利用する | 5 |
| コア | Rust の crate `ararat-core`、SQLite のストレージ、Swift 向けの UniFFI バインディング、C++ 向けの C ABI | macOS、Windows、Linux、iPhone で同一のコアを使用する | 6 |
| macOS の UI | 動きのある部分はすべて AppKit、設定とオンボーディングは SwiftUI | Cra は SwiftUI から AppKit へ移行した後、space のスワイプ時のメインスレッドの処理時間が 1900 → 440 ms になったことを計測した（Cra ledger 12） | 7 |
| 同期 | エンドツーエンド暗号化とし、アカウントを必要としない。独自サーバーは、認証済みで追記のみの blob を中継するブラインドリレーとする。デバイスはリカバリーフレーズ、または PAKE（パスワード認証鍵交換）で認証したペアリングコードで参加する | 「独自サーバー、ログインなし」の条件を満たす。Chromium の同期エンジンや共有フォルダが存在しない環境（iPhone、Windows）でも動作する | 8 |
| プロセス | すべての作業単位は、設計・実装（Opus 5.5）→ レビュー（Codex gpt-6.1-sol）→ 判定（Opus 5.5）の順で進める | オーナーの規則（`AGENTS.md`） | 13 |

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
    apply.sh       copies our code in, applies hooks (idempotent, --check)
  macos/           one SwiftPM package
    Sources/ararat_ffiFFI/  C module for the core's UniFFI header; links the Rust static library
    Sources/AraratKit/      Swift adapter over the core bindings (generated) and, later, the engine API
    Sources/AraratUI/       AppKit + SwiftUI components (library)
    Sources/AraratHarness/  UI harness: real components on real core data, a placeholder where the page goes
    scripts/build-core.sh   builds the core and regenerates the bindings
    App/                    the browser app (Xcode project, from phase 3)
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
| ベースのパッチセット（採用した場合は Helium） | 取り込み、ガード付き | `engine/patches/series` | スキップリストとガードにより、スキップしたパッチが含まれないこと、およびスキップによって保護している箇所に何も手が入らないことを検査する |
| Rust のコア、同期、インポート | 分離 | `core/` | Chromium の型を使用しない |
| AppKit の UI | 分離 | `macos/` | エンジンとは `AraratKit` を介してのみ通信する |

### 4.2 ベースとパッチの管理

- クリーンな Chromium の revision とベースのパッチセットは、`engine/build-inputs.toml` で別々に固定する。
- Helium は暫定である。phase 2 では、Chromium + Helium と Chromium + ungoogled-chromium のどちらを採るかを、次の 2 点で決定する。1 つは、ベースの全パッチについて、維持・スキップ・対抗パッチのいずれかとセキュリティ上の帰結（たとえば Helium のビルドフラグは Safe Browsing を無効にする）を記した、固定した一覧である。もう 1 つは、1 回のリベースの計測である。
- Helium を維持する場合は、Ardia に倣い、こちらの選択と衝突するものをスキップする。対象は、パスワードマネージャーの削除、キーチェーンの名称変更、Sparkle の統合、クラッシュダイアログ、オンボーディング、services ページ、!bangs、Web Store のプロキシである（Ardia ledger 1.2）。
- パッチの順序の唯一の正本は `engine/patches/series` である。パッチ名は関心事を表し、順序を示す接頭辞は付けない。
- `series check` は、固定したベースに対してスクラッチのツリーで series 全体を fuzz なしで適用し、ビルドツリーとバイト単位で比較する。`series check` はエンジンのリリースのたびに事前に実行する。
- Chrome のファイルへの大きな編集は、新しいクラスと小さな hook に書き直す（Ardia は 1,012 行の PiP パッチをこの方法で書き直した）。
- 指標はパッチの数ではなく、Chrome のファイル内の hunk の数とする。

### 4.3 Hook

hook は `ararat_hooks.h` で宣言する `g_ararat_*` の関数ポインタであり、`ararat_hooks.h` はパッチを当てた Chrome のファイルと独自レイヤーの両方からインクルードする。hook が未設定のとき、Chrome は標準どおりに動作する。シグネチャの変更はコンパイル時にエラーとなる。

### 4.4 エンジン ↔ アプリの API

- framework は `//ararat/core` から手書きの Objective-C クラスをエクスポートする（たとえば `ARWindowHost`、`ARTab`、`ARProfile`、`ARExtensions`、`ARDownloads`、`ARAutocomplete`、`ARPasswords`）。Swift はこれらを framework の module map を介してインポートする。
- すべてのクラスに共通の契約は次のとおりである。メインスレッドに固定する（他のスレッドからの呼び出しはプログラミングエラーであり、debug ビルドでは abort する）。Chrome のオブジェクトをラップするオブジェクトは、Chrome のオブジェクトが破棄された時点で無効化し、無効化したオブジェクトへの呼び出しはすべて何もせずにエラーを返す。コールバックはキャンセルトークンを持ち、無効化の後には発火しない。ラッパーは Swift が所有し、Chrome のオブジェクトはエンジンが所有する。
- UI が必要とするサービス（パスワード、autofill、拡張、ズーム、検索エンジン、履歴、ブックマーク、ダウンロード）は、独自レイヤーから Chrome のサービスを直接呼び出す。`chrome://` の WebUI ページをスクリプトで操作することはしない（Ardia ledger 1.4）。
- アプリとエンジンは同時に出荷する。互換性のための分岐は設けない。起動時に API のバージョンを 1 回検査し、不一致の場合は abort する。

### 4.5 プロセスと run loop

- `main` は独自のエントリポイントを呼び出し、エントリポイントは独自の `ChromeMainDelegate` サブクラスを渡して `ChromeMain` を呼び出す。`NSApp` は Chrome の `BrowserCrApplication` である。Chromium の起動前に `NSApp` に触れる処理は存在せず、AppKit の UI は Chromium の起動時のコールバックから生成する。
- Chrome の `AppController` は、終了、Dock、ログアウトのイベントを所有する独自のオブジェクトに置き換える。このオブジェクトは、キャンセル可能なクローズと終了（beforeunload、ダウンロードの確認）と、ウィンドウが 1 つも開いていないときの keep-alive を実装する（Ardia ledger 1.1）。

### 4.6 ウィンドウ、タブ、および Chrome の UI から引き継ぐ責務

**ウィンドウとプロファイル。**

- アプリのウィンドウ 1 つは、Views を基盤とする `NSWindow`（`NativeWidgetMacNSWindow`）1 つである。これにより、Chrome の bubble、ダイアログ、メニュー、autofill のドロップダウンが子ウィンドウとしてこのウィンドウに付随する。
- ウィンドウに表示する各プロファイルは、それぞれ専用の Chrome の `Browser` を持つ。その `BrowserWindow` は独自のオブジェクトであり、`BrowserView`、フレーム、タブストリップ、ツールバーを持たない。
- 拡張から見たウィンドウの意味論は次のとおりである。プロファイルごとの `Browser` は、それぞれ別個の拡張のウィンドウ id である。アプリがアクティブな間は、キーウィンドウで表示しているプロファイルの `Browser` がフォーカスを持つウィンドウである。他のアプリのウィンドウで表示している `Browser` はフォーカスなしだが最小化はしていないものとし、非表示のプロファイルの `Browser` はフォーカスなし、かつ最小化に相当する bounds を報告する。アプリが非アクティブになると、すべてがフォーカスなしになる。拡張自身のコンテキスト（popup、side panel、タブの content script）の `currentWindow` は、そのコンテキストがある `Browser` とする。background のコンテキストでは、フォーカスを持つ `Browser`、アプリが非アクティブな間は最後にフォーカスを持った `Browser` とする。これらの規則により、`windows.getCurrent`、フォーカスのイベント、`tabs.query({active: true, currentWindow: true})` は、ユーザーが見ているものと一致する。非表示のプロファイルのウィンドウに対する `windows.update({focused: true})` は、アプリのウィンドウをそのプロファイルに切り替える。spike では、2 つのアプリのウィンドウに表示した 2 つのプロファイル、その間でのフォーカスの移動、アプリの非アクティブ化、拡張が生成したウィンドウ、非表示のプロファイルで動作する拡張を用いて、この挙動を検証する。
- 拡張のポップアップウィンドウ（`windows.create({type: "popup"})`）は実際のポップアップウィンドウのままとする（Cra ledger 10）。独自の内部用ヘルパーウィンドウは拡張から隠す（Ardia ledger 1.7）。プロファイルの `Browser` は内部用ではなく、拡張から見える。

**タブ。**

- タブの `WebContentsViewCocoa` は独自のビューツリーに配置する。これらのビューをどの compositor（描画の合成を担う機構）が所有するか（タブのビューごと、プロファイルごと、ウィンドウごとの共有）は spike で決定する。Ardia は、ビューごとの compositor がタブの切り替えのたびに 1〜2 回のリフレッシュ分の遅延を生むこと、および後から変更すると描画の書き直しを要することを見出したためである（Ardia ledger 1.3、1.6）。spike では、各候補について、切り替え時の最初のフレームまでの遅延、バックグラウンドのページの活動、オクルージョン、リサイズ、分割ペイン、ディスプレイの変更を計測する。
- 新しいコンテンツ: renderer が生成したウィンドウは、既存の `WebContents` と保留中のナビゲーションの状態を保持したまま、`AddNewContents` を経由して独自レイヤーに届く。修飾キー付きのクリックやフォームの target は別の経路（`OpenURLFromTab`）を通る場合がある。固定した revision 上のすべての生成経路を列挙し、それぞれ個別にテストする。対象は、POST の target、features 指定の有無それぞれの `window.open`、⌘ クリック、shift クリック、opener の関係、ブロックされたポップアップである。Chrome が自ら生成するウィンドウ（`chrome.windows.create`、シークレット、ドッキングしていない DevTools）は、`Browser` のコンストラクタ内の hook によって独自レイヤーへ回す。
- 1 つのページは 1 か所にだけ表示する。live のページは、ちょうど 1 つのペインにだけ表示する。2 つ目のウィンドウやペインが同じ workspace のタブを選択した場合、key になったウィンドウがページを取得し、もう一方のウィンドウは再び key になるまで、ぼかしたスナップショットのプレースホルダーを表示する（Arc の挙動、Cra ledger 19）。1 つのウィンドウの中では、フォーカスを取ったペインがページを取得し、もう一方のペインはプレースホルダーを表示する。分割ペインの spike でこれを確かめる。ウィンドウを閉じるときは、別のウィンドウがまだ表示しているページを再読み込みせずに移動する（Cra ledger 20）。
- 分割ペイン: 各ペインは 1 つのタブを保持する。フォーカスのあるペインのタブが、その `Browser` における Chrome の active タブである。他のペインは表示されているが非 active である。区切り線のドラッグ中はページのサイズを固定し、ドラッグを離したときに 1 回だけリサイズする（Cra ledger 21）。

**Chrome の UI から引き継ぐ責務。** `BrowserView` を用いないため、`BrowserView` が担っていたすべての責務に所有者が必要である。spike でこの表を完成させる。最初の項目は次のとおりである。

| 責務 | 所有者 |
|---|---|
| 権限のプロンプトとその拒否 | seam の実装（ホスト側の UI） |
| 外部プロトコルの確認 | seam の実装 |
| デバイスの chooser（USB、HID、Bluetooth、シリアル）、Cast | seam の実装 |
| フルスクリーンとポインタロックの解除の警告 | seam の実装（`ExclusiveAccessContext`） |
| 拡張のアクションのポップアップ、インストールのプロンプト、インストール完了の bubble、サイドパネル | seam の実装 |
| パスワードと autofill の bubble | seam の実装。autofill のドロップダウンは Chrome の子ウィンドウのままとする |
| ページ内検索 | Chrome の `FindTabHelper`、ホスト側の UI |
| ページとブラウザのコマンドの間のキーボードイベントの振り分け | ホスト。Chrome の規則に従う: ページを先に処理し、処理されなかったキーはメニューに戻し、予約キーは最初に取得する（Cra ledger 11） |
| フォーカスの受け渡し（⌘L、⌘T の直後の貼り付け） | ホスト。メインスレッド上で同期的に処理する（Ardia ledger 1.10） |
| ウィンドウのアクセシビリティツリー | ホストのビューと Chrome の Web アクセシビリティ |
| ダウンロードの UI | ホスト（Chrome の bubble は無効にする） |
| セッションの永続化 | 独自レイヤー（下記） |

**セッション。** 独自の `Browser` については Chrome のウィンドウの自動復元を無効にするが、永続化の責務そのものは放棄しない。独自レイヤーは、各タブのナビゲーションスタック、選択中のエントリ、セッションストレージの名前空間を、Chrome 自身のセッションのコードでシリアライズし、コアの安定した項目 id をキーとして保存する。保持期間は次のとおりである。live タブと、読み込まれていない workspace のタブは、エントリを保持する。archive したタブは、archive が存続する間エントリを保持する。最近閉じたタブは Chrome の上限に従う。タブを復元するときはエンジンにコアの id を渡し、エンジンは履歴を含めて `WebContents` を再構築する。

### 4.7 ビルドと成果物の同一性

- ビルドはリポジトリ外の `~/chromium-build` に置く。通常の作業中はインクリメンタルビルドのみを行う。
- Ardia の数値: M5 Pro で初回ビルドに約 2〜2.5 時間、インクリメンタルビルドに約 7 分（コンパイルと ThinLTO の再リンク）、ディスクは約 45 GB。こちらの数値は phase 2 で Mac Studio 上で計測する。
- エンジンのビルドはロックのもとで一度に 1 つだけ実行する。
- GN args は 1 つのファイルに置く: official build、ThinLTO、PGO、DCHECK なし、シンボルの除去、`proprietary_codecs=true`、`ffmpeg_branding="Chrome"`、独自のブランディング。
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
- コアの coordinator は id を付けて live タブのコマンドを発行する。エンジンはトランザクション `{epoch, rev, cause, strips}` で応答する。`epoch` はエンジンの起動のたびに変わる。`rev` は 1 つの epoch の中で単調に増加する。`cause` は、独自のコマンドの id、独自のエンジン呼び出し、Chrome 自身のいずれかである。1 つのトランザクションに複数の cause を混在させない。エコーを抑制する時間窓や、「自分が起こした変更か」を示すフラグは設けない。
- Chrome が自ら行う変更（拡張によるタブの移動、クローズ後の後継タブ）は差分を取り、コアの規則によって workspace に適用する。後継タブは、Chrome の選択ではなくコアの規則（split の連続性、折りたたんだタブと読み込まれていないタブのスキップ）に従う。
- タブの切り替えでは、まずネイティブにページを表示する。表示の経路に UI の状態を経由する往復は含めない。

### 5.2 クラッシュ時の一貫性

- すべての live タブはコアの安定した項目 id を持ち、それをエンジンのタブごとのセッションデータに保存する。これにより、対応関係は再起動後も保たれる。
- 起動時、エンジンは新しい epoch の完全なスナップショットを報告し、coordinator はそれを workspace と照合する。正とするのは workspace である。各項目は、ライフサイクルの状態（開いている、読み込まれていない、閉じた、アーカイブした）を、変更と同じトランザクションで記録する。閉じる操作とアーカイブは、coordinator がエンジンに伝える前に commit する。workspace が開いている、または読み込まれていないと記録していてエンジンが知らないタブは、復元するか、読み込まれていない状態として記録する。項目が閉じた、アーカイブした、または削除した状態のエンジンのタブは、取り込まずに閉じ直す。項目が存在しないエンジンのタブ（クラッシュの前の、commit されていない最後の 1 秒に生成されたもの）は Today に取り込む。コマンドの完了は発行時の epoch を持ち、現在の epoch でなければ捨てる。
- クラッシュ時に失われうる範囲: workspace の変更は、その SQLite トランザクションがコミットされた時点で永続化され、コミットは、ストレージが動いている間はイベントから最大 1 秒後である（メインスレッド外でバッチ処理する）。書き込みが失敗している間（次の項目）は、再試行が成功するまでこの範囲が広がる。クラッシュで失われうるのは、最大でその直近 1 秒分の workspace の変更である。workspace と送信用の同期ログは同じトランザクションで書き込むため、クラッシュによって両者が不整合になることはない。
- ディスクの容量不足や書き込みの失敗の場合は、メモリ上の状態を保持し、バックオフ付きで再試行し、ユーザーに通知する。データベースを切り詰めることはしない。
- バックアップには SQLite の backup API を用いるため、WAL も含まれる。

### 5.3 プライベートブラウジング

off-the-record のプロファイルは、エンジンの契約における属性であり、すべてのトランザクションとタブがこの属性を持つ。コアは off-the-record の workspace の状態をメモリ上にだけ保持し、それに対する永続的な書き込み、archive のエントリ、同期のレコード、command bar の学習を 1 か所でまとめて拒否する。テストでは、プライベートタブを開いた状態でのクローズ、クラッシュ、archive、同期を対象とする。

## 6. Rust のコア

### 6.1 内容

- workspace のモデル: プロファイル、space、コンテナ（favorites はプロファイルごと、または space ごと、14）、項目（タブ、フォルダ、split）、archive のエントリ、ウィンドウの状態。
- ツリーの表現: 各項目は所属のレジスタ `(parent id, fractional order key, HLC, previous parent id)` を 1 つだけ持つ。子のリストは導出するものであり、別に保存しない。修復は、merge したレジスタの上の決定的なビューである。修復の結果は、同期するレジスタに書き戻さない。そのため、同じ移動を異なる順序で受け取ったデバイスも、同じツリーを計算する。修復したレジスタを書くのはインポートだけである。インポートするファイルがそれらのレジスタの出どころだからである。決定的な修復は次のとおりである。循環を生む移動は、HLC（ハイブリッド論理時計）のタイムスタンプが大きいほうの移動を残し、もう一方の項目を以前の親に付け直して解決する。親が存在しない項目は、その space の Today コンテナに移す。space は移動前の親（レジスタに記録する）の祖先のコンテナから決め、決まらなければ先頭の space とする。以前の親に戻しても循環が解けない項目は Today に移す。削除と並行する編集とでは、編集が復元である場合を除き、削除を優先する。ツリーの不変条件のテスト（循環がないこと、すべての項目にちょうど 1 回到達できること）と配送順序のテストは、すべての merge のテストで実行する。
- 規則: Arc 上で計測したとおりの Air Traffic Control の照合（大文字小文字、スキーム、先頭の `www.` を無視する。「Contains」はクエリとフラグメントも検査する。「Is equal to」はホストとパスだけを比較する。最初に一致したものを採用する）、自動 archive の閾値、後継タブの規則、split のレイアウトの計算。
- live-tab coordinator: エンジンのトランザクションを適用し、コマンドを発行し、起動時に照合する（5）。
- インポート: Arc（`StorableSidebar`、`StorableWindows`、`StorableArchiveItems`、`StorableKeyBindings`、`StorableLinkRouting`）、後に Dia、Chrome、Safari、Firefox。インポートは中立な計画を生成する。Chromium のデータ（パスワード、cookie、履歴）は、エンジンを介して Chrome のストアに書き込む。
- エンジンが供給するソース（Chromium の `AutocompleteController` の結果、開いているタブ、workspace の項目、コマンド）に対する command bar の順位付け。
- 同期クライアント（8）。

### 6.2 ストレージ

workspace、archive、同期のジャーナルには SQLite（WAL）を用いる。書き込みはメインスレッド外で実行する。Cra の JSON ファイルは、書き込みをメインスレッド外に移す前、2,000 項目の archive の書き込み 1 回あたりメインスレッドで約 30 ms を要した（Cra ledger 16）。SQLite は 5.2 が必要とするトランザクションを提供する。

各レコード（space、item、favorites のコンテナ）は 1 行 `(kind, id, JSON の本体)` として保存する。space も item と同じく fractional order key を持ち、一覧は保存しない。各変更は同じトランザクションでジャーナルの表にも追記する。この版が知らない kind の行は変更せずに残す（8.3）。writer スレッドは、バッチの最初の変更から 1 秒以内に `synchronous = FULL` で commit する。

### 6.3 バインディング

- `ararat-ffi` は、UniFFI（macOS と iPhone の Swift 向け）と C ABI（Windows と Linux 向けの、Chromium のツリー内の C++ 向け）を介してコアを公開する。
- コアは同期的であり、ストレージの書き込み用スレッドと同期のワーカー以外のスレッドを所有しない。Swift のアダプターは 1 つの serial queue からコアを呼び出し、スナップショットを UI に公開する。
- 秘密情報は、コアがゼロで消去するバイトバッファとして境界を越える。秘密情報を Swift の `String` に変換することはしない。

## 7. macOS の UI

- サイドバー、space のページング、favorites のグリッド、リストの行、dock、command bar、Little window、ウィンドウの chrome、ツールチップには AppKit を用いる。行は layer を基盤とするビューであり、キーごとに再利用する。space のページングでは layer だけを移動する（Cra ledger 12、4）。
- 設定とオンボーディングには、`NSHostingView` 内の SwiftUI を用いる。
- 動きとサイズの値は、オーナーの機器で計測した Arc の値とする（`docs/research/arc-ardia-observed.ja.md`）。フローティングサイドバーは、response およそ 0.15 s、damping およそ 0.84 の spring で現れ（5 pt の inset）、およそ 90 ms の ease-out で隠れる。components note 5 はこの spring を 0.185 s と 0.77 とするが、計測への当てはまりはこちらの方が悪い。Arc の値のうち、ドックしたサイドバーの表示と非表示（⌘S。Cra が記録した Arc の非表示は 100 ms の ease-out cubic である。components note 5）、切り替えの間の space の滑り、タブを開く・閉じる動きは、該当する部分を作る前に同じ probe で計測する必要がある。components note 5 の Dia の値は使わない。
- サイドバーの上のスクロールによる space の切り替えは、計測した Arc の振る舞いとする（`docs/research/arc-ardia-observed.ja.md` の 5 節。オーナーの選択、2026-10-31）。トラックパッドのジェスチャー（began から ended までのスクロールのフェーズと、それに続く慣性）は、最大で 1 つの space を切り替える。ホイールの入力にはフェーズが無いため、1 つの space を切り替えた後、およそ 300 ms のあいだホイールの入力を無視する。向き: `scrollingDeltaX` を取り、ホイールのイベント（フェーズが無いもの）では `isDirectionInvertedFromDevice` が立っているときに符号を反転する。値が負なら次の space へ進む。トラックパッドのイベントは符号をそのまま使う。そのため、ナチュラルなスクロールのもとでは、Arc と同じく、同じ向きの手の動きでもトラックボールとトラックパッドで逆に動く。未計測: 最初の切り替えを始める入力の量と、300 ms を切り替えから数えるのか最初のイベントから数えるのか。
- フローティングサイドバーは、計測した Arc の挙動に従う（`docs/research/arc-ardia-observed.ja.md`。オーナーの選択、2026-10-31）。サイドバーは、ポインタがウィンドウの左端から 5 pt 以内またはウィンドウの左外側におよそ 150 ms とどまった後に現れ、動き始めてからおよそ 110 ms で全幅に達し、およそ 1% 行き過ぎる（上記の動きの値のフローティングサイドバーの spring）。ポインタがウィンドウの左外側にある間は、ウィンドウの左端からおよそ 250 pt までは表示を維持する。この限界はウィンドウの幅で変わらなかった。サイドバーは、ポインタがウィンドウからおよそ 250 pt より左へ離れたとき、ウィンドウ内でもウィンドウの右端より右でもサイドバーの端からおよそ 72 pt より右へ移動したとき、またはウィンドウの上へ出たときに、およそ 90 ms で減速しながら隠れる。ウィンドウ内では tracking area を用いる。ウィンドウの外では tracking area は何も報告しないため、アプリがアクティブな間はウィンドウの外でもポインタを追う。サイドバーが隠れている間は、ローカルとグローバルの mouse-moved の `NSEvent` の監視（Yab の `LightsRow` と同じ）で左端の領域ととどまる時間のタイマーを動かし、ポインタが領域を出たらタイマーを取り消す。サイドバーの表示中は、ポインタの位置（`NSEvent.mouseLocation`）をディスプレイのリフレッシュレートでサンプリングする。対象はキーウィンドウのサイドバーだけである。Arc と同じく、アプリが非アクティブになったときにサイドバーを隠し、どちらの追跡も止める。Yab の異なる値は `docs/research/yab-observed.ja.md` にある。
- テーマ: Arc の `blendedGradient`（2 つの基調色、オーバーレイの色、ノイズと強度、類似色または補色の色相環、ライトまたはダークの半透明）を、`NSVisualEffectView` とグラデーションの layer に対応付ける。非公開 API の `CABackdropLayer` は、計測した差がその使用を正当化しない限り使用しない（Cra ledger 34）。
- 設定ウィンドウ: unified toolbar を持つ `NSSplitViewController` とし、各ペインは SwiftUI で実装する。1 つのウィンドウにすべての space の設定を置き（Yab の Spaces のペインと同じ）、space から設定を開いたときは、そのウィンドウでその space の設定を開く（オーナーの選択、2026-10-31）。space の間をスライドしたときに space ごとの設定がどう切り替わるかは、まだモックで決める（14）。
- 拡張機能は、設定ウィンドウの Extensions のペインからプロファイルごとに追加・管理する。Arc に入っていて未導入の拡張機能を一覧して追加する経路を持つ（Yab と同じ。オーナーの選択、2026-10-31）。このペインは §9 のインポートの規則に従う。

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
- 削除: デバイスを削除すると、新しいランダムな epoch の秘密から新しい epoch を開始する。この秘密は、削除の操作をしたデバイスが残りの各デバイスの鍵で封緘して送り、group secret だけからは導かない。そのため、削除されたデバイスは新しい鍵を導けない。古い epoch の relay の credential は失効させ、membership のレコードからそのデバイスを外し、残りのデバイスは新しい epoch のもとでスナップショットを封緘し直す。削除ではグループ秘密も置き換える。オーナーには新しい recovery phrase を示し、古いフレーズではグループに参加できなくなる。フレーズでの参加には現在のグループ秘密が要るからである。各 epoch の秘密は、現在のグループ秘密から導いた復旧用の鍵で封緘して relay にも置く。そのため、残る端末が無くても、現在のフレーズだけで現在の鍵を取り戻せる。グループ秘密を先に置き換えるので、削除された端末はそれを開けない。
- 最初のリリースからの復元の安全性: バックアップから復元したデバイスは新しい incarnation を得て、incarnation やシーケンス番号を再利用しない。

### 8.3 データの経路

- 各デバイスは追記だけを行う: シーケンス番号付きのデバイスごとのログと、version vector 付きの定期的なスナップショット。どのデバイスも他のデバイスの blob を書き換えない。
- merge は、ハイブリッド論理時計に基づくレコードごとの last-writer-wins とし、merge の後に 6.1 のツリーの規則を適用する。
- blob は 1 KiB 単位にパディングし、圧縮しない。
- ローカルのジャーナルは、アップロードの前に、workspace の変更と同じトランザクションで書き込む（5.2）。
- tombstone（削除を表す記録）は、デバイスの退役、epoch、長期間不在だったデバイスに対するスナップショットによる再参加の義務付けが実装されるまで無期限に保持する。これらが実装されて初めて回収を許可する（Ardia ledger 3 は、取り消した試みから判明した要件を列挙している）。
- 新しいレコードの種類は、古いバージョンが読み取らず、そのまま保持するキーのもとに追加する。これにより、古いクライアントが新しいレコードを損なった状態で書き戻すことはない。iPhone のクライアントは、使用できないレコードの種類（たとえば拡張）も保持する。

### 8.4 同期の対象

workspace、Air Traffic Control の規則、キーバインド、設定、パスワード、Web Store の拡張を同期する。パスワード: エンジンはレコードをゼロで消去するバッファとしてコアに渡し、コアがそれを封緘する。平文がブラウザプロセスの外に出ることも、UI のレイヤーに届くこともない。拡張は、バージョンと権限が承認済みのものと一致する場合にだけ、別のデバイスで有効にする（Ardia ledger 1.5）。履歴の同期は後で対応する。

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
- CI では署名のフェーズをビルドのフェーズから分離する。action はコミットの SHA で固定する。
- すべてのリリースに Corresponding Source を付ける（4.7）。
- Windows と Linux のアップデーターは、それぞれの phase で決定する。

## 13. 開発プロセス

設計または実装の各作業単位は次の順で進める: Opus 5.5 が設計と実装を行い（effort medium）→ Codex `gpt-6.1-sol` がレビューだけを行い（effort medium、labteam アカウント）→ Opus 5.5 が指摘ごとに修正するか否かを判定し、修正を差し戻す。タスクは orca-agent-team の席で実行してよい。レビューと判定は `docs/reviews/` に保存する。

## 14. オーナーが決める未決の事項

| 項目 | 選択肢 | 現時点の方向 |
|---|---|---|
| space の間をスライドすると切り替わる space ごとの設定 | オーナーの設計。入力: space のヘッダーから行う Arc の space ごとのテーマ / プロファイルの編集、Dia の設定ウィンドウ、Yab の設定（`docs/research/yab-observed.ja.md`）。決まっていること: すべての space を 1 つのウィンドウに置き、今の space の設定から開く（7） | まずモックを作り、その後に決定する |
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
| 2 | Mac Studio 上のエンジンのビルド基盤: Xcode、固定した Chromium、両方のベース候補の一覧作成、GN args、ロック、初回ビルドとインクリメンタルビルドの計測、`series check`、ベースの決定 | 独自のスクリプトによる、選んだベースの標準ビルド。ベースの決定を記録済み |
| 3 | 縦断スライスの spike: コアの coordinator と最小限のサイドバーを備えた `//ararat/core` を、署名済みのアプリ（bundle id、team、entitlement、ヘルパーの署名）で動かす。受け入れ条件（非表示と表示あり）: 1 つのウィンドウ内の 2 つのプロファイルと拡張から見たウィンドウの意味論、すべての生成経路によるポップアップ、拒否を含む autofill・passkey・権限のプロンプト、外部プロトコルの確認、フルスクリーンの解除、ドッキングした DevTools、ポップアップ付きの MV3 拡張、Chromium が run loop を所有した状態での正常な終了とキャンセルされた終了、ウィンドウ間のページの移動と 2 ペインの split、compositor の計測と決定、⌘L の後の IME と貼り付け、クラッシュと再起動の照合、1 回の練習のリベース。責務の表（4.6）を完成させる | すべての受け入れ条件の検査が通る。compositor のモデルを選定済み |
| 4 | UI の構築: 完全なサイドバー、favorites、フォルダ、space のページング、Arc の規則によるフローティングサイドバー、テーマ、Chromium の autocomplete を用いた command bar | オーナーが Arc のレイアウトでブラウジングできる |
| 5 | Little window、既定のハンドラーとしての Air Traffic Control、split view、archive、ダウンロード、セッションの復元 | 日常の使用において Arc のワークフローと同等 |
| 6 | 配布とセキュリティの関門: Developer ID、notarization、Sparkle、CI での署名、Corresponding Source、4.9 の保守のジョブ、評判の検査。DRM を決定し、ページの API を凍結する | 自己更新する署名済みのビルド。オーナーが日常的な使用を開始する |
| 7 | 設定（オーナーによる space ごとの設計を含む）、パスワード・cookie・拡張のインポート、キーバインド | オーナーが Arc から移行する |
| 8 | 同期: レビュー済みのプロトコル仕様、クライアント、リレーサーバー | 2 台の Mac がアカウントなしで同期する。オフラインからの復帰、削除、復元のテストが通る |
| 9 | Windows: 同一のエンジンのレイヤーとコアの上に Views の UI を置く | space と同期を備えた Windows のビルド |
| 10 | Linux: Views の UI、Wayland と X11 | space と同期を備えた Linux のビルド |
| 11 | iPhone: コアと同期を備えた WKWebView のアプリ | iPhone に同期された workspace |

Cra はオープンソースであるため、Cra の挙動はソースから読み取る。Cra のバイナリに REA を実行しても、コードから得られる以上の情報は得られない。REA は Yab に対して使用する（phase 1）。使用は 2026-09-30 付の Yab の利用規約の範囲内で行う。この利用規約はあらゆる合法的な利用を認めており、解析を禁じる条項を含まない。
