# Arc と Dia のコンポーネント目録（公開されたリバースエンジニアリングの集約）

作成日: 2026-10-30。目的は、Swift/AppKit の UI・ArcCore 方式の Chromium fork・Rust の中核で作る macOS ブラウザのコンポーネント構成を決めるための材料を集めることである。本文書はバイナリを新たに解析していない。使ったのは次の公開文書と、手元の `/Applications/Arc.app` の `Info.plist`・`Contents/Frameworks` のファイル名・`otool -L` の結果だけである。

- Cra: `VictorKildahl/cra` の `docs/arc-reverse-engineering.md`（以下「Cra 文書」）
- Ardia: `mantrakp04/ardia` の `docs/dia-spec.md`・`docs/dia-feature-parity.md`・`docs/omnibox-ux.md`・`docs/research/*.md`・`docs/architecture-review.md@2713787d`（以下「Ardia 文書」）。第 4 節の補強に `docs/ardiacore-spike.md` と、@2713787d 版の `docs/research/chromium-ui-layer.md`・`chrome-hosted-window.md` も参照した

## 用語と記号

| 語 | 意味 |
|---|---|
| space | Arc のサイドバーの切り替え単位。pinned と Today の 2 つの container を持つ |
| pinned | space ごとの固定タブの区画 |
| Today | space ごとの非固定タブの区画（データ上は `unpinned`） |
| favorites | profile ごとに 1 つで、全 space が共有する上部のタイル列（データ上は `topApps`） |
| folder | サイドバー項目の入れ子（データ上は `list`） |
| archive | 閉じた・自動で片付けたタブの保管先（`StorableArchiveItems.json`） |
| ARC_* | Arc の bundle 名・Swift モジュール名の接頭辞 |
| ArcCore | Arc・Dia が同梱する Chromium の framework（`ArcCore.framework`） |
| seam | Chrome の `chrome/browser/ui` が宣言し、embedder が実装を差し替えられる関数・クラス |

証拠の記号は元文書のものを保つ。**[O]** 観察（出荷物・データファイル・実機の録画で確認）、**[I]** 推測、**[U]** 不明、**[?]** 未確認（Cra 文書の表記）。元文書が記号を付けていない Ardia 文書の記述は、出典の種類（バイナリの逆アセンブル・録画・Ardia の実装）を文で書いた。「Cra:」「Ours」「Ardia」で始まる記述は再実装側の判断であり、Arc・Dia の事実として扱っていない。

---

## 1. Arc の全体構成

### 1.1 手元の Arc.app で観察した事実（本調査の一次観察）

- **[O]** `CFBundleShortVersionString` 1.170.0、`CFBundleVersion` 89123、`BCNYBuildDate` 21 Oct 2026、`BCNYCommitInfo` Release-89123-9f5625b…、bundle id `company.thebrowser.Browser`、`NSPrincipalClass` `Arc.BrowserApp`、`LSMinimumSystemVersion` 13.0.0、SDK macOS 26.4（Xcode 26.4.1）。
- **[O]** URL scheme は `http`・`https`・`mailto`・`arcBrowser`。文書型は PDF・HTML・XHTML（Viewer）。
- **[O]** Sparkle の設定: `SUFeedURL` https://releases.arc.net/updates.xml、`SUEnableAutomaticChecks` true、`SUAutomaticallyUpdate` true、`SUScheduledCheckInterval` 28800（8 時間）。
- **[O]** `Contents/Frameworks` の中身は次の 10 件である。
  - `ArcCore.framework`（実行ファイル 478.6 MB、`Helpers/`・`Libraries/`・`Resources/` を持つ）
  - `Sparkle.framework`（current version 2.9.4）、`Lottie.framework`、`Sentry.framework`
  - `FirebaseFirestoreInternal.framework`、`grpc.framework`、`grpcpp.framework`、`openssl_grpc.framework`、`absl.framework`
  - `libswiftCompatibilitySpan.dylib`
- **[O]** `otool -L Contents/MacOS/Arc`（x86_64 と arm64 の universal）: `@executable_path/../Frameworks/ArcCore.framework/Versions/A/ArcCore`（compatibility/current version **8078.0.48**）、Lottie、Sparkle を直接リンクする。システム側は AppKit・**SwiftUI**・Combine・CoreData・CloudKit・Metal/MetalKit・QuartzCore・WebKit・PDFKit・ScreenCaptureKit・AVKit・NaturalLanguage・GameplayKit・CryptoKit・UserNotifications・MetricKit（weak）など。リンクされる UI framework は AppKit と SwiftUI であり、React Native の framework はリンクされていない（静的リンクの有無は `otool -L` では分からない）。
- **[I]** ArcCore の版 8078.0.48 は Chromium の branch 8078 に相当する。Dia の ArcCore では compatibility version 8037.0.58 が Chromium 154.0.8037.58 に対応する（Arch › B、chrome-hosted-window.md）ので、同じ規則なら Chromium ?.0.8078.48 であり、156 系というのは推測である。Cra 文書は Chromium 156.0.8078.48 に言及するが、文脈は Cra 自身の CEF の検証であり、Arc の ArcCore がこの版だとは明記していない。
- **[I]** FirebaseFirestore と grpc の同梱、CloudKit のリンクは、Cra 文書の「sync via CloudKit + Firebase」（Other observed features）と整合する。

### 1.2 アプリ本体（Swift の shell）

- **[O]** ネイティブの Swift アプリで、UI は AppKit。`SidebarViewController`・`SidebarDockViewController`・NSCollectionView のレイアウト・`CommandBarTextField`・`SuggestionsView` がある（Cra 文書 › Architecture）。
- **[O]** 状態管理は TCA（ComposableArchitecture）: `Store<WindowState, WindowAction>` と view store（Cra 文書 › Split View › Where it lives）。`Arc.AppReducer`・`Arc.WindowsReducer` が `LinkRoutingClient` を持つ（Air Traffic Control）。
- **[O]** 画面の部品は `XiblessViewController<NSView>` を基にした AppKit の view controller が中心で、SwiftUI も linked である（`otool -L`）。どの画面が SwiftUI かは元文書に記述がない **[U]**。
- **[O]** web content は埋め込みの Chromium で、`User Data/Default` は Chrome の profile である（History・Cookies・Extensions・Preferences）（Cra 文書 › Architecture）。

### 1.3 「ARC」フレームワークと機能モジュール

Cra 文書は「Framework "ARC" with feature modules」と書く（Architecture）。しかし手元の `Contents/Frameworks` には `ARC.framework` が存在しない。Cra 文書が根拠として挙げるのは `ARC_CommandBar.bundle`・`ARC_PictureInPicture.bundle`・`ARC_SiteControlCenter`・`ARC_WindowThemeUI` のようなリソース bundle と、Swift のモジュール名である。したがって、ARC は実行ファイルに静的にリンクされたモジュール群の名前空間と読むのが妥当である **[I]**。

元文書に現れるモジュール・型の名前を、機能ごとにまとめる（すべて Cra 文書の [O] 記述から。Dia の名前は Ardia 文書から）。

