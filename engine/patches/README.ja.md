# エンジンのパッチセット

パッチの順序は `series` だけで定める。パスはこのディレクトリからの相対パスであり、ungoogled/generic を ungoogled/macos より先に適用する。取り込んだパッチは下記のコミットに由来する。

| ソース | コミット | Chromium |
|---|---|---|
| ungoogled-software/ungoogled-chromium、pull request #4032（2026-11-04 にマージ、タグ `157.0.8103.38-1`） | de09e0c70c6bc1ac83d4ecdfd0e82c7e250c9a3c | 157.0.8103.38 |
| ungoogled-software/ungoogled-chromium-macos | 31f01756a43d55b2c4211e73ca329bfab4ebfcb2 | 156.0.8078.79 |

generic のパッチは pull request の head のバイト単位のコピーである。対象は 157.0.8103.38 であり、Ararat の 157.0.8103.39 に fuzz なしで適用できる。マージコミットは取り込み済みの head と同一なので、取り込み直しは不要である。macOS の 2 件のうち、`add-local-network-usage-description.patch` はコピーし、`disable-crashpad-handler.patch` は手作業で 157 にリベースした（crashpad の `InitialStart` に `embedder_port` 引数が加わったため）。元の効果は維持しており、`InitialStart` は空の send right を返し、`StartHandler` は false を返す。

両プロジェクトは BSD-3-Clause である。LICENSE ファイルは `ungoogled/generic/LICENSE` と `ungoogled/macos/LICENSE` に変更せず保存する。

## パッチ一覧（series 順）

| `series` 内のファイル | 出典 |
|---|---|---|
| `ungoogled/generic/upstream-fixes/missing-dependencies.patch` | generic, upstream-fixes |
| `ungoogled/generic/core/inox-patchset/0003-disable-autofill-download-manager.patch` | generic, core/inox-patchset |
| `ungoogled/generic/core/inox-patchset/0021-disable-rlz.patch` | generic, core/inox-patchset |
| `ungoogled/generic/core/iridium-browser/safe_browsing-disable-incident-reporting.patch` | generic, core/iridium-browser |
| `ungoogled/generic/core/ungoogled-chromium/disable-crash-reporter.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-google-host-detection.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/toggle-translation-via-switch.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-profile-avatar-downloading.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-gcm.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-domain-reliability.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-gaia.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-fonts-googleapis-references.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-webrtc-log-uploader.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-ai.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/disable-network-time-tracker.patch` | generic, core |
| `ungoogled/generic/core/ungoogled-chromium/block-requests.patch` | generic, core |
| `ararat/restore-component-updater.patch` | 独自 |
| `ungoogled/generic/core/ungoogled-chromium/remove-navigation-source-param.patch` | generic, core |
| `ungoogled/generic/core/bromite/disable-fetching-field-trials.patch` | generic, core/bromite |
| `ungoogled/generic/extra/ungoogled-chromium/disable-intranet-redirect-detector.patch` | generic, extra |
| `ungoogled/generic/extra/ungoogled-chromium/fix-building-without-mdns-and-service-discovery.patch` | generic, extra |
| `ungoogled/generic/extra/ungoogled-chromium/disable-dial-repeating-discovery.patch` | generic, extra |
| `ungoogled/generic/extra/ungoogled-chromium/add-credits.patch` | generic, extra |
| `ungoogled/generic/extra/ungoogled-chromium/disable-ai-search-shortcuts.patch` | generic, extra |
| `ungoogled/macos/ungoogled-chromium/macos/disable-crashpad-handler.patch` | macos |
| `ungoogled/macos/ungoogled-chromium/macos/add-local-network-usage-description.patch` | macos |
| `ararat/remove-screenai-sandbox-parameter.patch` | 独自 |
| `ararat/link-ararat-layer.patch` | 独自 |
| `ararat/extra-parts-hook.patch` | 独自 |
| `ararat/permission-prompt-hook.patch` | 独自 |
| `ararat/devtools-hook.patch` | `mantrakp04/ardia`（GPL-3.0） |
| `ararat/autofill-address-bubble.patch` | `mantrakp04/ardia`（GPL-3.0） |
| `ararat/app-controller-hooks.patch` | 独自 |
| `ararat/quit-confirmation.patch` | 独自 |
| `ararat/browser-window-factory.patch` | 独自 |
| `ararat/viewless-read-anything.patch` | 独自 |
| `ararat/viewless-bubble-anchor.patch` | 独自 |
| `ararat/sad-tab-viewless.patch` | 独自、Ardia に同じガードがある |
| `ararat/ssl-interstitial-layout.patch` | 独自 |
| `ararat/keyboard-ime-diagnostics.patch` | 独自 |
| `ararat/find-close-command.patch` | 独自 |
| `ararat/hidden-dialog-containment.patch` | 独自 |
| `ararat/page-dialog-queue.patch` | 独自 |
| `ararat/history-deletion-hook.patch` | 独自 |
| `ararat/crash-lock-abandon.patch` | 独自 |
| `ararat/history-retention.patch` | 独自 |
| `ararat/command-line-urls-hook.patch` | 独自 |
| `ararat/native-editor-ime.patch` | 独自 |
| `ararat/password-manager.patch` | 独自 |
| `ararat/password-prompt.patch` | 独自 |
| `ararat/password-prompt-trace.patch` | 独自 |
| `ararat/passwords-touch-id-check.patch` | 独自 |
| `ararat/menu-bar.patch` | 独自。Araratのメニュー名を定義し、ChromiumのHistory、Bookmarks、Profilesの各メニューとコントローラ、タブ一覧のコントローラの生成を省く。BackとForwardはViewに置く |
| `ararat/search-suggestions-pref.patch` | 自作 |

