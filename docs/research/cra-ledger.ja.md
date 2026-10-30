# Cra の設計判断の台帳（2026-10-30 時点）

対象: https://github.com/VictorKildahl/cra （MIT、HEAD = 37a87aad、2026-10-29）。初回 commit は 2026-10-24（fac5c687）であり、履歴は commit 40 件、リリースは Cra 0.1.0〜0.1.19 と CEF のビルド 4 件である。5 日間で設計が数回入れ替わっている。

読み方の注意:

- 根拠の「`path:行`」は HEAD のファイルの行番号である。`arc-RE` は `docs/arc-reverse-engineering.md` を指す。
- 「新ブラウザ」は、Chromium を fork して自前の層を tree 内に置く（ArcCore 方式）、UI は Swift/AppKit、中核は Rust、の前提で評価した。
- 用語: Alloy style = CEF の埋め込み用の実行形態（Chrome の UI を持たない）。Chrome style = CEF の中で Chrome 本体の Browser・Views を使う実行形態（拡張機能と Chrome の DevTools が動く）。

## 1. 構成図

### SwiftPM のターゲット（`Package.swift`）

| ターゲット | 種類 | 言語 | 依存 | 役割 |
|---|---|---|---|---|
| `Cra` | executable | Swift | `CraCEF`、Sparkle（vendor/sparkle、`-F` で直接リンク） | アプリ本体。AppKit の window・サイドバー・コマンドバー、状態、取り込み、更新 |
| `CraCEF` | library | Objective-C++（C++20、`-fno-rtti -fno-exceptions`） | `libcef_dll_wrapper`（vendor/cef を CMake でビルド）、AppKit、IOSurface | Swift と CEF の境界。公開 API は `Sources/CraCEF/include/CraCEF.h` の 4 クラスと 1 protocol だけ |
| `CraHelper` | executable | C++ | `libcef_dll_wrapper` | Chromium の子プロセス（renderer・GPU・utility）。`CefScopedSandboxContext` で sandbox に入ってから framework を読む（`Sources/CraHelper/main.cc:9-20`）。build.sh が 5 個の Helper.app に複製する |
| `CraDockTile` | dynamic library | Swift | AppKit | Dock tile plug-in。終了後も Dock のアイコンを保つ（d1a43cb5） |

依存の向きは `Cra → CraCEF → CEF(libcef)` の一方向である。`Cra` は `CraCEF.h` の型（`CraBrowser`、`CraBrowserDelegate`、`CraCEFRuntime`、`CraApplication`）しか見ない。CEF の C++ 型は Swift に出てこない。

### `CraCEF.h` の境界（Swift から見える面）

- `CraBrowser`（タブ 1 つ分の Chromium browser）: 生成（URL、incognito、profilePath）、遷移、検索、ズーム、DevTools、PiP、`sendDevToolsMethod`（タブ単位の CDP）、`containerView`（Alloy 用）と `hostWindow`（Chrome style 用）の 2 つの置き場所（`CraCEF.h:86-169`）。
- `CraBrowserDelegate`: タイトル・URL・読み込み・favicon・テーマ色・背景色・全画面・新規タブ要求・popup の受け皿・DevTools の配置・キー（予約キーと未処理キー）・ダウンロード・権限要求（`CraCEF.h:27-84`）。
- `CraCEFRuntime`（プロセス全体）: 初期化、run loop、Chrome style の切り替え、自前のコンテキストメニュー、広告ブロック、HTTPS-Only、多重起動の受け渡し、「迷子のページ」（拡張機能が開いたタブ）の受け皿、ブラウザ単位の CDP pipe、プロファイルの cookie を使った fetch（`CraCEF.h:171-248`）。
- `CraApplication`: CEF が要求する `NSApplication` のサブクラス。⌘ キーの振り分けと accessibility の window の差し替えもここで行う（`CraCEF.mm:2093-2175`）。

### `Sources/Cra` の中の層

| 層 | 主なファイル | 依存先 |
|---|---|---|
| App | `App/main.swift`（起動順序）、`App/AppDelegate.swift`（cra:// の受け口、外部リンクの振り分け、window の管理）、`App/KeyBindings.swift`、`App/NewestCopy.swift` | UI・Services・Model |
| UI | `UI/ShellView.swift`（window の content view）、`UI/Windows/*`（MainWindowController、LittleWindowController、Chromium の window への手当て）、`UI/Sidebar/List/*`（AppKit のサイドバー）、`UI/SplitView/*`、`UI/CommandBar/*`、`UI/Settings/*`（SwiftUI）、`UI/Onboarding/*`（SwiftUI） | Services・Model・CraCEF（`CraBrowser.hostWindow` を直接扱う） |
| Services | `SidebarStore`（唯一の状態の正本）、`BrowserManager`（タブ ⇔ CraBrowser）、`Persistence`（JSONStore）、`Import/*`、`ExtensionStore`・`ExtensionActions`、`LiveFolderManager`・`GitHubLiveClient`、`SuggestionEngine`、`SoftwareUpdater`、`SafeStorage` | Model・CraCEF |
| Model | `SidebarModel.swift`（Space・SidebarItem・ArchivedItem・AppSettings・WindowSession）、`LinkRouting.swift`（ATC）、`LiveFolderModel.swift` | Foundation のみ |

### 機能ごとのファイル