| 区分 | モジュール・型（Arc） | 出典の見出し |
|---|---|---|
| 汎用 UI | `ARCUI`（`SplitViewController`、`PageSwipeController`、`VelocityTracker`、`GradientView`） | Split View › Where it lives / Dia space paging |
| ウィンドウ | `WindowContents`（`SplitViewState` 等）、`SharedWindowFeature`（`WindowAction`、`SidebarCellCloseButtonConfiguration`、`WindowData+ContentReparenting`） | Split View / Closing vs removing pinned tabs / A tab open in two windows |
| データモデル | `BaseModels`（`SidebarSplitViewData` 等）、`SidebarDataStore`、`StorableSidebar` | Architecture / Split View › Data model |
| サイドバー | `SidebarUI`（`SplitViewCellState`）、`SidebarDock`、`SidebarBanner`、`HomeButton`（Library） | Space dock / Library / Software updates |
| command bar | `CommandBar`（`ARC_CommandBar.bundle`）、`TypeTravel` | Command bar |
| space の見た目 | `SpaceStyleEditor`、`ARC_WindowThemeUI` | Spaces / Ardia feature parity §21 |
| 小窓 | `LittleBrowser`（Little Arc）、`ModalItemSwitcher`（タブ切り替え） | Little Arc / Tab switcher |
| ツールチップ | `ArcTooltip` | Closing vs removing pinned tabs |
| ダウンロード | `DownloadsUI`、`ADKClient/DownloadManager.swift` | Downloads |
| ポップアップ | `ADKClientLive.BrowserExtensionsPopUpManager`、`Arc.BrowserExtensionWindow` | Extension popups |
| PiP | `PictureInPicture`（`ARC_PictureInPicture.bundle`） | Picture in Picture |
| 更新 | `SoftwareUpdaterClient`（Sparkle の `SPUUserDriver` を自前実装） | Software updates |
| その他 | `HoverCards`、`Archive`、`ARC_SiteControlCenter`、Boosts、Easels | Architecture / Site Control Center |

`ADK` は Swift 側から ArcCore を呼ぶ層の名前として現れる（`ADK.ContextDownloadDelegate`、`ADKClientLive`）**[I]**。

### 1.4 ArcCore（Chromium 側）

Arc の ArcCore について元文書が示すのは次の範囲だけである。

- **[O]** ArcCore の browser delegate が拡張のポップアップを web contents として Swift に渡す: `browser:didOpenExtensionPopup:webContents:`、`browser:didResizeExtensionPopup:size:`、`browser:didCloseExtensionPopup:`。`createPopupBrowser:withDelegate:`・`didCreateNewBrowser:`、`ChromiumBrowser.browserType: {normal, popup, pictureInPicture}`（Cra 文書 › Extension popups）。
- **[O]** `arc::VideoPiPCoordinatorImpl(content::VideoPictureInPictureWindowController*)` で Chromium の video PiP を包む（Picture in Picture）。
- **[O]** Chrome 標準の DevTools embedder の文字列（`&can_dock=true`、`setInspectedPageBounds`）があり、Arc は Chrome の `DevToolsWindow` をそのまま使う（DevTools docking, Arc's way）。
- **[O]** split view は Chromium 側に無い。ArcCore には Chrome 標準の `tabs.createSplit` の文字列があるが、Arc の UI は参照しない（Split View › Where it lives）。
- **[O]** ダウンロードは ADK 経由で Arc の view に渡り、Chrome の download bubble は出ない（Downloads）。

Dia の ArcCore は Ardia 文書がより詳しく調べている（第 4 節）。Dia の ArcCore が持つ ObjC API（146 クラス、mojom から生成、`Headers/arc/browser/objcpp`）と同じものが Arc の ArcCore にもあるかは、元文書では確かめられていない **[I]**。

### 1.5 同梱フレームワークの役割

| フレームワーク | 役割 | 証拠 |
|---|---|---|
| ArcCore | Chromium（`//chrome` を含む）と Arc 独自の C++ 層 | 手元の otool [O]、Cra 文書 |
| Sparkle 2.9.4 | 自動更新。UI は `CustomUserDriver` で自前 | Info.plist [O]、Cra 文書 › Software updates |
| Lottie | アニメーション（更新完了の heart など） | Cra 文書 › Software updates [O] |
| Sentry | クラッシュ報告 | ファイル名のみ [O]、用途は [I] |
| FirebaseFirestore + grpc 系 | 同期 | ファイル名 [O]、用途は Cra 文書の記述からの [I] |

---

## 2. コンポーネント目録

出典の略記: **Cra** = `VictorKildahl/cra` › `docs/arc-reverse-engineering.md`、**Spec** = `mantrakp04/ardia` › `docs/dia-spec.md`、**Parity** = 同 `docs/dia-feature-parity.md`、**Omni** = 同 `docs/omnibox-ux.md`、**Arch** = 同 `docs/architecture-review.md@2713787d`。行番号は取得した版のもの。

### 2.1 Arc

