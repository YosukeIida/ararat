# U20 モックとの照合

照合元は `~/.config/herdr-agent-team/ararat/reports/design-u20/u20mock/project` にあるオーナーの U20 プロジェクトである。各ページと併せて、`reports/design-u20` の `mock-decisions.md` と `ui-inventory.md` を参照する。図とオーナー決定が異なる場合は決定を優先する。このディレクトリには 76 ページがあり、Batch A のリンク 7 件に対応するページも同名で収録されている。

## トークンテストと構造検査

[照合表](research/mock-values.json)には 89 件あり、このうち Swift との比較対象は 77 件で、全件一致した。残る 12 件は、オーナーの寸法規則や selshadow で扱う選択行の影など、照合表に理由を記載した項目である。CSS 変数の値がライトとダークで異なる場合は、一つの宣言に二つの照合項目が対応することがある。

76 ページから抽出した CSS 宣言の候補は 27,782 件で、88 件を確認し、27,694 件の分類が残った。候補には、ページ間で共有する規則、注釈、インラインで指定した状態差、未実装画面の値も含む。この件数は残りの候補数の上限であり、Swift に対応付ける必要がある件数は未確定である。集計時に、照合表の各セレクタ、プロパティ名、値が記載の行にあることも検査する。

```sh
MOCK_PROJECT="$HOME/.config/herdr-agent-team/ararat/reports/design-u20/u20mock/project"
direnv exec . env -u DEVELOPER_DIR -u SDKROOT swift test --package-path macos --no-parallel --filter MockParityTests
uv run --no-project python macos/scripts/mock-values/census.py "$MOCK_PROJECT"
```

VM では `split-focus`、`split-commands`、`dock`、`urlfield`、`folder-empty`、`today` を `--ararat-screen=<name>` で実行する。[画面チェックの実行例](architecture.ja.md)に従い、一時プロファイルとワークスペースを用意する。出力に記録された PNG と、拡張子以外のファイル名が同じ JSON を一緒に取得する。JSON の座標はウィンドウ座標系で、単位は pt である。領域撮影の JSON にはチェック対象のウィンドウのビュー階層が入る。検査対象は分割セグメント、サイドバーに共通のナビゲーション、Library の位置、URL 欄のボタン、空フォルダの行、Today の区切り線である。AppKit のメニューとページ内の DOM は別途確認する。

```sh
uv run --no-project python macos/scripts/mock-values/check_structure.py /path/to/copied/sidecars/*.json
# 1 回分だけを検査する場合は --screen split-focus とその JSON を渡す。
```

## 比較画像

ホストでモックをレンダリングする際は、VM から取得した PNG を指定する。スクリプトは PNG のピクセル寸法を読み、専用の一時プロファイルでヘッドレス Chrome を実行する。モックの縦横比を保ち、指定の寸法に収める。一つのページに見本が複数ある場合は、`--selector` で対象の CSS セレクタを指定する。出力先はいずれも `$TMPDIR` 内で、コマンドがパスを表示する。比較画像の左側がモック、右側が VM の撮影画像である。

```sh
VM_PNG=/path/to/copied/captures/split-focus-a.png
MOCK_PNG="$(uv run --no-project python -B macos/scripts/mock-values/render_mock.py "$MOCK_PROJECT/A-TabRows.dc.html" --capture "$VM_PNG")"
uv run --no-project python -B macos/scripts/mock-values/pair_pngs.py "$MOCK_PNG" "$VM_PNG"
```

## 資料と実装の相違

`B-Split.dc.html:20` は説明文でセグメントに言及しているが、図では分割行の背景全体を一つに塗っている。セグメントごとの背景は `A-TabRows.dc.html:79–82` で定義され、Swift もこの定義に従う。非フォーカス時の背景はライトとダークの両方でホバー色の CSS 変数を参照する。

[アーキテクチャ §7](architecture.ja.md)ではオンボーディングを SwiftUI としている。[OnboardingWindow.swift](../macos/Sources/AraratUI/OnboardingWindow.swift) は AppKit で実装している。

[アーキテクチャ §7](architecture.ja.md) と Little Window のコードでは 46 pt をモック独自の値として扱っている。[Cra の Arc 調査](research/arc-dia-components.ja.md)と [Yab との比較](research/yab-values.ja.md)には Arc の値として 46 pt が記録されている。実装は 48 pt であり、値の出典が確定するまで、照合表にはオーナーの寸法規則を理由として記載する。