| 機能 | ファイルと役割 |
|---|---|
| window | `UI/Windows/MainWindowController.swift`（2,000 行超。タブ・split・DevTools・ページ window の貼り付け・コマンドバー・検索）、`CraWindow`（同ファイル 2036 行〜、背景ドラッグの抑止） |
| サイドバー | `UI/Sidebar/List/SidebarView.swift`（列全体、上段のバー、`SpaceDockView`）、`SpacePagerView.swift`（space の横送り）、`SpaceColumnView.swift`（favorites・見出し・リスト）、`SpaceListView.swift`（pinned と Today のリスト）、`SidebarRowViews.swift`、`SidebarListDrop.swift`、`UI/SidebarUIState.swift`（一時状態） |
| 浮くサイドバー | `UI/Windows/FloatingSidebar.swift` |
| space | Model の `Space`（`SidebarModel.swift:268`）、`UI/Windows/SpaceEditorView.swift`、`SpaceDockView`（`SidebarView.swift:503`） |
| Little Windows | `UI/Windows/LittleWindowController.swift`（サイドバーの無い小窓、⌘O で space へ昇格 `promote(to:)` 485 行） |
| ATC（routes） | `Model/LinkRouting.swift`（照合規則）、`UI/Settings/AirTrafficControlView.swift`（編集画面）、`AppDelegate.openExternalURL` |
| 取り込み | `Services/Import/Importers.swift`（Arc・Dia を中立な `ImportPlan` に変換）、`ChromiumImporter`・`FirefoxImporter`・`ZenImporter`・`SafariImporter`、`CredentialImport.swift`（パスワードと cookie を再暗号化して次回起動時に書き込む）、`ExtensionImporter.swift` |
| 永続化 | `Services/Persistence.swift`（`JSONStore<T>`）。ファイルは sidebar.json、archive.json、windows.json、settings.json、history.json、commandbar.json（`SidebarStore.swift:45-50`）、keybindings.json、downloads.json |

## 2. 判断の台帳