## 取り込んだパッチを選んだ理由

パッチごとの維持・スキップ・対抗パッチの判断と、セキュリティ上の帰結は `docs/research/ungoogled-inventory.md` §8 にある。

## 独自パッチに関する注記

Araratレイヤーの `ararat_main.mm` は、ブラウザ検査用の一時プロファイル、一時ワークスペース、モックキーチェーンの条件を満たす場合に `--ararat-check=close-successor` を受け付ける。

search-suggestions パッチは、General の設定をアプリ全体で共有するため、Chromium の `prefs::kSearchSuggestEnabled` を Local State に登録する。リンク用のパッチは `AraratSearchSuggestionsEnabled` と `AraratSetSearchSuggestionsEnabled` を公開し、ブラウザウィンドウの有無にかかわらず設定から Local State を読み書きできるようにする。Ararat レイヤーは各通常プロファイルの既定の `TemplateURL` と Chromium の検索候補レスポンスパーサーを使う。`search-suggestions` の検査は使い捨てのプロファイルとループバックの fixture を使う。

`ararat/native-editor-ime.patch` は、first responder が `RenderWidgetHostViewCocoa` のとき、Chromium が英数・かなキーを key window へ直接配送する処理を維持する。それ以外では、`TISCreateInputSourceList` が有効な `kTISTypeKeyboardInputMode` を返した場合（`includeAllInstalled = false`）、AppKit の `[super sendEvent:event]` で配送する。入力モードが有効なら、ABC を選択している間もこの経路を使う。一覧が空または NULL の場合は、U.S. 入力ソースだけの input context が U+0010 を挿入することがあるため、keyDown を破棄する。実機のJISキーボードでの入力ソース切り替えは未確認。

`ararat/sad-tab-viewless.patch` は、host ウィンドウに `BrowserView` がない場合、標準の sad-tab view を設置せずに戻る。Ardia（`mantrakp04/ardia`、GPL-3.0）の `engine/ardiacore/apply.sh` にも同じガードがある。このパッチは Chromium のソースに対して独自に記述した。

`ararat/history-deletion-hook.patch` は、HistoryService が履歴削除を予約する前に任意の hook を呼び、Ararat がファイル用シーケンスでタブ履歴を無効化できるようにする。
mode 1 の検査は `DeleteURLs` を要求し、ファイル用シーケンスの barrier を待つ。要求時の hook が無効化を予約したことを確認するもので、history backend の完了や後続の削除通知は待たない。

`ararat/history-retention.patch` は `ExpireHistoryBackend::GetCurrentExpirationTime()` に日数の保持値を足し、アプリの Privacy のペインが期限切れのループごとに Chromium の固定の 90 日を置き換えられるようにする。0（ペインの Forever と、最初の適用より前の状態）では `DoExpireIteration()` がどの reader よりも前に戻り、segment の後片付けも走らず、待ち行列を 5 分の間隔で組み直すので、何も期限切れにならず、null の `Time` の `LocalMidnight` での削除も起きず、後から保持を設定すると約 5 分以内に効く。

`ararat/crash-lock-abandon.patch` は、workspace の復旧完了前にプロファイルが破棄された場合、クラッシュを確認済みにせず crash lock を解放できるようにする。

`ararat/permission-prompt-hook.patch` は `ChromePermissionsClient::CreatePrompt` から独自 hook を呼ぶ。hook が未設定か null を返す場合は Chrome 標準のプロンプトを使う。`link-ararat-layer.patch` は permissions のビルドターゲットに `//ararat/core:hooks` を追加する。