| コンポーネント | 役割 | 観察された証拠 | 出典 |
|---|---|---|---|
| サイドバー（本体） | favorites・space の見出し・タブ一覧・dock を縦に並べる | [O] 幅 328 pt（`StorableWindows.json` の `sidebarWidth`）、`sidebarMode` は `anchored`（バイナリには `floating`・`hidden`・`collapsed` もある）。[O] 行は 40〜41 pt pitch、タイトル 14 pt、favicon 16 pt、入れ子の字下げ約 18 pt。[O] 一覧は 1 つの outline（`sidebarAllTabList`）で、pinned・区切り・Today が一緒にスクロールし、favorites と space の見出しは固定。[O] 上下の境界線は 1 pt・約 5% 黒で、スクロール位置に応じて 0.2〜0.3 s で出入りする。[?] space を切り替えたときにスクロール位置を保つか | Cra › Window state（L43）、Visual reference（L96）、Sidebar scrolling（L724） |
| サイドバーの見出し（ツールバー非表示時） | ツールバーを隠したときに URL とナビゲーションをサイドバー上部に置く | [O] 設定は `topBarURLEnabled`（View ▸ Show Toolbar）。[O] 1 行目に信号機・サイドバー切替・戻る/進む/再読込、2 行目に host だけを示す 36 pt の URL pill。[I] 拡張・コピー・Site Control Center のボタンは見出しの hover で出る（`isHeaderViewHovered`） | Cra › Sidebar header with the toolbar hidden（L1189） |
| space | サイドバーの切り替え単位。profile とテーマを持つ | [O] `SpaceModel`: id、title、profile、`containerIDs`、`customInfo.iconType`（`emoji_v2`/`emoji`）、`customInfo.windowTheme`。[O] UI: `SidebarDock`（下部の切替）、`SidebarPagingContainer`（横ページング）、`SpaceCreation`、`SpaceStyleEditor`（color pad・dial・color picker）、`SpaceIconPicker`、`SpaceManagement`（並べ替え）。[O] 操作: `focusNextSpace`/previous、⌥⌘→/⌥⌘←、⌃N | Cra › Sidebar data model（L17）、Spaces（L47）、Key bindings（L73） |
| space の dock | サイドバー下部の space 切り替え | [O static] `SidebarDock.SidebarDockView` は NSCollectionView で、並べ替えは collection view の drag and drop。[O AX] 各 space は 36×34 の AXButton、34 pt pitch で隙間なく並ぶ。左に 32×32 の Library ボタン、右に 32×32 の「+」。[O] 押下時の塗りは白約 7.8%、角約 6 pt。[U] hover の塗り。[O] 「Drag to Reorder Space」は dock ではなく `Arc.SpaceControlsView` のもの | Cra › Space dock（L1490） |
| pinned | space ごとの固定タブ。保存した URL を「家」として持つ | [O] 各 space は pinned container を 1 つ持ち、順序は `childrenIds`。[O] pinned タブは `savedURL`/`savedTitle` を家として保つ。文字列: `resetTab`、`replacePinnedTab`、`PinnedTabNavigationProfile`、`renamePinnedTabsEnabled=1`。[O live] 現在のタブの hover ボタンは「—」（"Close and Keep Pinned ⌘W"、unload して pinned に残す）、それ以外は「✕」（"Archive this tab"）。[I] 読み込み済みの背景の pinned タブも ✕。[O] 1.170 で pinned 区画の折りたたみ（`collapsePinnedSection`、窓ごとの `spacesWithCollapsedPinnedSections`）。[I] space 名のクリックで切り替わる。[O] 家から離れた pinned タブは host を 11 pt の 2 行目に出す。[?] pinned タブの context menu の文言 | Cra › Sidebar data model（L31–41）、Closing vs removing pinned tabs（L748）、Sidebar icons（L664） |
| Today | space ごとの非固定タブ | [O] 各 space は unpinned container を 1 つ持つ。[O] 区切りは `UnpinnedSectionDividerCellView`（`SidebarClearButton` を含む）。状態 `clearTabAction`（`clearAll`・`clearOthers`・`tidyAndClear`）、`buttons`（`clear`・`moveToMainWindow`・`custom`）。hover 状態を持たず、ボタンは区画と一緒に常に出る。メニューは "Clear Unpinned Tabs"（⇧⌘K）、toast で Undo を出す。Arc の 2022 年のリリースノートによれば、選択中のタブとメディア再生中のタブは残る | Cra › Sidebar data model（L33）、Spec › Arc note: Clear above the unpinned tabs（L279） |
| favorites | profile ごとのタイル列。全 space で共有 | [O] `topApps` container は profile ごとに 1 つ（`topAppsContainerIDs`）。[O] タイルは高さ 47 pt、隙間 8 pt、角 13 pt。非選択はサイドバー色 ×0.955、選択は白約 38% と内側 2 pt の縁。[O] 黄と黒の破線リングはキーボードで選んだときだけ出る | Cra › Sidebar data model（L29）、Chrome metrics re-measured（L444） |
| folder | サイドバー項目の入れ子 | [O] `SidebarItem.data.list {}`、任意で `customInfo.iconType`、GitHub の live folder 用の `automaticLiveFolderData`。[O] 入れ子は `parentID`、開閉状態は窓ごとの `expandedItems`。[O] アイコンは `folder.fill`（テーマ色を白へ 80% 寄せた色）の上に `folder` の輪郭（ツールバー色） | Cra › Sidebar data model（L26）、Window state（L44）、Live re-fit（L522） |
| archive | 閉じたタブ・自動で片付けたタブの保管と復元 | [O] `StorableArchiveItems.json`: `archivedAt`、`reason`（`manual`/`auto`）、`source`（`space{id}`/`littleArc`/`standaloneSidebar`/`unknown`）、`sidebarItem`（項目の複製）。[O] 自動 archive の閾値: `twelveHours`・`twentyFourHours`・`sevenDays`・`thirtyDays`（profile ごと）。[O] 操作: `viewArchive`・`clearArchive`・`reopenClosedTab`・`resetSpace`・`archiveTab` | Cra › Archive（L52） |
| Library | archive・ダウンロード・メディアなどの一覧 | [O static] 別窓ではなく窓の状態（`WindowState+Library.swift`）で、ページは `HomeButton/Pages/{Archive,Downloads,Media,…}`。外側のクリックでは閉じない。[O] 開くとサイドバー全体を置き換え、幅を 347→417 pt に広げる（113 pt のレール + 一覧）。[O] 最後に開いたページを覚える。[O] ボタンの hover でダウンロード一覧が出る（0.2 s 後、行が下から 25 ms 間隔で出る）。[U] 一覧の列幅が固定か、開閉の曲線 | Cra › Library（L1518）、Arc's downloads list（L1450） |
| command bar | URL 入力・検索・タブ切替・コマンド実行の統合入口 | [O] 入口: `keyboardShortcutT`・`keyboardShortcutL`・`sidebarDoubleClick`・`sidebarNewTabButton`・`littleArcPlaceholderClick`・`topbar` など。[O] 結果の種類（archetype）: `tab`（Switch to Tab、`customTitle` を持つ）、`chromiumHistory`、`chromiumSearchWhatYouTyped`、`chromiumSearchSuggestion`、`chromiumNavigateWhatYouTyped`、`chromiumSearchHistory`、`chromiumNavigateSuggestion`、`chromiumBookmark`、`chromiumSearchOtherEngine`、`chromiumSearchCalculatorAnswer`、`topDomain`（同梱の `popularDomains.json`）、`typeTravel`（`menuItem:`・`focusSpace:`・`moveToFolder:`・`openFolder`・`webContentExtension:`）、`askGPTWhatYouTyped`、`siteSearch`、`staticQuerySuggestions`。[O] 順位付けの信号: `recentlySwitchedToTabs`（タブごとに直近 10 回）、`queriesToSelectedArchetype`（入力の接頭辞 → 選んだ種類を学習）、`typeTravelUsage`（頻度と直近 15 回）、`siteEngagementScore`、`fuzzySearchConfidence`、hotWords の一致率、タイトル/URL の一致率と位置、recency、importance、`customTitlePrefix` の加点、`veryRecentTabOrDocumentBoost`、`derankCurrentItemURL`、`dedupByTitleAndHostList`。[U] 重み（CoreML の `CommandBarRankingTensor`）。[O] 見た目: 幅約 766 pt、入力行 60 pt、結果行 50 pt、補完行 → 入力そのまま → 一致の順、選択行は space の色。⌘L はツールバー表示中なら inline で編集 | Cra › Command bar（L57）、Visual reference（L105） |
| type travel | command bar からメニュー項目・space・folder を実行 | [O] トリガーの例 "Go to Sidebar Item 3"・"3. tab"。`toggleBetweenTypeTravelAndCommandBar`。split view の候補（AddLeft/Right/Top/BottomSplit 等） | Cra › Command bar（L64, L70）、Split View › Commands（L366） |
| Little Arc | サイドバーの無い小窓。外部アプリのリンクを受ける | [O] `StorableWindows.json` に `little { profile, session { entryPoint { externalLink } }, preferredFrame }`。閉じると `source: littleArc` で archive へ。`LittleBrowserWindow_size` が最後の大きさを保つ。[O] 46 pt の帯 1 本、角 10 pt。帯は既定 profile の暗い配色（フォーカス中の space ではない）。[O] 「Open in <space> ⌘O \| ⌄」ボタン、⌄ で `LittleBrowserMoveMenu`（space の検索・選択）。[O] ⌥⌘N で空の Little Arc。[O] 開くときはポインタ下の小さな矩形から約 120 ms で全体に広がる、fade なし。[O] ⌘L/⌘T で幅 500 pt の command bar が窓内に出る | Cra › Little Arc（L464） |
| Air Traffic Control（LinkRouting） | 外部から来た URL を規則で space か Little Arc に振り分ける | [O] Settings ▸ Links の "Air Traffic Control…" で 508×500 の sheet。規則は 2 行（"🔗 URL" + 一致方式 + テキスト、"↳ Open in" + 行き先）。[O] 保存は `StorableLinkRouting.json`（第 3 節）。[O] 型: `LinkMatchingRule`、`LinkSourceComponent.ComponentType = urlMatch(style, String)`、`LinkDestination = space(ProfileDestination) \| littleArc(ProfileDestination)`、`ProfileDestination = mostRecent \| space(UUID) \| profile(…)`。[O] 「Links from other apps open in Little Arc」は既定の行き先そのもの。[O 実行時] 比較の前に URL と規則の両方から大文字小文字・scheme・先頭の `www.` を落とす。"Contains" は query と fragment も見る。"Is equal to" は host と path だけを比べ、末尾の `/` は無視。規則は上から順に評価し、最初の一致で決まる。space 行きは Today の先頭に前景タブを作り、窓をその space に切り替える。[O] meet.google.com → Most Recent Space の規則を 1 回だけ種まきする。[U] 1 規則に複数条件があるときの意味（any か all か） | Cra › Air Traffic Control（L1276） |
| split view | 1 つの窓に最大 4 枚の pane を並べる | [O] 全体が Swift の shell にあり、Chromium 側にはない。`ARCUI.SplitViewController` は NSSplitView を使わない自前の layout engine（`SplitViewControllerLayout` が context から frame を出す純関数）。[O] サイドバー上は folder と同じく `splitView` という項目で、子が pane のタブ（第 3 節）。[O] pane の大きさは `widthFactor`、resize 中は web content の幅を固定して端に寄せる（`lockContentWidth`、`ContentResizeMode {intrinsic, throttle, locked}`）。[O] drag and drop: `DropTarget = replaceContent(index) \| insertContent(index)`、サイドバーのタブを左右半分に重ねても作れる。[O] 入口の記録 `SplitViewEnteredSource`（plusButton・dragAndDrop・menu・alternateClick（⌥クリック）・typeTravel 等）。[O] エラー `splitViewMaximumPanesExceeded`。[I] 上限 4 枚。[O live] pane の間は 10 pt、各 pane に ← → ✕ のツールバー。[U] 境界の drag による resize の操作感（実機では pane の移動モードに入った） | Cra › Split View（L221–391）、Split View, observed live（L595） |
| peek（リンク） | リンクを窓の上のカードで一時的に開く | [O strings] Cra 文書は機能名「Peek」と key binding の識別子 `peekEmail` を挙げるだけである。挙動の記述（⇧クリックで開く）は Ardia の Parity 表の「as in Arc」という記述で、Arc の録画や解析に基づくものではない。[U] Arc の Peek の寸法・動き | Cra › Other observed features（L117）、Key bindings（L81）、Parity §1 Peek 行（L219） |
| peek（サイドバー） | サイドバーを隠したとき、窓の左端にポインタを置くとサイドバーを重ねて出す | [O 録画] 5 pt の inset で窓の左・上・下から離した浮遊パネル、幅は固定時のサイドバーと同じ（227.5 pt）、暗い色、0.5 pt の明るい縁。fade なしで端から spring（response 0.185 s、damping 0.77）で入り、約 150 ms の ease-in-out で出る。パネルのサイドバーボタンで即座に固定へ移る | Spec › Arc note: hiding the sidebar with the address bar in it（L258） |
| profiles | cookie 等を分ける Chromium の profile と space の対応 | [O] データ上の対応だけが分かる: `SpaceModel.profile`、`topApps{profile}`（favorites は profile ごと）、`ProfileDestination`、`PinnedTabNavigationProfile`、Little Arc の `profile: {default: true}`、自動 archive の閾値は profile ごと。[O] Library のダウンロードは profile で絞れる。[O] space の見出しに "Edit Space profile" のツールチップ。[U] Arc の profile 管理画面 | Cra › Sidebar data model、Archive、Little Arc、Downloads（L1408）、Closing vs removing pinned tabs（L786） |
| キー割り当て | 操作の一覧と既定のキー、ユーザーの上書き | [O] 第 3 節のデータ形式。[O] 操作の識別子（`newTab`・`archiveTab`・`pinTab`・`toggleSidebar`・`focusNextSpace`・`addSplitView`・`showLittleArc`・`peekEmail`・`moveToSpace`・`replacePinnedTab` など72 個）。[O] 既定のキーは Accessibility でメニューから読んだもの（⌘T、⌘L、⌘S = Hide Sidebar、⇧⌘D = Hide Toolbar、⌘D = Pin/Unpin、⌃⇧= = Add Split View、⌥⌘N = Little Arc、⇧⌘K = Clear Today、⌃Tab = 直近のタブ など） | Cra › Key bindings（L73）、Developer Mode, shortcuts（L203） |
| 設定画面 | Arc の Settings | [O] 元文書で確認できるのは一部だけである。Settings ▸ Links の Air Traffic Control の card と sheet、"Automatically update my Arc"（`automaticallyUpdateArc`）、"Enable Picture in Picture when you leave a video tab"、`topBarURLEnabled`（View メニュー）。[O] space ごとの設定は space の見出しから開く（"Edit Space theme"・"Edit Space profile"・space options のツールチップ、`spaceHeaderContextMenu`）。[O] Developer Mode はサイト単位で、ツールバーの構成を切り替える（⌃D で解除）。[U] Arc の Settings 窓の構成・ペイン一覧 | Cra › Air Traffic Control、Software updates（L1263）、Picture in Picture（L539）、Closing vs removing pinned tabs（L786）、Developer Mode（L203） |
| テーマ（blendedGradient） | space ごとの窓の色・グラデーション・ノイズ・透過 | [O] `customInfo.windowTheme = blendedGradient { baseColors[2], overlayColors, modifiers { noiseFactor, intensityFactor, overlay: "grain" }, wheel: analogous \| complimentary, translucencyStyle: light \| dark }`、明暗の `appearanceBased` 変種、`semanticColorPalette`（`foregroundPrimary`/`Secondary`/`Tertiary`、`backgroundExtra`、`maxContrastColor`、`hover` など）。Ardia の Parity 表によれば、Arc 1.167 の Swift 型情報にはさらに overlay の第 3 色、texture（grain・sand・denim・tweed）、`windowAppearance`、不透明の `basicColor` がある。[O] ツールバーの色はページの `theme-color`、無ければ body/html の背景色。[O] 非アクティブ時は背景の透過をやめ、平らな色になる | Cra › Sidebar data model（L19–22）、Hover, toolbar colour（L587）、Picture in Picture hover controls（L876）、Parity §20 Arc theme import、§21 Custom profile theme |
| Site Control Center | ツールバー右端のスライダーボタンから開く、サイトごとの操作 | [O] 262 幅の AXPopover。共有・New Boost・範囲キャプチャ・全体キャプチャのボタン、拡張のグリッド（pin の badge 付き）、Developer Mode・広告ブロック・自動 PiP の切替、"Secure" pill と More メニュー（Clear Cache・Clear Cookies・All Site Settings 等） | Cra › Site Control Center（L1368） |
| tab switcher | ⌃Tab で直近のタブを巡回 | [O] `ModalItemSwitcher`。フォーカス中の space のタブを `timeLastActiveAt` の新しい順に 5 枚。⌃ を離すと切替、Esc で取消、短く押すとパネルを出さずに切替。アニメーション無し | Cra › Tab switcher（L1463） |
| 窓をまたぐタブ | 同じタブを 2 つの窓で開いたときの扱い | [O static] ページを窓の間で移す（`reparentWindowContent`）。移された側は blur した snapshot の placeholder を出す（`BlurredSnapshotView`）。[U] blur の半径、発火の時機 | Cra › A tab open in two windows（L1551） |
| 拡張のポップアップ | 拡張の popup を別窓で出す | [O] ArcCore → Swift の delegate（第 1.4 節）、`Arc.BrowserExtensionWindow`、移動後の frame を autosave。[I] ユーザーが drag できる別窓。[O] パスワード管理拡張の ID 一覧を同梱 | Cra › Extension popups（L1326） |
| ダウンロード | ダウンロードの表示と Library への格納 | [O] Chrome の download UI を使わず ADK 経由で自前の view に出す。放物線で Library ボタンへ飛ぶアニメーション（約 1.10 s）、bin は 30 s 後に消える | Cra › Downloads（L1404）、Arc's download animation（L1424） |
| PiP | Chromium の video PiP を Arc の窓で包む | [O] `NSFloatingWindowLevel`、6 pt の角、元タブの窓がキーになると閉じる。[U] hover の操作ボタンの配置 | Cra › Picture in Picture（L527）、Picture in Picture hover controls（L857） |
| 更新 | Sparkle と自前の更新 UI・サイドバーの banner | [O] 第 1.1 節の設定、`CustomUserDriver`、`SidebarBanner`（"An update is ready!"）。[U] 自動再起動の遠隔フラグの値 | Cra › Software updates（L1227） |
| ツールチップ | 独自のツールチップ | [O] `ArcTooltipConfiguration { content, keyboardShortcut, preferredAnchor, presentationBehavior, maxWidth, colorPalette }`。[O live] ポインタ静止から 1.60 s で出る | Cra › Closing vs removing pinned tabs（L767） |