| # | 判断 | 理由 | 退けた代替案 | 根拠 | 新ブラウザへの適用 |
|---|---|---|---|---|---|
| 1 | ページの置き方は 3 通りを持つ。既定は Chrome style の Views（frameless な `CefWindow` に `CefBrowserView`、Chrome の toolbar は `CEF_CTT_NORMAL` で作って非表示）を 1 タブ 1 window で作り、その中の `WebContentsViewCocoa` と `ViewsCompositorSuperview` を Cra の card に移す | CEF 154/156 の Alloy style には拡張機能の API が無い。Chrome style は macOS では Views の window の中にしか作れない。toolbar は拡張機能の popup の anchor として要り、無いと `Extensions.triggerAction` が落ちる | Alloy の `SetAsChild`（`chromeEngine` を切ると今も使える）、`CRA_CHROME_STYLE=1` の `SetAsChild` + Chrome runtime（実験用） | `CraCEF.mm:1357-1421`、`CraCEF.mm:1500-1520`、`SidebarModel.swift:428`、`AppDelegate.swift:47-48`、arc-RE 213-219, 410-424 | 採らない。fork なら Chromium の `content::WebContents` の NSView を直接 shell に持てる。Arc 自身もそうしている（arc-RE 14, 232） |
| 2 | ページを子 window で重ねる方式（0.1.0〜0.1.16）から、card への埋め込み（0.1.17 既定）へ移した | 1 つの window と 1 つの Core Animation の木にすると、ページが card と一緒に動き、アニメーションし、キーが別 window を key にせず届く。計測でタブ切り替えの停止が 89 → 62 ms | 子 window の方式（`CRA_EMBED_PAGES=0` で残る） | a1c6c33e（実験として追加）、3aae97c3（既定化）、`UI/Windows/EmbeddedPages.swift:4-20` | 採る（考え方）。ページは shell の view 階層の中に置く。fork では前提として最初からそうなる |
| 3 | ページの主 window は残すが、空にして click-through、key にも main にもならないようにする | Chromium のメニュー・popup・レイアウトが画面座標を主 window から取る。alpha 0 にすると Chrome のコンテキストメニューが出ない | window を捨てる、alpha 0 にする | `EmbeddedPages.swift:9-12, 27-33, 71-85` | 採らない。fork では不要（§3） |
| 4 | DevTools は 3 段階で変遷した。CEF 154 で `SetAsChild` の DevTools が CHECK で落ちる → 非表示の Alloy の window を子 window として重ねる → docked の frontend（`can_dock=true`）が 2 回目の遷移で接続を失う → undocked の frontend に閉じるボタンを注入 → 最終的に Chrome style の DevTools を `can_dock=true` で再読み込みし、`setInspectedPageBounds` と `setIsDocked` を console message で shell に写し、shell がページを placeholder の上に置く | Arc は Chrome の DevToolsWindow をそのまま使っている（ArcCore に `can_dock=true`、`setInspectedPageBounds` がある）。同じ振る舞いを CEF の外から再現するため | DevTools の NSView を Cra の window へ移す（CEF が DevTools を閉じるとき `view.window` を閉じるため危険） | arc-RE 171-179, 191-201, 626-662、`CraCEF.mm:1334-1355`、`MainWindowController.swift:918, 1070` | 採らない（方式）。fork では Chrome の `DevToolsWindow` の docking をそのまま使える |
| 5 | Chromium の engine を自前でビルドする（Spotify の配布する CEF から、同じ commit の自前ビルドへ） | Spotify の CEF は H.264/AAC を含まず、X・Instagram・Reddit の動画が再生できない。codec はコンパイル時の設定である | Spotify の CEF をそのまま使う（`CEF_URL` で今も切り替えられる） | 5d10ea59、`scripts/build-cef.sh:1-16`、`docs/release.md:189-210` | 採る（前提として同じ）。fork はどのみち自前ビルドであり、`proprietary_codecs=true ffmpeg_branding=Chrome` を最初から入れる |
| 6 | Chromium の版上げを毎日検知し、ビルドは手元の Mac で行う | Chromium は最新版にしかセキュリティ修正を出さない。GitHub の無料の macOS runner は小さすぎ、大きい runner は有料 | CI でビルドする | 65eb6edf、`.github/workflows/cef-updates.yml`、`docs/release.md:211-219` | 採る（検知の部分）。ビルドの置き場所は要検討（fork はビルド量がさらに大きい） |
| 7 | CEF に当てるパッチは `scripts/cef-patches/` に置き、少数に保つ（現在 6 件） | 全パッチを版上げのたびに運ぶ必要がある。新しいパッチは maintainer が合意してから足す | パッチを増やして CEF の挙動を広く変える | `CONTRIBUTING.md`「Chromium and CEF」、`scripts/cef-patches/*.patch` | 採る（運用）。fork でも上流との差分を最小の単位で管理する |
| 8 | 拡張機能のツールバー操作は、ブラウザ単位の DevTools Protocol を private な pipe（fd 3/4、`--remote-debugging-pipe`）で張り、`Extensions.triggerAction` で実行する | CEF には拡張機能のツールバーを操作する API が無い。`triggerAction` は信頼された CDP の client を要求する | port を開ける `--remote-debugging-port`（他プロセスから届く） | `CraCEF.mm:245-320, 484-490`、`Services/ExtensionActions.swift:4-8` | 採らない。fork では拡張機能の API を Chromium の内部から直接呼ぶ |
| 8b | 拡張機能の読み込みは 2 経路にする。(a) `<data>/Extensions/<id>` の unpacked フォルダを起動時に `--load-extension` で渡す。(b) Web Store からのインストールは Chrome が profile に置き、Chrome が管理する。Arc・Dia から取り込んだ拡張機能は manifest の `key` を残して unpacked で複製し、ID を変えない。toolbar に並べる順は、乗り換え元のブラウザの `extensions.pinned_extensions` から初期化する | CEF の Chrome style でしか拡張機能が動かない。ID を保てば拡張機能の保存データと native messaging の許可が引き継がれる | — | `CraCEF.mm:457-467`、`Services/ExtensionStore.swift:5-7, 25-26, 56, 112-113`、`Services/Import/ExtensionImporter.swift:4-6`、arc-RE 917 | 要検討。ID を保つ取り込みと pinned の順の初期化は採る。`--load-extension` の経路は、fork では Chrome の ExtensionService に直接登録する形に置き換える |
| 9 | 拡張機能の popup は Chrome 本物の bubble を残し、Cra の枠 window（`ExtensionPopupWindow`）で包んでボタンの下に吊る。ドラッグした位置はボタンからの相対位置で覚える | popup を本物の extension popup のまま保つ（activeTab の付与、入力先のタブ）。絶対座標で覚えると画面やウィンドウの移動で「ばらばらの場所」に出た | 絶対座標で覚える（0.1.17 まで）、ポインタ位置 + 17 pt に置く | 5f4c901f（#8）、37a87aad、`UI/Windows/ExtensionPopupWindow.swift:4-30, 154-163` | 要検討。ボタンからの相対位置で覚える規則は採る。包み方は fork なら Chrome の `ExtensionPopup` を自前の anchor に付けるだけで済む |
| 10 | 拡張機能が作る popup 型の window（`windows.create({type:"popup"})`）は Chrome の window のまま残し、それ以外の Chromium が勝手に開くページは Cra のタブに変える | 1Password などが window の id、`windows.getCurrent().type` を前提にしている | すべて Cra のタブにする（以前の挙動） | c5b7f46a、`CraCEF.mm:195-243`、arc-RE 1355-1360 | 採る（規則）。Arc の `BrowserType {normal, popup, pictureInPicture}` と同じ区別を Rust の中核の window 種別に持たせる |
| 11 | ページの shortcut は Chrome の規則に従う。⌘ キーはまずページへ渡し、ページが処理しなかったものだけメニューに戻す。予約キーは `OnPreKeyEvent` で先に取る | ⌘F（Google Docs）、テキスト欄の ⌘← が動くようにするため | Cra が先にすべての ⌘ キーを取る | `CraCEF.mm:2121-2155`、`CraCEF.h:58-62`、README「Keyboard」 | 採る（規則）。実装は fork なら Chrome の `CommandDispatcher` 相当を shell 側に持つ |
| 12 | サイドバー・コマンドバー・ツールバーを SwiftUI から AppKit に書き直した。行は layer-backed な view を key で再利用し、画面の近くだけ実体化する。space の横送りは layer の translation だけで行う | 計測（main thread の busy ms）で space の swipe 1900 → 440、サイドバーのスクロール 930 → 416。Arc 自身も AppKit（NSCollectionView 等）で組んでいる | SwiftUI のまま最適化する（0.1.16 の ItemTable、0.1.17 のツールチップ修正までは SwiftUI で詰めた） | 5f4c901f、3aae97c3、a1c6c33e、`UI/Sidebar/List/SpacePagerView.swift` 冒頭、`SpaceListView.swift` 冒頭 | 採る。頻繁に動く部分（サイドバー・ページ送り・コマンドバー）は最初から AppKit で書く。設定画面・オンボーディングは SwiftUI のままでよい（Cra もそうしている） |
| 13 | main thread の停止を計測する仕組み（`CRA_HITCH_LOG`）と、ポインタを使わずに操作する cra:// の command file を先に作り、版ごとに同じ台本で比べる | main thread は Chromium の browser UI thread でもあり、停止は入力とスクロールも止める | 体感で判断する | a1c6c33e、`Services/HitchMonitor.swift`、`docs/development.md`「Running a test instance」 | 採る。Chromium の fork でも UI thread は共有されるので、計測の仕組みを最初の版から入れる |
| 14 | 状態の正本は `SidebarStore` 1 つにし、Arc の Storable*.json の形（space が favorites・pinned・Today の 3 つの container を持ち、item は id の木と明示の子の順序）を写す | Arc の取り込みをそのまま載せ、Arc の挙動（pinned tab の home URL、archive の理由）を再現するため | 独自の形 | `Model/SidebarModel.swift:1-6, 10-60, 291-310`、`Services/SidebarStore.swift` 冒頭、arc-RE 17-55 | 採る（形）。Rust の中核のデータモデルの出発点として妥当。split も Arc と同じく folder 型の item（`SplitData`）として持つ（`SidebarModel.swift:90`） |
| 15 | favorites は space ごとに持つ（Arc は profile ごとに共有） | 読み取れる理由の記述は commit の「Favorites belong to each space」のみ。保存済みのファイルは読み込み時に移行し、表示中の space が共有分を受け継ぎ、他の space は複製を得る | Arc と同じ profile 共有（初版） | a0572f5e、`SidebarModel.swift:5-6, 21-23` | 要検討（製品の判断）。移行を読み込み時に行う手順は参考になるが、新ブラウザは後方互換を持たないので初めから決める |
| 16 | 永続化は種類ごとの JSON ファイル（`JSONStore<T>`）。0.4 秒の debounce、専用の serial queue で encode と書き込み、atomic な書き込み、直前の版を `.bak` に 1 つ残す、壊れたファイルは `.corrupt` に退避して空から始める | 2,000 件の archive.json の encode が main thread で約 30 ms かかり、タブ切り替えのたびに 2〜4 フレーム落ちていた。Arc のタイムスタンプ付きの複製が溜まる問題は避ける | main thread で書く（0.1.15 まで） | a1c6c33e、`Services/Persistence.swift:45-102` | 要検討。atomic 書き込み・`.bak`・`.corrupt` 退避・off-main の規則は採る。形式は Rust の中核なら SQLite も候補（archive と history は件数が伸びる） |
| 17 | pinned と Today を 1 つのリストにする（pinned を固定表示にしない） | Arc も 1 つの outline で、固定の group row は無い。長い pinned は space 名からの折りたたみで逃がす | pinned と Today を別々のスクロールに分ける（試して捨てた） | arc-RE 734-739 | 採る |
| 18 | Library を独立した window からサイドバーのモードに変えた | 別 window だと他をクリックしたときブラウザの裏に隠れた（#3） | `ArchiveView` の window | 992776f8、arc-RE 1518-1550 | 採る |
| 19 | 同じタブを 2 つの window で開いたとき、使っている window がページを持ち、もう一方は最後のスナップショットをぼかして見せ、key になったらページを取り返す | 1 つのページは 1 つの場所にしか置けない。Arc も reparenting と blurred placeholder で同じことをしている | 片方の選択を外す（以前の挙動、#4） | 992776f8、arc-RE 1551-1568、`UI/SplitView/PaneCardView.swift`（`elsewhereSnapshot`） | 採る |
| 20 | window を閉じても、別の window が見ていたページは再読み込みせず移す。最後の通常 window は閉じずに隠す | タブを window 間で動かしても状態を失わないため | 閉じた window のページを捨てる | 24d50210、a1c6c33e | 採る |
| 21 | split view は Arc の `SplitViewController` を写した純粋なレイアウト関数（`widthFactor × (container − gaps)`、最小幅で clamp、pixel snap）。ドラッグ中はページの大きさを固定して位置だけ動かし、離したときに 1 回だけ resize する | Chromium の resize は同期のレイアウトであり、毎フレーム行うと重い。Arc も `lockContentWidth` と throttle で同じことをしている | `NSSplitView`（Arc も使っていない） | arc-RE 284-323, 392-409、`UI/SplitView/SplitPaneLayout.swift` 冒頭、`PaneCardView.swift:39, 130`、`ShellView.swift:316-321` | 採る。レイアウト関数は Rust の中核にも置ける（平台に依存しない） |
| 22 | Air Traffic Control は Arc の照合規則を実測して写す（大小文字・scheme・先頭の `www.` を落とす、「Contains」は query と fragment も見る、「Is equal to」は host と path だけ、上から順に最初の一致） | Arc の routes を取り込んでそのまま動かすため | 独自の照合規則 | c5b7f46a、`Model/LinkRouting.swift` 冒頭、arc-RE 1276-1325 | 採る。平台に依存しないので Rust の中核へ移す第一候補 |
| 23 | Little Windows は「他のアプリからのリンクの既定の行き先」として実装し、⌘O で live の browser ごと space の Today に移す。閉じたら archive に入る | Arc の Little Arc と同じ。「Little Arc で開く」の設定は ATC の default destination そのもの | 別の設定として持つ | `UI/Windows/LittleWindowController.swift:1-14, 485`、arc-RE 1300-1301, 464-471 | 採る |
| 24 | cookie とパスワードの暗号鍵を Cra 専用の Keychain 項目（"Cra Safe Storage"）に置き、旧版の mock keychain で暗号化した値は初回起動時に Chromium が開く前に再暗号化する | `--use-mock-keychain` では公開された定数 "mock_password" で暗号化され、profile を読める者は誰でも復号できた（外部からの報告） | mock keychain（初版から 0.1.10 まで）、全 Chromium 系アプリが共有する "Chromium Safe Storage" | 24d50210、`Services/SafeStorage.swift` 冒頭、`scripts/cef-patches/keychain-service-name.patch`、`App/main.swift:24-26` | 採る。fork では branding の設定で自前の service 名にし、最初から Keychain を使う |
| 25 | 子プロセスを macOS の sandbox に入れる | Chrome と同じ保護を得るため（#5） | `no_sandbox`（0.1.13 まで） | 992776f8、`Sources/CraHelper/main.cc:9-14` | 採る（前提） |
| 26 | 広告とトラッカーの遮断は同梱のドメインリスト（AdAway と Anudeep、計 22,510 件）を `OnBeforeResourceLoad` で照合し、第三者の subresource と subframe だけ止める | MIT のアプリに同梱できるライセンスのリストに限った。照合は lock-free（atomic pointer の後ろの不変集合） | EasyList/EasyPrivacy（GPL・CC BY-SA）、DuckDuckGo Tracker Radar（非商用）、hagezi・Disconnect（GPL）、StevenBlack（非商用のソースを含む） | arc-RE 1067-1095、`Sources/CraCEF/CraContentBlocker.h` | 要検討。ライセンスの選別は参考になる。fork なら Chromium の subresource filter に載せる選択肢がある |
| 27 | WebRTC は、当初「mDNS を残して Local Network の確認に説明文を付ける」としたが、同日中に「mDNS を切り、`webrtc.ip_handling_policy = default_public_interface_only` にして local IP を一切出さない」に変えた | 前者: mDNS を切るとページに本当の local IP を渡してしまう。後者: public interface だけにすれば告知するものが無くなり、確認自体が出ない | 前者の方式（dc7fb65b） | dc7fb65b → c5b7f46a、`CraCEF.mm:338-348, 470-477` | 採る（後者）。Chromium の挙動なので fork でも同じ判断が要る |
| 28 | 業務のシングルサインオンのため、Chrome・Edge の管理ポリシー（`AuthServerAllowlist`）を読んで `--auth-server-allowlist` に渡す。Basic・NTLM の認証エラーは自前のエラーページで潰さず Chrome に任せる | CEF は Chrome の enterprise policy を読まない | 何もしない | 64c8a17b、`CraCEF.mm:322-336, 480-483` | 要検討。fork では Chrome の policy の仕組みが動くので、どの policy domain を読むか（自前の bundle id か Chrome のものか）を決める |
| 29 | 拡張機能の native messaging host は、他のブラウザに入っている manifest を Cra の profile に symlink する。ただし ChatGPT の computer use のように「Chrome を操作する」host は除く | アプリは自分の知っているブラウザにしか manifest を入れない。symlink ならアプリの更新に追従する。除外しないと ChatGPT が Chrome の代わりに Cra を操作した | 複製、何もしない | c5b7f46a、`Services/NativeMessagingHosts.swift:3-37` | 採る。自前の bundle id を持つ fork でも同じ問題が起きる |
| 30 | 更新は Arc と同じく Sparkle 2（EdDSA 署名の appcast、8 時間ごとの確認、裏でのダウンロード）にし、ユーザーが離れているときに再起動する。ダウンロード・ダイアログ・Little Window・PiP・メディア再生中は待つ | Arc の振る舞いを写す | — | 12fa95ef、arc-RE 1227-1275、`Services/SoftwareUpdater.swift` | 要検討。macOS では採れる。Windows・Linux では別の仕組みが要る |
| 31 | 古い版が新しい版の代わりに動かないようにする（新しい版が起動したら古い版を終わらせる、古い install が新しい install を開いて終わる） | Chromium は profile を 1 プロセスに持たせ、後からの起動を既存のプロセスに渡すため、古い版が表示され続けた | — | 24d50210、`App/NewestCopy.swift` 冒頭、`App/main.swift:11-14` | 採る |
| 32 | アカウントとサーバ（Convex）を外し、すべてを手元の Mac に置く。AI 機能は入れない | 製品方針（「No account, no server, no telemetry」「No built-in AI」） | 初版にあった任意のアカウントと設定の同期 | fac5c687 → 9e224a7e、`CONTRIBUTING.md`「What fits」 | 要検討（製品の判断） |
| 33 | cra:// の scripting は、ページからは一切届かず、他のアプリからは `commandbar`・`dismiss`・http(s) の `open` だけにする。他は defaults か test instance の command file が要る | ページが cra:// を新しいタブで開いて scripting の命令（ローカルファイル、キー送信、CDP）を実行できた（外部からの報告） | すべての host を公開（0.1.10 まで） | 24d50210、`App/AppDelegate.swift:255, 408` | 採る。自動操作の口は「ページから届かない」を最初の条件にする |
| 34 | 外観は Arc の画面を pixel 単位で計測して合わせる。明るい vibrant テーマは system の material では Arc の値に届かないので、私的クラスの `CABackdropLayer` で untinted の blur を作り、暗い層と白い lift を重ねる | system の material はどれも色が付き、背景の透過に上限があり、Arc の切片と傾きを同時に満たせなかった | `NSVisualEffectView` の material だけで合わせる（暗いテーマとフォールバックに残す） | arc-RE 811-856, 120-160、`UI/ShellView.swift`（backdrop の説明）、`UI/Tuning.swift` | 要検討。私的 API は App Store の審査と OS の版上げで壊れる危険がある |
| 35 | タブのスリープは CDP の `Runtime.evaluate` でページの状態（入力中の文字、`beforeunload`、メディア、録画、PiP、DevTools）を調べてから unload する。既定は無効 | 消えてはいけない状態のタブを眠らせないため | — | 992776f8、`Services/BrowserManager.swift:282-300` | 採らない（方式）。fork では Chrome の tab discarding（Memory Saver）の判定を使える |
| 36 | 開発の手順として、UI を変えたリリースには clip を必須にし、Claude Code の PreToolUse hook で v* tag の push を止める | リリースノートに目に見える変更の clip を載せるため | — | 4444441a、`.claude/settings.json`、`scripts/clips/check-release-media.sh` | 要検討（運用） |