`ararat/devtools-hook.patch` は `mantrakp04/ardia` の `engine/patches/chromium-window-docked-devtools.patch`（GPL-3.0）を元にする。`DevtoolsUIController::UpdateDevtools` を任意の hook に通知し、hook が未設定なら Chrome の動作を維持する。`link-ararat-layer.patch` は DevTools のビルドターゲットに `//ararat/core:hooks` を追加する。

`ararat/autofill-address-bubble.patch` は `mantrakp04/ardia` の `engine/patches/chromium-autofill-address-bubble-window.patch`（GPL-3.0）を元にする。Browser の unowned user data から Autofill handler を取得し、住所プロモーションの `AsBrowserView()` 呼び出しをガードし、カード controller の 2 つの検査を早期 return に変える。

`ararat/keyboard-ime-diagnostics.patch` は keyboard check の browser 側の対象と転送を件数制限付きで記録する。入力テキストは記録しない。

`ararat/hidden-dialog-containment.patch` は hidden check の予期しない通常の JavaScript dialog を拒否し、beforeunload の開始と完了を WebContents の境界で検証できるようにする。

`ararat/page-dialog-queue.patch` は Ararat のページダイアログを閉じるとき、Chromium がキューの次のダイアログを表示する前に現在のウィジェットを隠す。

`ararat/find-close-command.patch` は検索セッションの終了後、検索 UI が非アクティブになった時点でコマンドの状態を更新する。

`ararat/app-controller-hooks.patch` は Dock の再オープンとメニュー、外部 URL、表示中の Browser を独自 hook に渡す。hook が未設定のときは標準の動作を使う。native の openURLs と Handoff は、最後のプロファイルを元の通常プロファイルに戻し、ポリシーによる incognito の強制は維持する。これにより、プライベートウィンドウが active でも外部リンクは Air Traffic Control を通る。

`ararat/remove-screenai-sandbox-parameter.patch` は `chrome/browser/chrome_content_browser_client.cc` の sandbox パラメータから ScreenAI の分岐を削除する。`disable-ai` が ScreenAI を削除するため、この分岐を残すと `ScreenAIInstallState::GetInstance()` が未定義シンボルになり、リンクに失敗する。

`ararat/restore-component-updater.patch` は `components/update_client/update_checker.cc` にある `block-requests` の hunk だけを元に戻す。これにより component updater はネットワーク経由の更新確認を再び実行する。他の hunk はすべて有効のままとする。Google Safe Browsing もビルドに残す。`fix-building-without-safebrowsing` を取り込まず、`engine/args.gn` に `safe_browsing_mode=0` を設定しないためである（いずれの場合も API キーは設定していない）。

`ararat/link-ararat-layer.patch` は `//ararat/core` を framework の依存に追加し、`ararat.exports` をリンカに渡し、独自のシンボルを `chrome/app/framework.order` に追加する。`ararat/extra-parts-hook.patch` は `ChromeContentBrowserClient::CreateBrowserMainParts` の末尾で `g_ararat_add_browser_main_extra_parts` が設定されていれば呼び出す。未設定の場合、Chrome は標準どおりに動作する。`ararat/browser-window-factory.patch` は `Browser` のコンストラクタで独自の window factory が設定されていれば呼び出す。未設定の場合と null が返った場合は、Chrome が標準ウィンドウを生成する。location bar がないウィンドウでは、その状態の保存も省く。hook の一覧は architecture §4.3 にある。

`ararat/viewless-read-anything.patch` は、side panel のない独自の viewless ウィンドウで side panel の後処理を省く。

`ararat/viewless-bubble-anchor.patch` は、`BrowserView` がない場合、location bar の chip を確認した後に空の page-info anchor を返す。その後 chooser とファイルシステムの復元権限バブルは、host ウィンドウの上端の開始側から Chromium の no-toolbar offset だけ離れた位置を使う。RTL では左右を反転する。host がない場合や空の場合は空の矩形を返し、標準の `BrowserView` の経路は変えない。実際の bubble の配置は未検証である。

factory hook の設定時、このパッチは `BrowserInitState` がフラグを取り込む前に Chrome のセッション復元を無効にする。標準ウィンドウを使う Browser も対象である。Ararat 自身の workspace の復元は U17 で core から行う。
U14 の拡張 action container と popup anchor は独自レイヤーにあり、Chromium のパッチを追加しない。外部インストールのエラーダイアログは `BrowserView` を前提としているため、外部インストールをサポートするにはガードまたはパッチが必要である（我々の規則）。

`ararat/command-line-urls-hook.patch` は、二重起動時の URL 引数を、Chromium が起動用プロファイルを読み込んだ後、`--no-startup-window` によって標準の起動処理が抑制される前に、アプリの外部 URL の共通入口へ転送する。hook が未設定なら Chromium の経路を使う。