### 2.2 Dia（比較用）

| コンポーネント | 役割 | 観察された証拠 | 出典 |
|---|---|---|---|
| サイドバー | タブを縦に並べる | Dia 1.50.1 のバイナリ: `TabListCollectionViewLayout`、既定幅 190 pt、行 37 pt（背景 34 pt）、pinned dock は `TabDockView` で固定、その下に 1 pt の線とスクロール領域（第 5 節） | Spec › Sidebar rows（1.50.1） |
| pinned（dock） | 上部のタイル。選択時の色をアイコンから作る | 1.50.1 のバイナリ: `TabDockItemView`、`TabIconProcessorImpl._generateTheme`（アイコンの色のばらつきで blur 型か template 型かを決める） | Spec › Sidebar |
| タブグループ | Arc の folder に当たる | 1.50.1 の録画と色トークン。hover 中だけ枠を出す。Parity 表によれば Dia のグループは入れ子にできない（Arc の folder はできる） | Spec › Sidebar、Parity §3 |
| profile とページング | profile ごとのサイドバーを横にページングする | 1.50.1 のバイナリ: `ARCUI.PageSwipeController`、`TabSidebar.PagingContainerViewController`、`SidebarProfileIndicatorButton`（見出しの profile 名、52 pt 未満ならアイコンだけ） | Spec › Profile paging、Research › dia-profile-swipe-binary.md |
| space | profile の下位の切り替え | 二つの記述が食い違う。Spec は `spaces-ui-enabled` が 1.50.1 で既定オン、フッターに点の切替（`SpaceSwitcherView`）があると書く。Parity §5 は「flag-gated; changelog says Dia has no Spaces」と書く。本文書はどちらとも決めない | Spec › Profile paging、Parity §5 |
| command bar | URL・検索・Chat の入口 | Dia は Chromium の `AutocompleteController` を自前の Swift UI の下で使う（`ArcAutocompleteMatch`、`autocomplete:cursorPosition:preventInlineAutocomplete:`、`deleteAutocompleteMatch:`、`SwitchToTabProvider`）。URL クリックで toolbar に重なるパネル（幅約 890） | Omni 冒頭、Spec › URL click → command panel |
| split view | pane を並べる | Parity §6 は最大 3 pane と書く（Arc は推測で 4）。`DragDrop.SplitTargetView`（"Add left split"/"Add right split"） | Parity §6、Spec › Dragging tabs and split targets |
| 設定画面 | Dia の Settings | Cra の Dia 1.54.2 の観察: 778×509、`NSSplitViewController` と unified toolbar、ペインは Account・Tabs・Privacy・Profiles・Skills・Apps・Shortcuts・Advanced。Shortcuts は検索欄・フィルタ（Customized/Conflicting）・詳細欄 | Cra › Dia Settings window（L1121） |
| 窓の背景 | 透過とテーマ | 1.50.1 のバイナリ: `WindowTreatment` の `NSVisualEffectView`（material 29/13）+ base tint + profile のグラデーション。Metal の `WindowThemeUI` は Arc のコードで、1.50.1 では呼ばれていない | Spec › Window translucency |
| 取り込み | 他ブラウザからの取り込み | Cra の Dia 1.54.2 の観察: `ImportFlow`、Chromium・Firefox・Safari の importer、Arc の space の選択（`ArcPreviewContentView`） | Cra › Dia import onboarding（L881）、Dia onboarding steps（L952） |