`commandbar` の画面チェックは挙動を検査し、JSON を出力する。通常のコマンドパネルとタブ切り替え画面の PNG は出力しない。

## ページ別の照合結果

VM チェック欄はチェック名と対象の段階を示す。「一致」「相違あり」は、根拠欄に示した範囲の判定である。外観の判定は、設計担当が VM で撮影した画像をモックと比較した後に記録する。

| モックページ | 要素 | VM チェック | 状態 | 根拠または確認事項 |
| --- | --- | --- | --- | --- |
| `A-BottomDock` | Library、追加メニュー、スペースセル | `dock (cells)` | 未撮影 | VM ではセルとドロップ拒否を確認する。 |
| `A-BottomDock` | 現在のスペースセルと他スペースのドット | `dock (cells, mid)` | 未撮影 | 表示中のスペースが変わると選択背景がクロスフェードする（決定 69）。 |
| `A-FavouriteTiles` | ファビコンタイル、読み込み、音声、未読マーク | `organize (first-favorite)` | 未撮影 | 最初のタイルを撮影する。ほかの状態には個別のフレームが必要である。 |
| `A-FavouriteTiles` | お気に入りが空のときの領域 | — | 未撮影 | プレースホルダーを表示せず、領域をたたむ（決定 13）。 |
| `A-Folders` | 展開したフォルダ、空行、現在の行の保持 | `folder-empty (line, drop)` | 未撮影 | 空行の高さ 24 pt と文字サイズ 12 pt はトークンテストで一致した。 |
| `A-Header` | 幅に応じたナビゲーションとツールチップ | `header (widths, tooltip, loading, stopped)` | 未撮影 | Reload は 200 pt、サイドバー切り替えは 232 pt で表示する（決定 7–10）。 |
| `A-Header` | ショートカット押下中と狭い幅でのオーバーフロー | `header (command-r, command-r-narrow, command-w)` | 未撮影 | コントロールとキーキャップの押下時の表示を比較する（決定 9–10）。 |
| `A-Header` | ヘッダーのオーバーフローメニュー | — | 未撮影 | 項目は header チェックで検査する。ネイティブメニューの外観は別途撮影する。 |
| `A-Layout` | サイドバーの配置 | `header (240)` | 未撮影 | 既定幅 240 pt と選択行の寸法はトークンテストの対象である。 |
| `A-SpaceName` | 名前、シェブロン、メニュー、ピンの折りたたみ | `space-name (hover, collapsed, renamed)` | 未撮影 | オーナーの寸法規則に従い、シェブロンの操作領域は 16 pt とする。 |
| `A-TabRows` | ピンと Today の行、スピナー、未読、クラッシュ、音声 | `sidebar-rows (rows, loading, unread, crashed, muted)` | 未撮影 | 未読ドットの寸法と、ライト・ダークのホバー色および押下色はトークンテストの対象である。 |
| `A-TabRows` | 分割セグメントの寸法と非フォーカス時の背景 | `split-focus (a), split-commands (vertical, split)` | 一致 | 対応表に載せた寸法と両外観の非フォーカス時の背景は、トークンテストとオフスクリーンテストで一致した。 |
| `A-TabRows` | 複数選択 | — | 未実装 | 複数選択はフェーズ 5 より後に実装する（§7）。 |
| `A-TabRows` | 選択行と選択セグメントの影 | `sidebar-rows (rows), split-focus (a)` | 未撮影 | 選択行の影は selshadow で扱う。 |
| `A-TabRows` | 読み込み中とクラッシュのアイコン | `sidebar-rows (loading, crashed)` | 未撮影 | 読み込み中はファビコンの位置にスピナーを表示する（決定 15）。 |
| `A-TabRows` | 未読の行とミュートした行 | `sidebar-rows (unread, muted)` | 未撮影 | 未読ドットは、読み込み済みで非表示のタブのタイトル変更を契機に付く（決定 19、24）。 |
| `A-TabRows` | 行のアーカイブと閉じるボタン | `header (command-w), sidebar-rows (rows)` | 未撮影 | 行の種類と読み込み状態に応じてアクションが変わる（決定 29、32）。 |
| `A-TodayNewTab` | Today の区切り線、Clear、New Tab | `today (today, cleared, new-tab-row)` | 未撮影 | 区切り線と Clear の表示は Today の内容で決まる（決定 39）。 |
| `A-TodayNewTab` | Clear 後の区切り線 | `today (cleared)` | 未撮影 | Today が空になった後に区切り線が消えることを構造検査で確認する。 |
| `A-TodayNewTab` | Appearance で New Tab を非表示 | — | 未撮影 | 設定は Today チェックで操作する。new-tab-row の PNG は再度表示した後の状態である。 |
| `B-CreateSpace` | スペース作成フォーム | `space-name (create-page)` | 未撮影 | フォームはサイドバー内に表示する。 |
| `B-CreateSpaceStates` | スペース作成の成功と失敗 | `create-space (created, failure)` | 未撮影 | 既存のチェックで成功と失敗を撮影する。 |
| `B-Drag` | サイドバーのドロップ位置、フォルダ上のホバー、拒否 | `organize (drop, hover-open), dock (refused)` | 未撮影 | 行のドラッグと、別プロファイルへのドロップ拒否を確認する。 |
| `B-Drag` | 別プロファイルへのドロップ拒否 | `dock (refused)` | 未撮影 | セルを暗くし、ポインタに拒否マークを付ける（決定 68）。 |
| `B-DragPage` | 分割を作るページ上のドロップ領域 | `split-commands` | 未撮影 | チェックではドロップ範囲の表示を検査する。保存するフレームはメニューと分割成立後の状態である。 |
| `B-Floating` | フローティングサイドバーの配置と内容 | — | 未撮影 | フローティング時の挙動は SidebarContainerView に実装されている。 |
| `B-FloatingDark` | ダークのフローティングサイドバー | — | 未撮影 | ダークの外観で撮影が必要である。 |
| `B-FloatingMotion` | 端からの表示、待機時間、非表示 | — | 未撮影 | 表示のタイミングは別のチェックで扱う。静止画からは判定できない。 |
| `B-Fullscreen` | ページとブラウザの全画面表示、端からの表示 | `fullscreen (page, browser, edge)` | 未撮影 | 状態ごとに撮影する。 |
| `B-History` | 履歴削除のエラーバナーと Retry | `toasts (banner)` | 未撮影 | 削除失敗時に同一プロファイルの全ウィンドウで表示する（決定 56）。 |
| `B-HistoryStates` | 履歴ストアの失敗と再試行 | `toasts (banner)` | 未撮影 | 失敗時のバナーを撮影する。再試行に成功するとバナーは消える。 |
| `B-Library` | Library のレールとアーカイブ一覧 | — | 未撮影 | Downloads の撮影対象は Library 内の別のページである。 |
| `B-LibraryStates` | アーカイブ一覧の状態 | — | 未撮影 | 検索、復元、削除は LibraryView に実装されている。 |
| `B-Menus` | 行、スペース、分割のネイティブメニュー | `split-commands (menu)` | 未撮影 | VM チェックは分割メニューの項目とアイコンを検査する。サイドバーのメニューの外観は未確認である。 |
| `B-NoTab` | 空のページカードとショートカット案内 | — | 未撮影 | サイドバーを表示した空のワークスペースの撮影が必要である。 |
| `B-SpacePaging` | ページ切り替えとドックのクロスフェード | `dock (mid)` | 未撮影 | ホイールによるページ切り替えのタイミングは別のチェックで記録する。 |
| `B-Split` | 2 ペイン、フォーカスリング、共通のナビゲーション | `split-focus (a, b)` | 未撮影 | ナビゲーションはサイドバーに置く（決定 65）。このページのサイドバー図では背面の塗りが行全体で一つになっている。 |
| `B-SplitStates` | 複数ペイン、仕切り、ドラッグ、移動 | `split-commands (vertical, split), split-focus (frozen, release), dialogs (transfer)` | 未撮影 | 説明文は Swift が連続した仕切り線を描くとする。SplitDividerView はホバー中とドラッグ中にグリップを描画する。 |
| `B-SplitStates` | 一つのサイドバー行に並ぶ 3 ペイン | `split-commands (vertical)` | 未撮影 | ページを縦に並べた状態でもサイドバーの三つのセグメントは横並びとする。 |
| `B-Tooltips` | ボタンと行のツールチップ、キーキャップ | `header (tooltip, command-w)` | 未撮影 | 同じキーと配置でも AppKit と CSS の描画には差が出る。 |
| `B-WindowStates` | ウィンドウ枠、最小幅、非アクティブ状態 | `window-drag (sidebar)` | 未撮影 | ドラッグの画像はサイドバーを撮影する。非アクティブ時の色は別途撮影する。 |
| `C-DialogHost` | ページカード上のダイアログ | `prompts, dialogs` | 未撮影 | ホストの PNG と別に出力されるダイアログの PNG を使う。 |
| `C-Downloads` | Library の進捗、ポップオーバー、全履歴 | `downloads (flight, ring, popover, library, popover-complete)` | 未撮影 | ポップオーバーの行の高さは 48 pt で一致した。間隔の例外はトークン表に記載した。 |
| `C-Downloads` | 進捗リングとファイルアイコンの移動 | `downloads (ring, flight)` | 未撮影 | 視差効果を減らす設定ではアイコンの移動を省く（§7）。 |
| `C-Downloads` | 処理中と完了後のポップオーバー | `downloads (popover, popover-complete)` | 未撮影 | 各段階の状態表示と実行できるアクションを比較する。 |
| `C-Downloads` | Library のダウンロード履歴 | `downloads (library)` | 未撮影 | 全履歴を表示した Library を撮影する。 |
| `C-Extensions` | URL 欄のピン留め拡張機能とオーバーフロー行 | `ext-actions (action, overflow, three-actions)` | 未撮影 | ホスト名に最低 64 pt を確保する（決定 47）。 |
| `C-Extensions` | 拡張機能アクションのオーバーフロー | `ext-actions (overflow, three-actions)` | 未撮影 | アイコンの寸法、行の高さ、複数行に折り返す条件を個別に確認する。 |
| `C-Permissions` | 権限の確認とブロック済みサイトの表示 | `prompts, site-controls (popover)` | 未撮影 | シートとサイトコントロールの状態は別々に撮影する。 |
| `C-SiteControls` | 撮影タイルとセキュリティ表示 | `site-controls (popover, certificate)` | 相違あり | モックでは四つのアクションを描く。製品には §7 に記載した二つを実装している。 |
| `C-SiteControls` | 縦長キャプチャ、翻訳、拡張機能グリッド、未実装の設定 | — | 未実装 | 対象の機能は §7 と §14 で実装を見送っている。 |
| `C-SiteControlsStates` | ポップオーバーの各状態の寸法 | `site-controls (popover, overlay, toast)` | 未撮影 | 幅、パディング、間隔、ボタン寸法はトークンテストの対象である。 |
| `C-SiteControlsStates` | 証明書シート | `site-controls (certificate)` | 未撮影 | セキュリティ表示から開く（決定 5）。 |
| `C-UrlField` | ホスト名、プレースホルダー、末尾のボタン | `urlfield (host, placeholder, internal, long-host)` | 未撮影 | ページ選択時に二つのボタンが URL 欄の子であることを構造検査で確認する。 |
| `C-UrlField` | 長いホスト名と狭い URL 欄 | `urlfield (long-host, long-host-narrow)` | 未撮影 | 二つの幅でホスト名の省略とボタンの表示を比較する。 |
| `CommandBar` | 概要のコマンドパネル | — | 未撮影 | commandbar モードは条件の結果を出力するが、PNG は出力しない。 |
| `D-CommandBar` | 検索を先頭に出す入力欄と履歴 | `little-window (command-bar)` | 未撮影 | Little Window で撮影するのは Edit URL である。通常ウィンドウの検索パネルには別の撮影が必要である。 |
| `D-CommandBarPanels` | コマンドパネルの各状態 | — | 未撮影 | commandbar チェックは複数のモードで結果を検査する。 |
| `D-CommandBarRows` | 結果行の寸法、内側余白、行間 | — | 一致 | 対応表に記載した行と入力欄の寸法は一致した。行の外観は未確認である。 |
| `D-ErrorPages` | オフラインと DNS のエラー | `errorpages (offline, dns)` | 未撮影 | ネイティブのエラーページを各状態で撮影する。 |
| `D-FindBar` | ページ内検索バーと件数 | — | 未撮影 | FindBarView に実装がある。検索語を入力し、結果がある状態を撮影する。 |
| `D-FindBarPage` | ページ上の検索バー | — | 未撮影 | ページと表示中の検索バーを同じウィンドウで撮影する。 |
| `D-LittleWindow` | バー、Open in メニュー、プロファイルメニュー、コマンドバー | `little-window (bar, profile-menu, space-menu, command-bar)` | 未撮影 | 対応表はバーの高さ 48 pt の例外を記録し、色とコントロールの値を照合する。 |
| `D-PrivateWindow` | プライベートウィンドウと URL 欄のマスク | `private-window` | 未撮影 | プライベートブラウザのウィンドウを撮影する。 |
| `D-PrivateWindowEmpty` | 空のプライベートウィンドウ | — | 未撮影 | 既存の private-window 撮影はページを開いた状態で行う。 |
| `D-SadTab` | クラッシュした Today タブとピン | `errorpages (today-crash, pin-crash)` | 未撮影 | Archive Tab と Close Tab の状態を個別に撮影する。 |
| `D-TabSwitcher` | Control-Tab の切り替え画面 | — | 未撮影 | commandbar チェックは切り替えと取り消しを検査する。PNG は出力しない。 |
| `D-Toasts` | コピー完了、Clear の Undo、失敗バナー | `toasts (toast, banner)` | 未撮影 | 履歴削除の失敗時はプロファイル内のウィンドウにバナーを表示する（決定 56）。 |
| `D-Toasts` | 更新完了と Restart | — | 未実装 | 更新機能は後のフェーズで実装する（§15）。 |
| `Dark` | ダークのブラウザ全体 | — | 未撮影 | ウィンドウ全体を比較するため、ダークのワークスペースを撮影する。 |
| `E-About` | About と更新状態 | — | 未実装 | 現行の設定画面に About ペインはない。 |
| `E-AirTraffic` | ルーティング規則と移動先の編集 | `settings-air-traffic` | 未撮影 | 既定の移動先とルールの編集を VM で確認する。 |
| `E-Appearance` | 外観の設定 | `settings-appearance (appearance, theme-light, theme-dark, theme-system)` | 未撮影 | テーマ、Look、New Tab 行、ツールチップ、ズームを実装している。 |
| `E-Controls` | 設定画面のコントロールと操作時の状態 | `settings-frame, settings-appearance` | 未撮影 | 行内に AppKit と SwiftUI のネイティブコントロールを使う。 |
| `E-Extensions` | インストール済み一覧、プロファイルメニュー、レビュー | `settings-extensions (extensions, extensions-profile2, extensions-review)` | 未撮影 | インストール済み一覧は Chromium を通して取得する。 |
| `E-Extensions` | Arc から追加 | — | 未実装 | インポート元の調査と権限の設計が必要である（§14）。 |
| `E-Frame` | 設定画面のツールバー、レール、カード | `settings-frame (frame), settings-toolbar (toolbar-top, toolbar-scrolled)` | 未撮影 | グループカードの角丸と間隔は対応表の値と一致した。 |
| `E-General` | 既定ブラウザ、起動時の動作、ダウンロード | `settings-general (general)` | 未撮影 | この三項目はフェーズ 5 で実装した（§7）。 |
| `E-General` | General の残りの設定 | — | 未実装 | 終了前の確認、検索候補、検索エンジン、スペルチェックは後の実装とする（§7）。 |
| `E-LittleWindow` | ショートカット、移動先、閉じる動作、サイズと位置の保持 | `settings-little-window (little-window)` | 未撮影 | 設定チェックで Little Window の各行を操作する。 |
| `E-Passwords` | 保存済みパスワードと Touch ID | — | 未実装 | U20 のパスワード設定は計画段階にある。 |
| `E-Privacy` | 閲覧データの消去、保持期間、Cookie とプライバシー設定 | `settings-privacy (privacy, privacy-sheet)` | 未撮影 | 保護機能の仮の項目はこのフェーズの製品に表示しない（§7）。 |
| `E-Privacy` | ブロッカーと危険なサイトの警告 | — | 未実装 | 方式と情報源は未決定である（§14）。 |
| `E-Search` | 設定内検索と該当項目の強調 | `settings-search (search, search-cleared)` | 未撮影 | 検索結果の強調表示の角丸、内側余白、行の高さはトークンテストの対象である。 |
| `E-Shortcuts` | ショートカット一覧、入力、競合の表示 | `settings-shortcuts (shortcuts)` | 未撮影 | 入力と競合の手順を含む既存のフィクスチャを使う。 |
| `E-SpacePage` | スペース個別の設定 | `settings-tabs (space-page)` | 未撮影 | tabs チェックがスペース個別のページへ移動する。 |
| `E-Spaces` | スペース一覧とスクロール方向 | `settings-spaces (spaces)` | 未撮影 | スクロール方向はワークスペース全体の設定である。 |
| `E-Sync` | 同期設定とデバイス | — | 未実装 | 同期はフェーズ 8 で実装予定である（決定 100）。 |
| `E-Tabs` | タブ設定とスペースへの移動 | `settings-tabs` | 未撮影 | タブ設定とスペース個別の設定への移動を確認する。 |
| `E-Websites` | 既定とサイト別の権限 | `settings-websites (websites, site-row, site-page)` | 未撮影 | サイト別の設定を作成してからページを開く。 |
| `Extensions` | ピン留めした拡張機能の概要 | `ext-actions (action, overflow)` | 未撮影 | 配置は URL 欄に関する決定 42 に従う。 |
| `F-Import` | インポート対象の選択、進捗、完了 | `onboarding (what-to-import, progress, done)` | 相違あり | フィクスチャを使うフローでは、ログイン状態、パスワード、履歴、アーカイブの行を省いている（§7）。 |
| `F-Import` | ログイン状態の引き継ぎとキーチェーン権限 | — | 未実装 | キーチェーンを使うフローにはインポートの調査が必要である（決定 105–106）。 |
| `F-LookControls` | 透明度、Glass のデテント、粒状感、メニュー | `look (55, detent, glass)` | 未撮影 | 透明度の位置と Glass のデテントを撮影する。 |
| `F-LookGallery` | プリセットとカラーピッカー | `look (popover)` | 未撮影 | モックと同じプリセットページを開いた状態で比較する。 |
| `F-LookPopover` | Look ポップオーバーと色の入力欄 | `look (55-popover, glass-popover)` | 未撮影 | 該当するモック内の見本とポップオーバーのフレームを組み合わせる。 |
| `F-LookSidebar` | 設定値ごとのスペース色とサイドバー | `look (55-sidebar, detent-sidebar, glass-sidebar)` | 未撮影 | サイドバーとポップオーバーを対応する組として記録する。 |
| `F-LookStates` | カラーピッカー、プリセット、粒状感の各状態 | `look` | 未撮影 | Look チェックは Glass と粒状感の状態を記録する。 |
| `F-Onboarding` | ようこそ、ソース、対象選択、既定ブラウザ、進捗、完了、二つのエラー | `onboarding (eight fixture states)` | 未撮影 | ボタンの高さと間隔の例外はオーナー決定としてトークン表に記載した。 |
| `F-Onboarding` | ようこそとインポート元の検出 | `onboarding (welcome, source)` | 未撮影 | インポート元のチェックは Arc 検出のフィクスチャを使う。 |
| `F-Onboarding` | インポート対象と既定ブラウザの設定 | `onboarding (what-to-import, default-browser)` | 未撮影 | インポート対象の行と既定ブラウザの操作を個別に確認する。 |
| `F-Onboarding` | キーチェーンのアクセス要求 | — | 未実装 | 3a はログイン状態を引き継げるか確認した後に実装する（決定 106）。 |
| `F-Onboarding` | 進捗と完了報告 | `onboarding (progress, done)` | 未撮影 | 報告の各行はインポートのフィクスチャに基づく。 |
| `F-Onboarding` | インポートエラーと関連ファイルの警告 | `onboarding (error, sibling-file)` | 未撮影 | 失敗の二つの状態を個別に撮影する。 |
| `Floating` | フローティングサイドバーの概要 | — | 未撮影 | 読み込み済みページの上にサイドバーを表示した状態を撮影する。 |
| `Main` | メインウィンドウの概要 | `header (240)` | 未撮影 | サイドバー幅 240 pt のヘッダーのフレームを使ってウィンドウ全体を比較する。 |
| `Themes` | Look の概要、色レイヤー、スライダー | `look (popover and sidebar)` | 未撮影 | 透明度スライダーとデテントは決定 113–115 で採用された。 |