## 3. CEF が原因で生じた回避策の一覧（新ブラウザでは不要になるもの）

### 3.1 CEF が原因で、Chromium の fork なら不要になるもの

| 回避策 | 何を回避しているか | 根拠 |
|---|---|---|
| ページの主 window を空・click-through・非 key にする swizzle（`canBecomeKeyWindow`・`canBecomeMainWindow` の差し替え） | Chrome style の browser は CEF の window の中にしか作れない | `EmbeddedPages.swift:22-33, 71-85` |
| `ChromiumChildHover`（`RenderWidgetHostViewCocoa shouldIgnoreMouseEvent:` の差し替え） | 子 window のページと DevTools は、key でない側の hover が死ぬ | `UI/Windows/ChromiumChildHover.swift` |
| `ChromiumChildFullscreen`（`toggleFullScreen:` の差し替え） | 子 window のページが全画面になると macOS が別の Space を作り、Mission Control に空のデスクトップが残る | `UI/Windows/ChromiumChildFullscreen.swift`、24d50210 |
| `ChromiumWindowCorners`（NSThemeFrame の角の問い合わせの差し替え。SDK 15.5 でリンクすると別の `_cornerMask` が効くので、それも消す） | Chromium の frame view は NSThemeFrame 派生なので、borderless でも角が丸く切られる | `UI/Windows/ChromiumWindowCorners.swift`、059ef4b4 |
| content view を window 全体に広げ直す（`fillContentView`） | Chromium の frameless window は content view を上から 22 pt 下げる（隠れた title bar の分） | `MainWindowController.swift:968`、arc-RE 1400-1402, 652-655 |
| 非表示のタブの window の content view を `isHidden` にする | 画面外に出した window を Chromium は「見えている」と判断し、裏のタブが動画を自動再生し全速で動いた | `MainWindowController.swift`「Chrome-style page windows」節 |
| `FloatingSidebar` の子 panel と 1/30 秒のポインタ監視 | ページが shell の上の子 window なので、shell 内のサイドバーは隠れ、shell の tracking area は key window でしか動かない | `UI/Windows/FloatingSidebar.swift:6-10, 50-73` |
| `WindowDragGesture` の手動の window 移動 | 浮くサイドバーは子 panel なので、`performDrag` が panel を window から引き剥がす | `UI/Windows/WindowDragGesture.swift`、37a87aad |
| status bubble・toast・検索バーを click-through の panel と個別の小 panel に載せる | ページの子 window より上に描くため。page 大の panel がクリックを奪わないよう、押せる物は個別の panel に分けた | `MainWindowController.swift:582-660`、a0572f5e |
| Cra が描くページのコンテキストメニュー（`setOwnContextMenus`、`RunContextMenu`） | ページを card に移すと Chrome のメニューが出せない | `CraCEF.mm:76-77, 1135-1142`、3aae97c3 |
| ⌘ キーをページへ先に渡す `sendEvent` の振り分けと、⌘C/⌘V/⌘A を Edit メニューに戻す処理 | Cra の window には Chromium の `CommandDispatcher` が無い | `CraCEF.mm:2121-2155`、3aae97c3 |
| `accessibilityFocusedWindow`・`accessibilityMainWindow` を最上位の window に差し替え | Rectangle・Magnet・Raycast が key の子 window（ページ）を動かし、ページが card から外れた | `CraCEF.mm:2157-2170` |
| DevTools の docking の再現（`can_dock=true` で再読み込み、`setInspectedPageBounds`・`setIsDocked` を console message で shell に写す、補助 popup の遮断） | CEF 154/156 の DevTools は undock の popup しか出せない | arc-RE 626-662、`CraCEF.mm:605-810` |
| `--remote-debugging-pipe` と `--enable-unsafe-extension-debugging`、renderer への `AutomationControlled` の無効化 | 拡張機能の API が CEF に無く、CDP の `Extensions.triggerAction` を使う。pipe が renderer に `navigator.webdriver` を立て、Google のログインが拒否される | `CraCEF.mm:484-499` |
| 終了時に CDP の pipe を先に閉じる | pipe の client が繋がっている間 Chrome は終わらず、⌘Q が固まった | 5a3d36fa、`CraCEF.mm:313-320` |
| 非表示の Chrome toolbar（`CEF_CTT_NORMAL` で作って `SetVisible(false)`） | 拡張機能の popup の anchor が要る | `CraCEF.mm:1360-1365, 1410-1412` |
| `Target.setDiscoverTargets` で、Cra が開いていない popup（shortcut、`openPopup()`）を探して枠に入れる | popup が Chrome の隠れた toolbar（左から約 174 pt）に吊られる | `ExtensionActions.swift:34-37, 143-150`、arc-RE 1361-1364 |
| `StrayBrowserClient`（Chromium が勝手に開くページを Cra のタブに変え、Web Store の「拡張を追加しました」の空タブを閉じる） | CEF の default client が stock の Chrome window を開く | `CraCEF.mm:195-243`、5d10ea59 |
| `--no-startup-window`、`--disable-session-crashed-bubble`、`--hide-crash-restore-bubble`、起動前の `Default/Sessions` の削除と `exit_type` の書き換え | Chrome runtime が前回のセッションを stock の Chrome window で復元した | `CraCEF.mm:451-456, 1877-1895`、arc-RE 675-680 |
| `OnAlreadyRunningAppRelaunch` で後からの起動の URL を受ける | 受けないと CEF が stock の Chrome window を開く | `CraCEF.mm:502-520` |
| profile の読み込み完了まで browser の生成を待たせる | 読み込み中の profile では Chrome style の browser view が作れない（CEF が null を返す） | `CraCEF.mm:44-48` |
| ページの背景色を view の背景に入れ直す（`OnThemeChanged`） | CEF が Chrome の背景を隠し、renderer の最初のページが透明になる（chromiumembedded/cef#3891） | `CraCEF.mm:1367-1374` |
| タブを閉じてもダウンロード中なら about:blank に退避して隠し、終わってから閉じる | Chromium は開始した browser が閉じるとダウンロードを止める（CEF では 1 タブ = 1 Browser） | 059ef4b4 |
| Chrome のダウンロード bubble とダウンロード開始のアニメーションを消す | anchor にする toolbar が無く、透明な window が次のクリックを奪った | arc-RE 1404-1421、`UI/Windows/ChromeDownloadAnimation.swift` |
| `extensions-normal-windows.patch` | CEF は `CefBrowserView` をすべて `TYPE_POPUP` で作るので、拡張機能から見て全タブが popup window になり、`openPopup()` が失敗した | c5b7f46a、arc-RE 1343-1350 |
| `extension-popup-browser-info.patch` | 拡張機能の popup には CefBrowser が無く、renderer が 2 秒の timeout を待った | ca95b3b2 |
| `cors-origin-header.patch` | CEF の proxy URL loader が `chrome-extension://` の Origin を "null" にした | a0572f5e |
| `extension-install-ui-null-tab.patch` | 埋め込み側（CEF）の browser に active なタブが無く、Web Store からのインストールで落ちた | 5d10ea59 |
| `keychain-service-name.patch` と、パッチ前の版の framework をバイナリで書き換える `fetch-cef.sh`（定数領域の文字列と LTO で畳まれた長さ 21 を書き換え） | CEF の branding では Keychain の service 名を変えられない | 24d50210 |
| `webauthn-keychain-access-group.patch` | Chromium の branding に team ID が無く、Touch ID の passkey の keychain group を作れない | cda7e4bf |
| unpacked の拡張機能を `--load-extension` で渡し、フォルダの変更は再起動まで反映しない | CEF の外から拡張機能を登録する口が起動時の switch しか無い | `CraCEF.mm:457-467`、`ExtensionStore.swift:56` |
| `ExtensionProtocolReply`（CDP の呼び出しに 5 秒の期限を付ける） | renderer が閉じた後、CEF が返事をしないことがある | `Services/ExtensionProtocolReply.swift`、37a87aad |