---

## 3. データ形式（Arc からの取り込みに要る粒度）

すべて `~/Library/Application Support/Arc/` の JSON で、Cra 文書が利用者自身のデータを読んで記述したものである（本調査では読んでいない）。

### 3.1 共通の符号化

- **[O]** 辞書の代わりに平らな配列を使う: `[id, object, id, object, …]`。`containers`・`items`・`itemWidthFactors` が同じ形である。
- **[O]** Swift の enum は `{ "<case>": { "_0": <値>, "_1": <値> } }` の形で書かれる（例: `{space: {_0: {mostRecent: {}}}}`）。

### 3.2 StorableSidebar.json

- **[O]** `sidebar.containers` = `[ {global}, { spaces, topAppsContainerIDs, items } ]`。
- **[O] space**（`spaces` の要素）: `id`、`title`、`profile`、`containerIDs = ["pinned", <id>, "unpinned", <id>]`、`customInfo.iconType`（`emoji_v2`/`emoji`）、`customInfo.windowTheme`（第 2 節のテーマの行）。
- **[O] 項目**（`items` の要素）: `id`、`parentID`、`title`（ユーザーが名前を変えたときだけ非 null で、ページのタイトルより優先）、`childrenIds[]`（順序）、`isUnread`、`createdAt`、`originatingDevice`、`data` は次のどれか 1 つ。
  - `tab { savedURL, savedTitle, savedMuteStatus, timeLastActiveAt, activeTabBeforeCreationID, referrerID?, liveItemID? }`
  - `list {}`（folder。任意で `customInfo.iconType`、`automaticLiveFolderData`）
  - `itemContainer { containerType: topApps{profile} | spaceItems{spaceID} }`
  - `splitView { itemWidthFactors: [<id>, <factor>, …], layoutOrientation: horizontal|vertical, focusItemID, timeLastActiveAt, customInfo: {iconType}? }`。子は `childrenIds` で pane の順。触っていない split は `[firstChild, 0.5]` の 1 要素だけで、drag 後は全要素を持ち合計 1.0。[I] 欠けた factor は残りを等分。子 0 個の split が残ることがあり、Arc は同期時に修復する
  - [O strings のみ] `easel`、`arcDocument`、`tabGroup` も存在する
- **[O]** favorites は `topApps` container（profile ごとに 1 つ）、space は pinned と unpinned（Today）の container を 1 つずつ持つ。folder の入れ子は `parentID`。
- **[O]** サイドバーの favicon は `SidebarItemsFaviconCache` に `md5(項目 id)` の名前で 32×32 PNG がある。

### 3.3 StorableWindows.json

- **[O]** `windows[]` の各要素: `sidebarWidth`、`sidebarMode`、`focusedSpaceID`、`lastFocusedSpaceID`、`expandedItems`（folder の開閉、窓ごと）、`itemLastActiveDates`、`itemCreatedDates`、`splitViewState`（`windowContentIDs` と `focusedContentID` だけ。向きと幅はサイドバーの項目から作り直す）、`windowContents`、`spacesWithCollapsedPinnedSections`。
- **[O]** Little Arc は `little { profile: {default: true}, session: { entryPoint: { externalLink } }, preferredFrame }`。

### 3.4 StorableArchiveItems.json

- **[O]** 要素: `{ archivedAt, reason: manual|auto, source: space{id}|littleArc|standaloneSidebar|unknown, sidebarItem: <3.2 の項目の複製> }`。
- **[O]** 自動 archive の閾値: `twelveHours`・`twentyFourHours`・`sevenDays`・`thirtyDays`（profile ごと）。

### 3.5 StorableKeyBindings.json

- **[O]** 操作 = `{ identifier, name }`、割り当て = `{ keyEquivalent, deviceIndependentModifierFlags }`、`priority`、`typeTravelTriggers`。ユーザーの上書きを保存する。
- **[O]** `item1`〜`item9` = "Go to Sidebar Item N"、修飾 `1048576`（= `NSEventModifierFlagCommand`）。
- 修飾フラグは AppKit の `NSEvent.ModifierFlags` の値として読める **[I]**。

### 3.6 StorableLinkRouting.json（Air Traffic Control）

- **[O]** `{ rules: [ { id, sourceComponents: [ { id, componentType: { urlMatch: { _0: {contains: {}} | {matches: {}}, _1: "meet.google.com" } } } ], destination } ], defaultDestination, version: 1 }`。
- **[O]** 行き先: `{space: {_0: {mostRecent: {}}}}`、特定の space は `{space: {_0: {space: {_0: "<space id>"}}}}`、Little Arc は `{littleArc: {_0: …}}`（中の値は profile を選ぶだけ）。`matches` は UI の "Is equal to" に当たる **[I]**（保存は `matches`、分析用の型は `equals`、UI は "Is equal to" と名前が揃わない）。

### 3.7 StorableCommandBarAdditionalRanking.json

- **[O]** command bar の順位付けの学習データの置き場所として名前が挙がる。中身の構造は元文書に書かれていない **[U]**。信号の名前は第 2 節の command bar の行にある。

### 3.8 その他

- **[O]** Chromium の profile は `User Data/<profile>/`。拡張は `Secure Preferences` の `extensions.settings`、Web Store の拡張の manifest は `key` を持つので、複製して読み込めば同じ ID になる。pin は `extensions.pinned_extensions`。
- **[O]** PiP の位置は defaults の `LastPiPPosition`（JSON）。
- Dia: **[O]** `StorableProfileContainers.json`（profile ごとの container、`window`/`favorites`、`tabs[].contents[].variant = webContent{_0:{title,url}} | newTabPage`）、`StorableAutoArchive.json`（Cra › Dia 1.54）。
- Ardia は Arc のテーマの解析器と fixture を持つ（`state/import/arcTheme.ts`、`packages/import/fixtures/arc-themes`）。本調査ではコードを読んでいない。

---

## 4. Chromium 側の差し込み口（Dia の ArcCore）

### 4.1 構造（Dia 1.49.1〜1.50.1 の読み取り）

- ArcCore は content だけでなく `//chrome` を含む。`ChromeMain` を export し、Chrome の helper app（Browser Helper・Renderer・GPU・Alerts）を同梱する。全 helper は Dia の子プロセス（Research@2713787d › chromium-ui-layer.md › How Dia embeds Chromium）。
- `chrome/browser/ui/browser.cc` と `tabs/tab_strip_model.cc` を compile するが、`views/frame/browser_view.cc` は含まない。つまり Chrome の `Browser` と `TabStripModel` は使い、Views の窓枠は使わない（Arch › B › What Dia does）。
- 独自の `BrowserWindow` 実装は `arc/browser/ui/window.cc` で、Views の frame を持たない普通のオブジェクトである。Ardia の設計案は、ここから「複数の `Browser`（profile ごと）を同じ `NSWindow` に付け、タブの `WebContentsViewCocoa` を自前の view tree に直接入れる」ことを読み取っている（Arch › 5）。ただし複数 `Browser` を 1 窓に付ける点が Dia の実装として確認されたのか、Ardia の設計なのかは文面から区別できない **[I]**。
- web content を自前の view に入れる仕組み: `ArcWebContents (Extensions)` の `createPaneHostView`・`nativeView`・`attachToPaneHostView:`・`detachFromPaneHostView:`。ArcCore 側に `PaneHostBridge`・`WebContentsPaneHostView`・`PaneHostCompositorOverlayView`、Dia 側に `PaneHostSlotCoordinator`・`adoptExistingNativeView(nativeView:)`。描画は Chromium 標準の `CALayerHost` 経路（chromium-ui-layer.md）。
- 窓の上の blur は web view の `CALayerHost` の上に置いた `CABackdropLayer`（`LayerEffects.BackdropEffectView`）。renderer に `--enable-blink-features=TopBandColorSampling`（`arc/blink/core/top_band_color_tracker.cc`、タブの色付け用）を渡す（chromium-ui-layer.md）。
- Swift から使う API: 146 個の `Arc*` ObjC クラスと 205 個の公開ヘッダ（`Headers/arc/browser/objcpp/`）。mojom から生成（`ArcWebContents.h` は `web_contents.mojom` から）。サービスは `ArcBrowserContextHistory`・`ArcBrowserContextAutocomplete`（`-[ArcBrowser autocomplete:…]`）・`ArcBrowserContextDownloads`・`ArcBrowserContextExtensions`・`ArcBrowserContextPreferences`・`ArcSessionTab`/`ArcSessionWindow`・`restoreForeignTab:`。拡張が作るタブグループは `ArcBrowserDelegate createTabGroupWithSessionIds:` で Swift に戻る（Arch › 1, B）。
- `arc/` の源ファイルは 108 個、うち `arc/browser/ui/*.cc` は 45 個（Arch › B、chromium-ui-layer.md）。
- Dia のアプリ側は Swift・SwiftUI・AppKit で、自前のモデルに GRDB（SQLite）、Lottie と Sparkle を使う（Arch › B）。

### 4.2 置き換えている seam（名前が分かるもの）

元文書が名前を挙げているのは `window.cc` を含めて次の 10 個である。`window.cc` が 45 個に含まれるかは文面から決まらないので、残りは 35〜36 個で **[U]** である。