### 3.2 Chromium が原因で、fork でも残るもの（参考）

- WebRTC の mDNS と Local Network の確認（台帳 27）。
- Bluetooth の 500 ms ごとの同期 XPC（`ChromiumBluetoothCache` は `IOBluetoothDevice` を swizzle している）。fork では swizzle ではなく Chromium のソースを直す形に変わる（`Services/ChromiumBluetoothCache.swift`、a1c6c33e）。
- 取り込んだ cookie の `has_cross_site_ancestor = 0` で Chromium の UPDATE・DELETE が一致しない問題（a0572f5e）。他のブラウザから cookie を取り込む限り残る。

### 3.3 CEF とは関係が無いもの（Cra 自身の判断や誤り）

- `--use-mock-keychain` で始めた誤り（台帳 24）。
- 動画の codec を入れるための自前ビルド（台帳 5）。fork ではビルド設定の 1 行であり、回避策ではない。
- native messaging host の symlink（台帳 29）。自前の bundle id を持つ限り残る。
- `AuthServerAllowlist` を Chrome・Edge の policy domain から読む処理（台帳 28）。CEF が policy を読まないことが発端だが、fork の policy の仕組みは自前の bundle id の domain を読むので、IT が Chrome 向けに配った設定を効かせるかは製品の判断として残る。