| `arc/browser/ui/` のファイル | 置き換える Chrome の UI（[I]、名前からの対応） | 出典 |
|---|---|---|
| `window.cc` | `BrowserWindow`（`BrowserView` の代わり） | Arch › 5, B |
| `browser_dialogs.cc` | `chrome/browser/ui/browser_dialogs.h` の各種ダイアログ | Arch › 5, B、chromium-ui-layer.md |
| `permission_prompt_impl.cc` | 権限のプロンプト（bubble・chip） | Arch › 5, B |
| `extension_install_prompt.cc` | 拡張のインストール確認 | Arch › 5, B、chromium-ui-layer.md |
| `password_dialog_prompts.cc` | パスワード保存・更新の bubble | Arch › 5 |
| `extensions_container.cc` | ツールバーの拡張の置き場（`ExtensionsContainer`） | Arch › 5 |
| `location_bar.cc` | `LocationBar`（omnibox の embedder 側） | Arch › 5, B、chromium-ui-layer.md |
| `autofill_popup_view.cc` | 自動入力の候補ポップアップ | Arch › B、chromium-ui-layer.md |
| `side_panel_ui.cc` | side panel | Arch › B |
| `views/overlay/video_pip_coordinator_impl.cc` | video PiP の窓 | Arch › B（Arc でも `arc::VideoPiPCoordinatorImpl` が確認されている。Cra › Picture in Picture） |

その他の `arc/` のファイルで名前が分かるものは `arc/browser/browser_impl.cc` と `arc/blink/core/top_band_color_tracker.cc` である。

### 4.3 Chromium の外（Swift 側）にあるもの

元文書から、次の機能は Chromium の UI を使わず Swift の shell が持つと分かる。

- サイドバー・space・favorites・folder・archive（`Storable*.json` の側）
- split view（Arc: Chromium の split 機能を使わない。Cra › Split View）
- command bar の UI と順位付け（候補の生成は Chromium の `AutocompleteController`。Arc は archetype の名前 `chromium*` から [I]、Dia は Omni と Arch で確認）
- ダウンロードの UI（ADK の delegate 経由。Cra › Downloads）
- 拡張のポップアップの窓（ArcCore の delegate から web contents を受け取る。Cra › Extension popups）

逆に Chrome のものをそのまま使うのは DevTools（frontend は `can_dock=true`、dock 状態は Chrome の prefs）と Task Manager（Parity §23 の記述では Dia の Window メニューから Chrome の Task Manager を開く）である。

### 4.4 Ardia 自身の差し込み口（参考。Dia の事実ではない）

Ardia は Dia を手本に ArcCore 方式の `ArdiaCore` を作り、Chrome のファイルに小さな hook（H1〜H6、`browser.cc` の窓 factory、`sad_tab_controller.cc`、`external_protocol_handler.cc`）を足している。host に出す UI は権限のプロンプト（`SetCreatePermissionPromptFunction`）、ポップアップのブロック、外部アプリへのリンク、拡張のインストール確認、拡張の action・side panel、device chooser、Cast、context menu である（`docs/ardiacore-spike.md` › Stage 1, Stage 2）。これは Ardia の実装であり、Dia の 45 個の内訳の推定には使っていない。

---

## 5. Dia の UI 寸法と動き（サイドバーと窓の操作感）

すべて Spec（Dia 1.50.1 のバイナリと所有者の録画）から。「Ardia」「Ours」と書かれた値は除いた。

### 5.1 窓とカード

| 項目 | 値 | 出典 |
|---|---|---|
| サイドバーの既定幅 | 190 pt（保存値があればそれ） | Spec › Sidebar rows |
| 信号機の中心 | x 24.75 / 47.75 / 70.75、y 26.75（上部タブ配置では 4 pt 左・6 pt 上） | Spec › Sidebar rows、Top tab strip |
| content card | x = サイドバー幅、上 6・右 7・下 7、角 10 | Spec › Content card |
| ツールバー | 高さ 41、ボタンの中心はカード左端から 21 / 55 / 92 / 126、glyph は SF Symbols 13 pt | Spec › Toolbar |
| 窓の背景 | `NSVisualEffectView`（behindWindow、material 暗 29 / 明 13）→ base tint（黒 0.4 / 白 0.8）→ profile のグラデーション（alpha 暗 0.5 / 明 0.75、`gradientAlpha` 0.36、neutral 0.12、下端は HSL 明度 +0.25）→ カード（#121212 0.5 / 白 0.7） | Spec › Window translucency |
| 非アクティブ時 | AppKit が blur を不透明の塗りに替える。Dia は Reduce Transparency を自分では見ない | 同上 |

### 5.2 サイドバーの寸法

| 項目 | 値 | 出典 |
|---|---|---|
| 見出し | 46 pt（信号機、6 pt、profile 表示、2 pt、Downloads） | Spec › Sidebar、Sidebar rows |
| pinned のタイル | 高さ 41、間隔 6、左右 inset 6、上端 54、角約 10 | Spec › Sidebar |
| タブの行 | 37 pt pitch、背景 34 pt（上下 1.5 の inset）、左右 inset 6、角 `min(h/3, 10)` | Spec › Sidebar rows |
| favicon とタイトル | favicon 16 pt を行の x 9、タイトルは favicon の右 7 pt、13〜14 pt、末尾は省略記号でなく fade | Spec › Sidebar、Sidebar rows |
| スクロール境界 | dock の下 4 pt に 1 pt の線、スクロールで 0.1 s（cubic-bezier(0.25, 0.46, 0.45, 0.94)）で出る | Spec › Sidebar rows（1.53.0） |
| フッター | 41 pt、Library を左、space の点の帯 28 pt（1 点 12 pt、7 点まで） | Spec › Profile paging |
| hover・選択の塗り | hover 白 16%（暗）/ 55%（明）、押下 31% / 70%、選択 #121212 0.5（暗）/ 白 0.7（明） | Spec › Sidebar、1.50 delta 6 |

### 5.3 動き