## 4. Swift/AppKit の UI として新ブラウザがそのまま参考にできる実装

| ファイル | 何をしているか |
|---|---|
| `UI/Sidebar/List/SpacePagerView.swift` | Dia の paging container の AppKit 版。全 space の列を 1 本の strip に並べ、swipe に 1:1 で追従し、spring で止める。page の位置は frame、残りの移動は sublayer の translation だけで行い、swipe 中にレイアウト・差分計算・再描画をしない |
| `UI/Sidebar/List/SpaceListView.swift` | pinned と Today のリスト。observation の範囲で store を読み、run loop 1 周に 1 回だけ平坦な行モデルを作り直し、違う行にだけ新しいモデルを渡す。hover はリスト全体で tracking area 1 つ |
| `UI/Sidebar/List/SpaceColumnView.swift` | space 1 つの列（favorites の grid、見出し、スクロールするリスト）。すべて AppKit で、space の切り替えは layer を動かすだけ |
| `UI/Sidebar/List/SidebarView.swift` | 左の列全体。上段のバー（traffic light・サイドバーの切り替え・戻る/進む）、`SpaceDockView`（34×32 pt の隙間の無い cell、押下中は window を動かさない、mouse-up で切り替え、横ドラッグで並べ替え） |
| `UI/Sidebar/List/SidebarRowViews.swift`、`SidebarListDrop.swift`、`SidebarJumpPill.swift` | 行の view（layer-backed、key で再利用）、リスト内のドラッグ＆ドロップと端での自動スクロール、開いているタブが画面外のときの戻り pill |
| `Services/ItemTable.swift` | item ごとの変更カウンタ。1 つの item の変更で全リストが再描画されるのを防ぐ（Observation を item 単位にする） |
| `UI/SplitView/SplitPaneLayout.swift` | split の純粋なレイアウト関数（Arc の `SplitViewControllerLayout` の写し）。最小幅、gap、hit target の outset、pixel snap |
| `UI/SplitView/PaneCardView.swift`、`SplitDraggerHandleView.swift` | Arc の角丸の card（上に toolbar、下にページ）。ドラッグ中はページの大きさを固定（`frozenWebBounds`）。ページの背景色を card の下地に敷き、resize の遅れで白い縁を見せない |
| `UI/ShellView.swift` | window の content view。gradient の背景、サイドバー（固定・非表示・浮く）、card の配置。vibrant テーマの blur の重ね方 |
| `UI/ArcTooltip.swift` | 共有の非 activating な子 panel 1 つで出すツールチップ（行ごとに NSView を作らない。0.1.17 で行ごとの tracking area が swipe を重くしていた） |
| `UI/Windows/WindowDragGesture.swift` | title bar の代わりの領域（toolbar、URL、サイドバーの上端）で、クリックは動作、3 pt を超えるドラッグは window の移動、を分ける |
| `MainWindowController.swift` の `CraWindow`（2036 行〜） | 押下が space の strip に入ったら mouse-up まで背景ドラッグでの window 移動を止める（`isMovableByWindowBackground` の一時的な切り替え） |
| `UI/Windows/LittleWindowController.swift` | サイドバーの無い小窓。46 pt の strip、検索の pill、「Open in <Space> ⌘O \| ⌄」の分割ボタン |
| `UI/Windows/ExtensionPopupWindow.swift` | ボタンの右端に吊る popup の枠。ボタンからの相対位置でドラッグ位置を覚え、ボタンのある display に置く |
| `UI/Windows/DownloadFlight.swift`、`UI/Sidebar/DownloadsTray.swift` | Arc のダウンロードが Library ボタンへ飛ぶ Core Animation の keyframe と、hover で開く最近のダウンロード |
| `UI/CommandBar/*` | コマンドバー（AppKit の行）。`SuggestionEngine` は開くたびに 1 回だけ検索 index を作る |
| `UI/Settings/*` | NSSplitViewController と unified toolbar の中に SwiftUI を置く設定画面（頻繁に動かない画面は SwiftUI で足りる例） |
| `UI/Theme.swift`、`UI/Tuning.swift` | space のテーマ色から palette を導く処理と、vibrancy の値を cra://debug で実行中に変えるための調整値 |
| `Services/HitchMonitor.swift` と cra:// の command file（`docs/development.md`） | 8 ms 以上の main thread の停止を記録し、command file の各行を印として挟む。`cra://debug?swipe=…`・`scroll=…` でポインタを使わずに操作する |
| `Services/Persistence.swift` | atomic 書き込み、`.bak`、`.corrupt` 退避、off-main の serial queue の `JSONStore`（Rust の中核に移すとしても、規則は同じ） |

平台に依存せず、Rust の中核へ移す候補になるもの: `Model/SidebarModel.swift` の形、`Model/LinkRouting.swift` の照合、`Services/SuggestionEngine.swift` の順位付け、`Services/Import/Importers.swift` の `ImportPlan` と各取り込み、`Services/GitHubLiveClient.swift` の解析、`SplitPaneLayout` の計算。

## 5. 文書とコードの食い違い

| 文書の記述 | コードの実態 |
|---|---|
| `Package.swift:69` のコメント「AppKit window, SwiftUI sidebar and command bar」 | 0.1.18（5f4c901f）でサイドバーとコマンドバーは AppKit になった |
| `docs/development.md:81`「SwiftUI keeps the favorites, space header, top bar and dock」 | `SpaceColumnView.swift` 冒頭は「All AppKit」、上段のバー（`SidebarTopBarView`）と dock（`SpaceDockView`）は `SidebarView.swift` の NSView である。main window のサイドバーに `NSHostingView` は無い（シートの 1 箇所 `MainWindowController.swift:1875` のみ） |
| arc-RE 1509-1513「SpaceDock draws 34×32 contiguous cells in SwiftUI; an AppKit view over the strip (SpaceDockMouse)」、commit 94c3034b「SidebarDock is an NSCollectionView」 | 現在はどちらでもなく、自前の NSView（`SpaceDockView`、`SidebarView.swift:503`）。`SpaceDockMouse` も `NSCollectionView` もコードに無い |
| `EmbeddedPages.swift:4`「Experimental」 | 同じファイルの 14 行目で「On by default」、0.1.17 から既定 |
| `FloatingSidebar.swift:6-10`「Pages are separate Chromium child windows stacked above the shell」 | 0.1.17 以降、既定ではページは card に埋め込まれている（主 window は click-through で残る）。浮くサイドバーの仕組みは 0.1.18 で触られたが、説明は子 window 時代のまま |
| commit dc7fb65b「the prompt stays and gets an explanation」（mDNS を残す） | 同日の c5b7f46a で `WebRtcHideLocalIpsWithMdns` を切り、`default_public_interface_only` にした。`resources/Info.plist:60` の `NSLocalNetworkUsageDescription` は残っている |
| `CraCEF.h:173`「Experiment: a Chrome-style (extension-capable) Views window」の `spikeChromeWindowWithURL:` | 実験は本番の方式になったが、spike の API と実装（`CraCEF.mm:1847` 以降）が残っている |
| arc-RE 1112「`SidebarRootView` pages every space side by side」 | `UI/Sidebar/SidebarRootView.swift` の中身は `SidebarIconButton`（SwiftUI のボタン）だけで、`SidebarRootView` という型は無い。space の横送りは `SpacePagerView` |
| `CONTRIBUTING.md:14`「The app is AppKit and SwiftUI」 | 誤りではないが、SwiftUI は設定・オンボーディング・更新の window などに限られている |