| 操作 | 値 | 出典 |
|---|---|---|
| サイドバーの開閉（⌘S） | spring 1 本、response 0.215 s、damping ratio 0.79。100 ms で 90%、約 0.15 s に 1〜2 pt の行き過ぎ、約 0.27 s で静止。サイドバー・信号機・カードの左端が一緒に動き、右端は動かない。ページは途中も layout される | Spec › Hiding and showing the sidebar |
| （参考）Arc のサイドバーを隠す | ease-out cubic 100 ms。Cra の計測でも約 5 フレームで 66% → 87% → 96% → 99% | Spec › Arc note、Cra › Backdrop-layer blur（L841） |
| タブを開く | 新しい行は最終位置に即座に出て選択済み。下の行は 1 pitch 下へ滑る: cubic-bezier(0.25, 0.1, 0.25, 1)、0.14 s | Spec › Opening and closing tabs |
| タブを閉じる | 閉じた行はその場で fade（cubic-bezier(0, 0, 0.58, 1)、0.10 s）、下の行は同時に 0.14 s で上へ滑る。hover は最終 layout に即座に従う | 同上 |
| 行の背景の変化 | 0.3 s easeOut | Spec › 1.50 delta 9 |
| hover card | 表示: opacity 0.10 s（cubic-bezier(0.25, 0.46, 0.45, 0.94)）+ scale 0.92→1 の spring（ζ 0.75、response 0.25 s）、左上の角を中心に拡大。消去: 0.10 s + scale 0.92 への spring（ζ 0.6、0.2 s）。表示の待ち 0.5 s か 0.1 s（どちらになるかの条件は未特定）、別の card が出ていれば 0。行から行へは窓を移して中身を替えるだけ | Spec › Tab hover card motion |
| profile のページング | 移動量は `scrollingDeltaX × −0.5`。端の rubber band `255·(1 − 1/(0.15·x/255 + 1))`。離した速さが 5 pt/s 以上なら速さの向きの次のページ、未満なら近いページ。速さは位置の 100 ms 履歴から計算。settle は critically damped spring（response 0.25 s、旧 0.4 s）を 1/240 s ごとに標本化した `CAKeyframeAnimation`（`space_swipe_settling`）。ページの選択は settle の開始前に通知する。ホイールは 0.049 s 以内の入力を合算し、1 pt を超えたら 1 ページ送り、0.25 s 無視 | Spec › Profile paging、Research › dia-profile-swipe-binary.md |
| 分割へのドラッグ（上部タブ配置で計測） | タブを持ち上げると 209×109.5 の窓の絵がポインタに付く。分割の的の上で離すと新しい pane が落とした側から入る。的の外で離すと約 0.2 s で新しい窓が広がる | Spec › Dragging tabs and split targets |
| タブの並べ替え（上部タブ配置で計測） | 隣のタブは critically damped spring（ω ≈ 90 rad/s、約 0.07 s）で場所を譲る | 同上 |

---

## 6. 出典の版、読めなかった箇所、推測の箇所

### 6.1 出典ごとの版

| 出典 | 取得した版 | 対象の版 |
|---|---|---|
| Cra `docs/arc-reverse-engineering.md` | commit `ef345193`（2026-10-28） | 冒頭は Arc 1.168.0（build 88413）。以降は 1.168.0 と 1.170.0（89123）の節が混在し、各見出しが版を示す（例: Little Arc の節は 10-24 付だが 1.168 の観察）。第 2 節の表の版は行ごとに異なる。Dia の節は 1.54 と 1.54.2。方法は REA CLI 6.4.0、`strings`、Swift の reflection metadata、`otool -oV`、利用者の JSON、Accessibility と画面の録画。逆コンパイラは使っていない |
| Ardia `docs/dia-spec.md` | `efcbaba7`（2026-10-28） | Dia 1.49.1 が基準、1.50.1（87750）のバイナリ、1.52 の録画、1.53.0 のバイナリ |
| Ardia `docs/dia-feature-parity.md` | `d8e1098b`（2026-10-29） | Dia 1.49.1（87398）と changelog（1.50.0 まで）。行の一部は 1.53 まで更新 |
| Ardia `docs/omnibox-ux.md` | `5686af30`（2026-10-26） | 2026-10-08 の監査、Chrome 154 の tree |
| Ardia `docs/research/dia-profile-swipe-binary.md` | `8dcfe369`（2026-10-12） | Dia 1.50.1、arm64 UUID C3CA2D1A… |
| Ardia `docs/research/profile-swipe-native-controller.md` | `a5157342`（2026-10-26） | Ardia 0.2.18 の実装記録（Dia の値を引用） |
| Ardia `docs/architecture-review.md` | `?ref=2713787d` で取得。本文の冒頭は「Reviewed at `b885f89c`（2026-10-01）」 | Dia 1.50.1、ArcCore compat 8037.0.58（Chromium 154） |
| Ardia `docs/research/chromium-ui-layer.md` | `?ref=2713787d` | Dia 1.49.1、ArcCore 153.0.8010.53 |
| Ardia `docs/research/chrome-hosted-window.md` | `?ref=2713787d` | Dia 1.50.1、ArcCore 154.0.8037.58 |
| Ardia `docs/ardiacore-spike.md` | main（2026-10-29 時点の HEAD `12ad9cd8` の tree） | Ardia の実装（第 4.4 節だけで使用） |
| 手元の Arc.app | — | Arc 1.170.0（89123）、build 21 Oct 2026、ArcCore 8078.0.48 |

Arc の情報は 1.168.0・1.170.0、Dia の情報は 1.49.1〜1.54.2 にまたがる。同じ名前の型でも版で中身が変わりうる。

### 6.2 読めなかった箇所・取り込んでいない箇所

- Arc の Settings 窓の全体構成、profile の管理画面、Peek（リンク）の寸法と動き、command bar の順位付けの重み（CoreML）、`StorableCommandBarAdditionalRanking.json` の構造は、読んだ範囲の元文書には書かれていない。
- Dia の `arc/browser/ui/*.cc` 45 個のうち、名前が分かるのは `window.cc` を含めて 10 個である。
- 現在の Ardia の `docs/research/` には 2 ファイルしかない。@2713787d にあった `chromium-ui-layer.md` と `chrome-hosted-window.md`（Dia・ArcCore に触れる）は旧版から読んだ。画像（`chrome-hosted-window/*.jpg`）は読んでいない。
- `docs/dia-feature-parity.md` は §1〜§8 と §20〜§23 の表、および Arc に触れる行だけを読んだ。§9〜§19・§24〜§25（AI・ブックマーク・履歴・パスワード等）は読んでいない。
- `docs/dia-spec.md` の New Tab page・色トークン・PiP・メニューの節は、サイドバーと窓の操作感に関係しないので要約に入れていない。
- 本調査は Arc の `Resources/` の中身、`strings`、逆アセンブル、ユーザーのデータを見ていない。

### 6.3 推測の箇所（本文書で [I] とした主なもの）

- ArcCore 8078.0.48 が Chromium 156 系であること（第 1.1 節）。
- 「ARC」が framework ではなく実行ファイル内のモジュール群の名前空間であること（第 1.3 節）。
- Sentry・Firebase・grpc の用途（第 1.5 節）。
- Arc の ArcCore が Dia と同じ ObjC API を持つこと（第 1.4 節）。
- Arc の command bar が Chromium の `AutocompleteController` の結果を使うこと（archetype 名からの推測。第 4.3 節）。
- `arc/browser/ui/*.cc` の各ファイルが置き換える Chrome の UI の対応（ファイル名からの推測。第 4.2 節）。
- Dia が複数の `Browser` を 1 つの `NSWindow` に付けること（Ardia の設計案と区別できない。第 4.1 節）。
- split view の上限 4 枚、欠けた `widthFactor` の扱い（Cra 文書の [I] をそのまま保持）。

### 6.4 元文書と観察の食い違い

- Cra 文書は「Framework "ARC"」と書くが、Arc 1.170.0 の `Contents/Frameworks` に `ARC.framework` は無い（第 1.3 節）。
- Dia の space の有無について、`dia-spec.md`（`spaces-ui-enabled` が既定オン、点の切替あり）と `dia-feature-parity.md`（changelog では Dia に Spaces は無い）が食い違う。
- split view の pane の上限は、Arc が推測で 4（Cra）、Dia が 3（Parity）である。別の製品の値なので矛盾ではないが、同じ「ArcCore 系」としてまとめないよう注意が必要である。
- `architecture-review.md` は @2713787d で取得したが、本文は `b885f89c` 時点のレビューと名乗る。