## 6. 読めなかった箇所と推測で書いた箇所

読めなかった箇所:

- `docs/arc-reverse-engineering.md` は 1〜130 行、160〜480 行、595〜665 行、724〜748 行、1227〜1240 行、1276〜1370 行、1551〜1568 行を通読した。130〜160、480〜595、664〜724、748〜1067、1096〜1227、1240〜1276、1370〜1551 行は「Cra」を含む行の grep と、その中の 670〜682、811〜820、1067〜1095、1396〜1402、1505〜1516 行だけを読んだ。Arc 側の観測の詳細（色の計測値、Dia のオンボーディング、Site Control Center の寸法など）はこの台帳では扱っていない。
- `MainWindowController.swift`（113 KB）、`CraCEF.mm`（113 KB）、`SidebarStore.swift`（64 KB）、`LittleWindowController.swift`（61 KB）は節の見出しと該当箇所だけを読み、全文は読んでいない。
- 取り込み（`Import/*`）、`SuggestionEngine`、`GitHubLiveClient`、`SoftwareUpdater`、`Tests/` は冒頭のコメントだけを読んだ。
- `docs/live-folders.md` は冒頭 40 行、`docs/release.md` は 189〜225 行だけを読んだ。
- 0.1.2〜0.1.10 のリリースノートは本文が無く、その間の変更は commit message からしか追えない。`ea159ec9`「Copy and paste bug」、`1f7cf3a9`「sidebar space collapse」、`bdd579a9` は message に説明が無い。

推測で書いた箇所:

- 台帳 15（favorites を space ごとにした理由）は commit に理由の記述が無く、未確定である。
- 台帳 1・3・8 などの「新ブラウザへの適用」で「fork では不要」としたのは、Arc の ArcCore が Chromium の内部 API でこれらを扱っているという arc-RE の観測（静的解析）と、Chromium の構造の一般的な知識に基づく判断である。fork で実際に作って確かめたものではない。
- 台帳 16 で SQLite を候補としたのは筆者の評価であり、Cra が SQLite を検討した記録は無い（Dia が live folder に SQLite を使っているという観測のみ）。
- 台帳 34 の私的 API の危険は一般論であり、Cra の文書に記述は無い。
- §4 の「Rust の中核へ移す候補」は役割から判断した。import を確かめた結果、SidebarModel・LinkRouting・SuggestionEngine・GitHubLiveClient は Foundation のみ、Importers と SplitPaneLayout は AppKit を import している（後者は NSRect などの型のためと見られるが、中身は確かめていない）。
