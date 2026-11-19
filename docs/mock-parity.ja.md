# U20 モックとの照合

照合元は `~/.config/herdr-agent-team/ararat/reports/design-u20/u20mock/project` にあるオーナーの U20 プロジェクトである。各ページと併せて、`reports/design-u20` の `mock-decisions.md` と `ui-inventory.md` を参照する。図とオーナー決定が異なる場合は決定を優先する。このディレクトリには 76 ページがあり、Batch A のリンク 7 件に対応するページも同名で収録されている。

## トークンテストと構造検査

[照合表](research/mock-values.json)には 134 件あり、このうち 126 件を Swift と比較する。選択行の影については、オフセット、ぼかし、不透明度を検査する。残る 8 件は、オーナーの寸法規則など、照合表に理由を記載した項目である。Library の Downloads の行間隔も、照合表に記録した Arc の実測値と比較する。一つの CSS 宣言が複数のトークンに対応したり、外観によって異なる値になったりする場合がある。

76 ページから抽出した CSS 宣言の候補は 27,782 件で、118 件を確認し、27,664 件の分類が残った。集計では、ファイル名と行番号、セレクタ、プロパティ名、CSS の値の組み合わせを 1 件と数え、照合元の記述と一致することを検査する。候補には、ページ間で共有する規則、注釈、インラインで指定した状態差、未実装画面の値も含む。この件数は残りの候補数の上限であり、Swift に対応付ける必要がある件数は未確定である。

下の台帳には 109 行ある。各行を状態別に 1 件と数えると、一致 43 件、未解決の相違 33 件（うち 1 件はオーナー判断待ち）、修正済みで VM 再確認待ち 15 件、承認済みの相違 4 件、判定不能 3 件、未実装 11 件である。


```sh
MOCK_PROJECT="$HOME/.config/herdr-agent-team/ararat/reports/design-u20/u20mock/project"
direnv exec . env -u DEVELOPER_DIR -u SDKROOT swift test --package-path macos --no-parallel --filter MockParityTests
uv run --no-project python macos/scripts/mock-values/census.py "$MOCK_PROJECT"
```

VM では次のチェックを `--ararat-screen=<name>` で実行する。[画面チェックの実行例](architecture.ja.md)に従い、バンドル済みのアプリ、一時プロファイル、ワークスペースを用意する。

- サイドバーとウィンドウは `organize`、`header`、`space-name`、`sidebar-rows`、`today`、`folder-empty`、`create-space`、`dock`、`split-commands`、`split-focus`、`fullscreen`、`window-drag`、`urlfield`。
- ページとパネルは `keyboard`、`prompts`、`dialogs`、`downloads`、`ext-actions`、`site-controls`、`commandbar`、`errorpages`、`little-window`、`private-window`、`toasts`。
- 設定とオンボーディングは `settings-air-traffic`、`settings-appearance`、`settings-extensions`、`settings-frame`、`settings-toolbar`、`settings-general`、`settings-little-window`、`settings-privacy`、`settings-search`、`settings-shortcuts`、`settings-spaces`、`settings-tabs`、`settings-websites`、`look`、`onboarding`。

ページ内検索と Archive の撮影には、keyboard のメインチェックを `--ararat-keyboard-main-scope` 付きで実行する。

PNG と、拡張子以外のファイル名が同じ JSON を一緒に取得する。JSON の座標はウィンドウ座標系で、単位は pt である。領域撮影の JSON には親ウィンドウのビュー階層が入る。サイドバー、分割セグメント、コマンドバー、タブ切り替え、Little Window、Downloads、設定の検査項目は [structure.json](../macos/scripts/mock-values/structure.json) に示す。AppKit のメニューとページ内の DOM の外観は PNG で確認する。

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

[アーキテクチャ §7](architecture.ja.md) と Little Window のコードでは 46 pt をモック独自の値として扱っている。[Cra の Arc 調査](research/arc-dia-components.ja.md)と [Yab との比較](research/yab-values.ja.md)には Arc の値として 46 pt が記録されている。実装は 48 pt であり、値の出典が確定するまで、照合表にはオーナーの寸法規則を理由として記載する。

## ページ別の照合結果

VM チェック欄にはチェック名と段階、またはファイル名の接頭辞、UUID、拡張子を省いた撮影名を示す。画像判定は `973f57e` の reports/mockvisual-1 に基づき、再確認には `71ccd33` の reports/design-rowcontrast-1 を引用する。各判定の範囲は根拠欄に記す。承認済みの相違には記録された製品判断があり、同じ行に未解決の相違があれば、その行は未解決として扱う。

| モックページ | 要素 | VM チェック | 状態 | 根拠または確認事項 |
| --- | --- | --- | --- | --- |
| `A-BottomDock` | Library、追加メニュー、スペースセル | `dock (cells)` | 一致 | Library と + は dock にある。構造検査 library-dock は PASS。VM の実行 mp2（646da87、2026-11-19）。比較画像は Design の reports/design-mockparity-1/sheets にある。 |
| `A-BottomDock` | 現在のスペースセルと他スペースのドット | `dock (cells, mid)` | 相違（承認済み） | VM capture design-rowcontrast-1, `dock-cells` と `dock-mid` で、現在のスペースの文字セルが残り、ほかがドットになることを確認した（決定 33）。オーナー承認済みの F 系ボードはライト 55%、ダーク 10% の背景と通常のラベル色を使い、A-BottomDock は 60%、13% とアクセント色の文字を描く。 |
| `A-BottomDock` | 開いている Library の塗り | `keyboard-archive-list` | 一致 | 開いた時点のスペースの Look のアクセントで塗る（mock-decisions.md:33）。 |
| `A-FavouriteTiles` | ファビコンタイル、読み込み、音声、未読マーク | `organize-first-favorite` | 修正済み、VM 再確認待ち | favicon がないタイルはサイトの頭文字を表示する（決定 11）。favicon の画像と音声、ミュート、未読の印は実装待ちであり、読み込み中の状態は撮影待ちである（決定 12）。 |
| `A-FavouriteTiles` | お気に入りが空のときの領域 | `organize-empty-favorites` | 一致 | `organize-empty-favorites` では空の領域が詰まり、プレースホルダーを挟まず URL 欄の下にスペース名が出る（決定 13）。 |
| `A-Folders` | 展開したフォルダ、空行、現在の行の保持 | `folder-empty (line, drop)` | 一致 | 空のフォルダに No tabs の行が出る。構造検査は PASS。VM の実行 mp2。 |
| `A-Header` | 幅に応じたナビゲーションとツールチップ | `header-240`, `header-232`, `header-231`, `header-200`, `header-199`, `header-164`, `header-tooltip-toggle_sidebar`, `header-tooltip-back`, `header-tooltip-forward`, `header-tooltip-reload`, `header-loading`, `header-stopped` | 一致 | `header-240/232/231/200/199/164` とツールチップ、読み込み中の画像で、サイドバー切替の 232 pt、Reload の 200 pt、読み込み中の Stop、ショートカット付きのツールチップを確認した（決定 7–10）。 |
| `A-Header` | ショートカット押下中と狭い幅でのオーバーフロー | `header-command`, `header-command-r`, `header-command-r-narrow`, `header-command-w` | 一致 | `header-command`、`header-command-r-narrow`、`header-command-w` で、キーとボタンの押下表示、狭幅時の … の押下背景、行の閉じるボタンの押下表示を確認した（決定 9–10）。 |
| `A-Header` | ヘッダーのオーバーフローメニュー | `header-overflow-menu` | 修正済み、VM 再確認待ち | オーバーフローメニューは A-Header に描かれた 8 項目の現在のショートカットを表示する。 |
| `A-Layout` | サイドバーの配置 | `header-240` | 一致 | `header-240` で 240 pt のサイドバー、URL 欄、スペース名、Clear の手前で終わる Today の区切り線、New Tab、dock を確認した（決定 118）。お気に入りとピン留めのブロックは撮影待ちである。 |
| `A-SpaceName` | 名前、シェブロン、メニュー、ピンの折りたたみ | `space-name-hover`, `space-name-collapsed`, `space-name-menu`, `space-name-renamed` | 修正済み、VM 再確認待ち | シェブロンは名前の文字に中央揃えとし、メニューは New Folder と Delete Space… の前に区切り線を表示する（決定 72）。 |
| `A-TabRows` | ピンと Today の行、スピナー、未読、クラッシュ、音声 | `sidebar-rows-selected`, `sidebar-rows-hover`, `sidebar-rows-pressed`, `sidebar-rows-rows`, `sidebar-rows-loading`, `sidebar-rows-unread`, `sidebar-rows-crashed`, `sidebar-rows-muted` | 一致 | `sidebar-rows-*` で読み込み済みピンの −、favicon の位置のスピナー、未読ドット、45% のクラッシュ行、音声とミュートのマークを確認した（決定 15、16、19、32）。カードは選択行の背景と影の行を参照。 |
| `A-TabRows` | 分割セグメントの寸法と非フォーカス時の背景 | `split-focus (a), split-commands (vertical, split)` | 一致 | 対応表に載せた寸法と両外観の非フォーカス時の背景は、トークンテストとオフスクリーンテストで一致した。 |
| `A-TabRows` | 複数選択 | — | 未実装 | 複数選択はフェーズ 5 より後に実装する（§7）。 |
| `A-TabRows` | 選択行と選択セグメントの影 | `sidebar-rows-selected`, `split-focus-a` | 一致 | VM capture design-rowcontrast-1, `sidebar-rows-selected` と `split-focus-a` で、ライト外観の選択 Today 行とフォーカスセグメントに白いカードを確認した。ダーク外観の選択背景と影の細部は画像での再確認待ちで、オフスクリーン検査では確認済みである。 |
| `A-TabRows` | 複数行の選択 | — | 相違（承認済み） | Phase 5 のサイドバーでは選択行は 1 行である。決定 17 にある複数選択は設計書 §7 で延期している。 |
| `A-TabRows` | 読み込み中とクラッシュのアイコン | `sidebar-rows-loading`, `sidebar-rows-crashed` | 一致 | `sidebar-rows-loading` と `sidebar-rows-crashed` で favicon の位置のスピナーと、45% のクラッシュ行の警告アイコンを確認した（決定 15–16）。 |
| `A-TabRows` | 未読の行とミュートした行 | `sidebar-rows-unread`, `sidebar-rows-muted` | 一致 | `sidebar-rows-unread` と `sidebar-rows-muted` で、右端のドットとタイトル横の斜線付きスピーカーを確認した（決定 16、19）。 |
| `A-TabRows` | 行のアーカイブと閉じるボタン | `header-command-w`, `sidebar-rows-hover`, `sidebar-rows-pressed` | 一致 | `header-command-w` で現在の Today 行の ✕ の押下表示、`sidebar-rows-hover` で読み込み済みピンの − を確認した（決定 29、32）。行のツールチップの文言は撮影待ちである。 |
| `A-TodayNewTab` | Today の区切り線、Clear、New Tab | `today (today, cleared, new-tab-row)` | 一致 | 区切り線と Clear が Today の上にあり、New Tab が先頭にある。構造検査は PASS。VM の実行 mp2。 |
| `A-TodayNewTab` | Clear 後の区切り線 | `today (cleared)` | 一致 | Today が空になると区切り線が消える。構造検査は PASS。VM の実行 mp2。 |
| `A-TodayNewTab` | Appearance で New Tab を非表示 | `today-new-tab-hidden` | 一致 | `today-new-tab-hidden` では New Tab を非表示にすると、区切り線と Clear の直下に Today の行が並ぶ（決定 93、116）。 |
| `B-CreateSpace` | スペース作成フォーム | `space-name-create-page` | 修正済み、VM 再確認待ち | Profile カードに人物アイコンを表示し、フォームを開いている間はドックを隠す。`space-name-create-page` で再確認する。 |
| `B-CreateSpaceStates` | スペース作成の成功と失敗 | `create-space-created`, `create-space-failure` | 一致 | VM capture design-rowcontrast-1, `create-space-failure` と `create-space-created` で、チャコール色の Create Space、標準文字色の Cancel、失敗時の文言、作成後のスペースを確認した（決定 70）。Creating… のスピナーは撮影待ちである。 |
| `B-Drag` | サイドバーのドロップ位置、フォルダ上のホバー、拒否 | `organize-drop`, `organize-hover-open`, `dock-refused` | 修正済み、VM 再確認待ち | ドラッグ中の複製では閉じるアイコンを隠し、ドロップ線を複製の手前に描画する。`organize-drop` で再確認する。 |
| `B-Drag` | 別プロファイルへのドロップ拒否 | `dock-refused` | 判定不能 | `dock-refused` ではドラッグ中の複製が対象セルを覆い、ポインターのバッジも写っていない。35% に暗くなる表示と拒否バッジの撮影が必要である（決定 68）。 |
| `B-DragPage` | 分割を作るページ上のドロップ領域 | `split-commands-drop-target` | 一致 | `split-commands-drop-target` で決定 60 の半面の強調表示を確認した。比較対象は B-SplitStates の第 4 図である。 |
| `B-Floating` | フローティングサイドバーの配置と内容 | `fullscreen-edge` | 相違 | `fullscreen-edge` のパネル配置は一致するが、モックの中立灰色に対して青緑に着色されている。B-Fullscreen の第 1 図は AppKit の全画面表示を指定しているが、ブラウザー全画面でも Chromium の Esc 長押しメッセージが出る。 |
| `B-FloatingDark` | ダークのフローティングサイドバー | `fullscreen-dark-floating` | 相違 | `973f57e` の `fullscreen-dark-floating` は実測の黒に近い色 (22, 15, 31) に対して中間の灰色であった。現行コードは実測色を使うが、design-rowcontrast-1 に全画面の画像がなく、フローティング時の合成結果は再確認待ちである。 |
| `B-FloatingMotion` | 端からの表示、待機時間、非表示 | `fullscreen-floating-before-reveal`, `fullscreen-dark-floating`, `fullscreen-floating-after-hide` | 一致 | `fullscreen-floating-before-reveal`、`fullscreen-dark-floating`、`fullscreen-floating-after-hide` で表示前・表示中・非表示後の静止状態を確認した。待機時間と動作時間は計測待ちである。 |
| `B-Fullscreen` | ページとブラウザの全画面表示、端からの表示 | `fullscreen-page`, `fullscreen-browser`, `fullscreen-edge` | 相違 | `fullscreen-page` の Chromium の終了メッセージと `fullscreen-edge` の端からの表示は一致する。`fullscreen-browser` にも Chromium のメッセージが出るが、B-Fullscreen の第 1 図にはない。 |
| `B-History` | 履歴削除のエラーバナーと Retry | `toasts-banner` | 修正済み、VM 再確認待ち | プロファイル内の警告カードに警告アイコン、見出し、本文、Try Again、閉じるボタンを表示する。 |
| `B-HistoryStates` | 履歴ストアの失敗と再試行 | `toasts-banner` | 修正済み、VM 再確認待ち | 失敗時は警告カードを表示する。再試行中、成功時、ダーク外観は撮影待ちである。 |
| `B-Library` | Library のレールとアーカイブ一覧 | `keyboard-archive-list` | 相違 | VM capture design-rowcontrast-1, `downloads-library` で、アイコンの下にラベルを置くレールと選択タイルを確認した。`keyboard-archive-list` の判定は維持し、Archive の選択タイルと Phase 5 の Clear Archive… フッターに dock が重ならないことは再撮影で確認する。 |
| `B-LibraryStates` | アーカイブ一覧の状態 | `keyboard-archive-list`, `keyboard-archive-search`, `keyboard-archive-no-matches`, `keyboard-archive-empty` | 相違 | `keyboard-archive-search`、`keyboard-archive-no-matches`、`keyboard-archive-empty` のリスト状態は一致し、旧画像では Phase 5 の Clear Archive… フッターに + が重なる。design-rowcontrast-1 に Archive の画像がなく、フッターとライト・ダーク外観の選択タイルは再確認待ちである。 |
| `B-Menus` | 行、スペース、分割のネイティブメニュー | `sidebar-rows-tab-menu`, `space-name-menu`, `split-commands-menu-open` | 修正済み、VM 再確認待ち | スペースのメニューに区切り線が 2 本ある（決定 72）。Today のメニューには Phase 5 の Add Split View があり、分割のメニューは決定 65 に従う。 |
| `B-NoTab` | 空のページカードとショートカット案内 | `keyboard-no-tab` | 一致 | VM capture design-rowcontrast-1, `dock-cells` と `create-space-created` で、空のページカードに ⌘T New Tab と ⇧⌘L Open Library が出ることを確認した（決定 61）。 |
| `B-SpacePaging` | ページ切り替えとドックのクロスフェード | `dock-mid` | 一致 | `dock-mid` ではヘッダー、URL 欄、下部バーを固定したまま内容がスライドし、現在のスペースのセルのみが残り、ほかはドットになる（決定 33）。クロスフェードは計測待ちである（決定 69）。 |
| `B-Split` | 2 ペイン、フォーカスリング、共通のナビゲーション | `split-focus (a, b)` | 一致 | VM capture design-rowcontrast-1, `split-focus-a` と `split-focus-b` で、ペイン間の Look 色のフォーカスリングの移動、サイドバーの共通操作部、各ペインに対応するセグメントを確認した（決定 17、65）。 |
| `B-SplitStates` | 複数ペイン、仕切り、ドラッグ、移動 | `split-commands-vertical`, `split-commands-split`, `split-focus-frozen`, `split-focus-release`, `dialogs-transfer` | 相違 | `split-commands-horizontal` では約 120 pt 幅の 4 ペインにスクロールバーが出る。B-SplitStates の最小幅は 240 pt で、縦分割、10 pt の間隔、フォーカスリング、`split-divider-hover` のグリップは一致する。 |
| `B-SplitStates` | 一つのサイドバー行に並ぶ 3 ペイン | `split-commands (vertical)` | 一致 | 縦の split でもセグメントは三つ横に並ぶ。構造検査は PASS。VM の実行 mp2。 |
| `B-Tooltips` | ボタンと行のツールチップ、キーキャップ | `header-tooltip-toggle_sidebar`, `header-tooltip-back`, `header-tooltip-forward`, `header-tooltip-reload`, `header-command`, `header-command-r`, `header-command-w` | 一致 | `header-tooltip-back/-forward/-reload` と `header-command` で名称、キー、押下表示を確認した（決定 9）。`header-command-w` は行の ✕ の押下を示し、行のツールチップは撮影待ちである（決定 29）。 |
| `B-WindowStates` | ウィンドウ枠、最小幅、非アクティブ状態 | `window-drag-sidebar` | 判定不能 | `window-drag-sidebar` では標準幅のアクティブ時の外枠が一致する。非アクティブ時の色と信号ボタン、狭幅・広幅のサイドバー、最小ウィンドウ幅は撮影待ちである（決定 71）。 |
| `C-DialogHost` | ページカード上のダイアログ | `permission`, `permission-dialog`, `javascript`, `javascript-dialog`, `dialogs-permission`, `dialogs-permission-dialog`, `dialogs-long-origin`, `dialogs-long-origin-dialog`, `dialogs-javascript`, `dialogs-javascript-dialog`, `dialogs-queued-permission`, `dialogs-queued-permission-dialog`, `dialogs-split`, `dialogs-split-dialog` | 修正済み、VM 再確認待ち | ページ上のダイアログには、外観に応じて C-DialogHost と同じ暗転を使う。表示中のダイアログを隠してから次を表示する。`dialogs-javascript` と `dialogs-queued-permission` で再確認する。 |
| `C-Downloads` | Library の進捗、ポップオーバー、全履歴 | `downloads-flight`, `downloads-ring`, `downloads-popover`, `downloads-library`, `downloads-popover-complete` | 修正済み、VM 再確認待ち | ポップオーバーに見出しと行ごとの進捗を表示する。Library は Arc 実測の 56 pt の行間隔で、狭い行の補助ステータスを中央で省略する。 |
| `C-Downloads` | 進捗リングとファイルアイコンの移動 | `downloads-ring`, `downloads-flight` | 一致 | `downloads-ring` と `downloads-flight` で進捗リングと飛び始めのファイルアイコンを確認した（決定 81）。軌道と所要時間は動画または計測での確認が必要である。 |
| `C-Downloads` | 処理中と完了後のポップオーバー | `downloads-popover`, `downloads-popover-complete` | 相違 | 見出し、進捗、ステータスは VM 再確認待ちである。dlpopover で実装した Chromium が許可する操作を維持する。処理中の行には Finder 表示が出ることがあり、完了行には Finder 表示、開く、削除を常時表示する。モックは処理中に一時停止とキャンセル、完了行のホバー時に Finder 表示と削除を表示する。 |
| `C-Downloads` | Library のダウンロード履歴 | `downloads-library` | 修正済み、VM 再確認待ち | Arc 実測の 56 pt の行間隔で、狭い行の補助ステータスをセル内の中央で省略する。 |
| `C-Extensions` | URL 欄のピン留め拡張機能とオーバーフロー行 | `ext-actions-action`, `ext-actions-overflow`, `ext-actions-three-actions` | 相違 | `ext-actions-action` は Copy Link の前に固定アクションを表示する（決定 42、47）。`ext-actions-overflow` は 16 pt のアイコンのみで、モックではお気に入りの列にそろえた高さ 32 pt のタイルを描く（決定 46、51）。 |
| `C-Extensions` | 拡張機能アクションのオーバーフロー | `ext-actions-overflow`, `ext-actions-three-actions` | 相違 | `ext-actions-overflow` にはタイルの背景がない。`ext-actions-three-actions` は比較画像に含まれておらず、複数アクションの配置は確認待ちである。 |
| `C-Permissions` | 権限の確認とブロック済みサイトの表示 | `permission-dialog`, `site-controls-popover` | 相違 | `permission-dialog` の上端中央の配置と `permission` の赤いブロック表示は一致する（決定 80、83）。シートはオリジンと権限のテキスト、枠付きボタン 3 個を表示し、アイコン、説明、Remember のチェックボックスがない。ブロック時のツールチップは撮影待ちである。 |
| `C-SiteControls` | 撮影タイルとセキュリティ表示 | `site-controls (popover, certificate)` | 相違（承認済み） | モックはキャプチャと翻訳の 4 アクションを描く（決定 77）。設計書 §7 は実装済みのキャプチャ 2 種を対象とし、縦長キャプチャと翻訳を延期している。 |
| `C-SiteControls` | 縦長キャプチャ、翻訳、拡張機能グリッド、未実装の設定 | — | 未実装 | 対象の機能は §7 と §14 で実装を見送っている。 |
| `C-SiteControlsStates` | ポップオーバーの各状態の寸法 | `site-controls-popover`, `site-controls-overlay`, `site-controls-toast` | 相違 | `site-controls-popover` は幅約 216 pt（決定 76 は 262 pt）で、半透明の背景に Settings 行がない。未実装の 2 アクションは延期対象である（決定 77）。フッター、`site-controls-overlay`、`site-controls-toast` は一致する（決定 5、78）。 |
| `C-SiteControlsStates` | 証明書シート | `site-controls-certificate` | 一致 | `site-controls-certificate` で、セキュリティフッターからシステムの証明書シートが開くことを確認した（決定 5）。 |
| `C-UrlField` | ホスト名、プレースホルダー、末尾のボタン | `urlfield (host, placeholder, internal, long-host)` | 一致 | VM capture design-rowcontrast-1, `urlfield-host`、`urlfield-placeholder`、`urlfield-internal`、`urlfield-long-host` で、短いホスト名の全体、プレースホルダー、内部アドレス、右端の操作を確認した（決定 73）。Look 色のカスタムフォーカス枠は画像での再確認待ちである。 |
| `C-UrlField` | 長いホスト名と狭い URL 欄 | `urlfield (long-host, long-host-narrow)` | 一致 | VM capture design-rowcontrast-1, `urlfield-long-host` と `urlfield-long-host-narrow` で、`cac6112` の修正後は両方の幅で末尾が切れず、ホスト名の後半が残ることを確認した。 |
| `CommandBar` | 概要のコマンドパネル | `commandbar-search`, `commandbar-recent` | 相違（承認済み） | VM capture design-rowcontrast-1, `commandbar-search` と `commandbar-recent` で、ウィンドウの暗転、ページカード中央のパネル、アクセント色の選択行、キーヒントを確認した。U23 は決定 84 に従い Return で開き、モックの Tab 補完のヒントを表示しない。 |
| `D-CommandBar` | 検索を先頭に出す入力欄と履歴 | `commandbar-search` | 一致 | VM capture design-rowcontrast-1, `commandbar-search` で、先頭の検索行の選択に Look のアクセントが使われ、次に履歴が続き、インライン補完がないことを確認した（決定 84）。 |
| `D-CommandBarPanels` | コマンドパネルの各状態 | `commandbar-search`, `commandbar-settings`, `commandbar-open-url`, `commandbar-recent`, `commandbar-edit-url` | 相違 | VM capture design-rowcontrast-1, `commandbar-search`、`commandbar-settings`、`commandbar-open-url`、`commandbar-recent`、`commandbar-edit-url` で各状態の選択行にアクセント色を確認した。最近のタブは Today ではなく Switch to Tab と表示し、Edit URL は検索優先ルール（決定 84）に従って Open URL の 1 行を表示する。 |
| `D-CommandBarRows` | 結果行の寸法、内側余白、行間 | — | 一致 | 対応表に記載した行と入力欄の寸法は一致した。行の外観は未確認である。 |
| `D-ErrorPages` | オフラインと DNS のエラー | `errorpages-offline`, `errorpages-dns` | 相違 | VM capture design-rowcontrast-1, `errorpages-offline` と `errorpages-dns` で、両方の Try Again にアクセント色を確認した。オフラインでは URL 欄とタブ行に内部の network-error アドレスが出るが、DNS エラーではホスト名が残る（決定 87）。 |
| `D-FindBar` | ページ内検索バーと件数 | `header-find-bar`、`keyboard-find-count`、`keyboard-find-no-match` | 修正済み、VM 再確認待ち | 入力欄の右端の表示枠に件数を左揃えで表示する。現在の検索の途中結果が届くとスピナーを表示し、0 件が確定すると赤い Not found を表示してシェブロンを無効にする。 |
| `D-FindBarPage` | ページ上の検索バー | `header-find-bar`、`keyboard-find-count`、`keyboard-find-no-match` | 修正済み、VM 再確認待ち | ページの右上に、欄内の件数、シェブロン、0 件確定時の表示を備えた検索バーを出す。 |
| `D-LittleWindow` | バー、Open in メニュー、プロファイルメニュー、コマンドバー | `little-window-bar`, `little-window-profile-menu`, `little-window-space-menu`, `little-window-command-bar` | 相違 | `little-window-bar` とプロファイル・スペースのメニューでは、アドレスが中央にあり、プロファイルメニューが小さく、スペースメニューが右寄せで余分な縦線がある（決定 89）。VM capture design-rowcontrast-1, `little-window-command-bar` では選択行のアクセント色を確認したが、モックのダークパネルに対しライトパネルである。 |
| `D-PrivateWindow` | プライベートウィンドウと URL 欄のマスク | `private-window` | 相違 | `private-window` のダーク外観、マスク、Private 表示は一致する（決定 86）。サイドバーには Today、Clear、Library、+ があり、New Tab と表示され、終了時の削除を説明する脚注がない。 |
| `D-PrivateWindowEmpty` | 空のプライベートウィンドウ | — | 相違 | 実装では最後のタブを閉じるとプライベートウィンドウも閉じる。モックは空のプライベートウィンドウを描く。オーナー判断待ち。 |
| `D-SadTab` | クラッシュした Today タブとピン | `errorpages-today-crash`, `errorpages-pin-crash` | 修正済み、VM 再確認待ち | ページには悲しい顔のウィンドウを表示する。サイドバーの行には A-TabRows で指定された警告アイコンを使う（決定 16）。 |
| `D-TabSwitcher` | Control-Tab の切り替え画面 | `commandbar-tab-switcher` | 相違（オーナー判断待ち。タイルの寸法とサムネイル） | 切り替え画面をウィンドウの中央に置き、現在のキー割り当てを表示する。タイルの寸法とサムネイルはオーナーの判断を待つ。 |
| `D-Toasts` | コピー完了、Clear の Undo、失敗バナー | `toasts-toast`, `toasts-banner` | 相違 | Link copied は 14 pt のリンクアイコン付きで、ページ下部に高さ 40 pt で表示する。モックはサイドバー内に高さ 36 pt で表示する。リンクアイコンと履歴削除失敗の警告カードは VM 再確認待ち、Undo と更新準備完了は撮影待ちである。 |
| `D-Toasts` | 更新完了と Restart | — | 未実装 | 更新機能は Sparkle が担う。Restart 付きのトーストは未実装である。 |
| `Dark` | ダークのブラウザ全体 | `fullscreen-dark-docked` | 相違 | `973f57e` の `fullscreen-dark-docked` は中間の灰色の背景と明るい灰色の選択行を示した。現行コードは実測の黒に近い背景と 19.5% の白のオーバーレイを使い、design-rowcontrast-1 にダーク外観で dock 固定の全画面画像がないため、画像での再確認は保留である。 |
| `E-About` | About と更新状態 | — | 未実装 | 現行の設定画面に About ペインはない。 |
| `E-AirTraffic` | ルーティング規則と移動先の編集 | `settings-air-traffic-settings-air-traffic`, `settings-air-traffic-settings-air-traffic-default-before-press` | 一致 | VM capture design-rowcontrast-1, `settings-air-traffic-settings-air-traffic` で空のルート一覧、既定の行き先、テスト欄、アクセント色のステッパーを確認した。ルート行と行き先の開いたメニューは比較画像待ちである。 |
| `E-Appearance` | 外観の設定 | `settings-appearance-appearance`, `settings-appearance-theme-light`, `settings-appearance-theme-dark`, `settings-appearance-theme-system` | 相違 | VM capture design-rowcontrast-1, `settings-appearance-appearance` と `settings-appearance-theme-dark` で選択部とスイッチに Look のアクセント色を確認した。Theme、Look、New Tab row、Tooltips は一致し、Page zoom は未実装である（決定 92）。 |
| `E-Controls` | 設定画面のコントロールと操作時の状態 | `settings-frame-frame`, `settings-appearance-appearance`, `settings-shortcuts-shortcuts-recorder` | 一致 | VM capture design-rowcontrast-1, `settings-frame-frame`、`settings-appearance-appearance`、`settings-shortcuts-shortcuts-recorder` でステッパー、スイッチ、選択セグメント、録音欄のフォーカスリングのアクセント色が一致した（決定 104）。主要ボタンの押下時は比較画像待ちである。 |
| `E-Extensions` | インストール済み一覧、プロファイルメニュー、レビュー | `settings-extensions-extensions`, `settings-extensions-extensions-profile2`, `settings-extensions-extensions-review` | 相違 | `settings-extensions-extensions` と `settings-extensions-extensions-review` でプロファイル選択、インストール済みの行、Review… の状態を確認した（決定 102）。Add from Arc は下の未実装行に記録する。 |
| `E-Extensions` | Arc から追加 | — | 未実装 | インポート元の調査と権限の設計が必要である（§14）。 |
| `E-Frame` | 設定画面のツールバー、レール、カード | `settings-frame-frame`, `settings-toolbar-toolbar-top`, `settings-toolbar-toolbar-scrolled` | 相違 | `settings-frame-frame` と `settings-toolbar-top/-scrolled` の外枠、スクロール時のタイトル、カードは一致する。レールにグループの間隔がなく、Passwords、Sync、About を除く 11 ペインが連続して並ぶ。 |
| `E-General` | 既定ブラウザ、起動時の動作、ダウンロード | `settings-general-general` | 相違 | `settings-general-general` には Warn before quitting、Search と Language のグループ、Downloads 行のパス、既定のブラウザー行の右端の操作または状態表示がない（決定 91）。 |
| `E-General` | General の残りの設定 | — | 未実装 | 終了前の確認、検索候補、検索エンジン、スペルチェックは後の実装とする（§7）。 |
| `E-LittleWindow` | ショートカット、移動先、閉じる動作、サイズと位置の保持 | `settings-little-window-little-window` | 一致 | `settings-little-window-little-window` で決定 99 の順序どおりに 5 行と各コントロールを確認した。ショートカットとスイッチの状態はフィクスチャの値である。 |
| `E-Passwords` | 保存済みパスワードと Touch ID | — | 未実装 | U20 のパスワード設定は計画段階にある。 |
| `E-Privacy` | 閲覧データの消去、保持期間、Cookie とプライバシー設定 | `settings-privacy-privacy`, `settings-privacy-privacy-sheet` | 相違 | `settings-privacy-privacy` には仕様検討中の Protection 機能がない（決定 97）。`settings-privacy-sheet` は Cancel に塗りがあり、Clear Data を Clear と表示し、プロファイルを固定ラベルで示し、Site permissions のチェックボックスがない。 |
| `E-Privacy` | ブロッカーと危険なサイトの警告 | — | 未実装 | 方式と情報源は未決定である（§14）。 |
| `E-Search` | 設定内検索と該当項目の強調 | `settings-search-search`, `settings-search-search-cleared` | 一致 | `settings-search-search` と `settings-search-search-cleared` で、レールに代わる検索結果、先頭結果の選択、対象行にスクロールした後の灰色の強調表示を確認した。 |
| `E-Shortcuts` | ショートカット一覧、入力、競合の表示 | `settings-shortcuts-shortcuts`, `settings-shortcuts-shortcuts-recorder`, `settings-shortcuts-shortcuts-conflict`, `settings-shortcuts-shortcuts-refusal` | 一致 | `settings-shortcuts-*` でキーまたは None、入力欄、競合表示、システムによる拒否表示を確認した。検索欄と次・前のペインへ移動する行（決定 103）は画面外である。 |
| `E-SpacePage` | スペース個別の設定 | `settings-spaces-space-page`, `dock-space-settings`, `settings-appearance-look-space-page` | 修正済み、VM 再確認待ち | `settings-spaces-space-page`、`dock-space-settings`、`settings-appearance-look-space-page` の見出し、ページ切替、各行は一致する。Delete Space の文字はボードの赤（`--red`: ライト #B3261E、ダーク #FF8A80）で、オフスクリーンのテストが描画後の画素と解決した色を読む。 |
| `E-Spaces` | スペース一覧とスクロール方向 | `settings-spaces-spaces` | 修正済み、VM 再確認待ち | `settings-spaces-spaces` ではタブ数と ⌃N を固定幅の右側列に置いて一覧で縦に揃え、アイコンの文字をモックの 24 pt タイルに載せる。どちらもオフスクリーンのテストで確認する。ドラッグハンドル、シェブロン、Natural / Reversed は一致する（決定 95）。 |
| `E-Sync` | 同期設定とデバイス | — | 未実装 | 同期はフェーズ 8 で実装予定である（決定 100）。 |
| `E-Tabs` | タブ設定とスペースへの移動 | `settings-tabs-settings-tabs`, `settings-spaces-space-page` | 修正済み、VM 再確認待ち | `settings-tabs-settings-tabs` に 2 行ともある。Archive Today’s tabs after のポップアップは内容に合わせた幅（モックでは 110 pt）で、行の右端に他の右寄せコントロールと同じく揃う。幅と位置はオフスクリーンのテストで確認する。 |
| `E-Websites` | 既定とサイト別の権限 | `settings-websites-websites`, `settings-websites-site-row`, `settings-websites-site-page` | 相違 | `settings-websites-websites` の既定値の一覧は一致する。`settings-websites-site-page` は上書きした Camera のみを表示する（モックは全権限を並べる。決定 94）。Clear… は Delete Space と同じボードの赤になり、オフスクリーンのテストが描画後の画素を読む。 |
| `Extensions` | ピン留めした拡張機能の概要 | `ext-actions-action`, `ext-actions-overflow` | 一致 | `ext-actions-action` では固定アクションが URL 欄にあり、ヘッダーにはない（決定 42）。概要図のアクションメニューと権限プロンプトは撮影待ちである。 |
| `F-Import` | インポート対象の選択、進捗、完了 | `onboarding (what-to-import, progress, done)` | 相違 | フィクスチャを使うフローでは、ログイン状態、パスワード、履歴、アーカイブの行を省いている（§7）。 |
| `F-Import` | ログイン状態の引き継ぎとキーチェーン権限 | — | 未実装 | キーチェーンを使うフローにはインポートの調査が必要である（決定 105–106）。 |
| `F-LookControls` | 透明度、Glass のデテント、粒状感、メニュー | `look-55-popover`, `look-detent-popover`, `look-glass-popover` | 一致 | VM capture design-rowcontrast-1, `look-55-popover`、`look-detent-popover`、`look-glass-popover` で、外観選択、波形、デテント、点灯した Glass ソケット、Grain ノブを確認した（決定 107、108、113）。Transparency 欄にはネイティブの青いフォーカス枠が残り、モックの描画には未展開のラベルがあり、… メニューは撮影待ちである。 |
| `F-LookGallery` | プリセットとカラーピッカー | `look-55-popover` | 判定不能 | `look-55-popover` で極座標の色選択欄、チップのページ切替、色数を確認した（決定 109）。モックの描画がほぼ空で、照合には正常なモック画像が必要である。 |
| `F-LookPopover` | Look ポップオーバーと色の入力欄 | `look-55-popover`, `look-glass-popover` | 相違 | `look-55-popover` と `look-glass-popover` で決定 109、113 の操作部と色選択欄を確認した。アプリの幅は約 272 pt、モックのソースは 380 × 564 pt を指定し、描画には未展開のテンプレートが残る。 |
| `F-LookSidebar` | 設定値ごとのスペース色とサイドバー | `look-55-sidebar`, `look-detent-sidebar`, `look-glass-sidebar` | 一致 | `look-55-sidebar`、`look-detent-sidebar`、`look-glass-sidebar` で透明度に応じた着色と、スペース名を起点とするポップオーバーを確認した。着色の強さの厳密な一致は確認待ちである（決定 111）。 |
| `F-LookStates` | カラーピッカー、プリセット、粒状感の各状態 | `look-55-popover`, `look-grain0-sidebar`, `look-grain5-sidebar`, `look-grain50-sidebar`, `look-grain100-sidebar` | 一致 | VM capture design-rowcontrast-1, `look-grain0-sidebar`、`look-grain5-sidebar`、`look-grain50-sidebar`、`look-grain100-sidebar` で、細かい粒状ノイズと紺の Look 上での Auto の明るい文字を確認した（決定 112、114）。ダーク外観で最も明るい不透明色とグラデーションの Look は VM で再確認待ちで、ユニットテストでは確認済みである。 |
| `F-Onboarding` | ようこそ、ソース、対象選択、既定ブラウザ、進捗、完了、二つのエラー | `onboarding-welcome`, `onboarding-source`, `onboarding-what-to-import`, `onboarding-default-browser`, `onboarding-progress`, `onboarding-done`, `onboarding-error`, `onboarding-sibling-file` | 相違 | `onboarding-*` で決定 106 の流れとボタンを確認した。インポート項目に不足がある。完了報告の切れは修正済み（当該行を参照）。キーチェーンの手順 3a は撮影待ちである。 |
| `F-Onboarding` | ようこそとインポート元の検出 | `onboarding-welcome`, `onboarding-source` | 一致 | `onboarding-welcome` と `onboarding-source` で見出し、ボタン、ページドット、検索結果を確認した（決定 106）。Arc の行にはモックのラジオマークがない。 |
| `F-Onboarding` | インポート対象と既定ブラウザの設定 | `onboarding-what-to-import`, `onboarding-default-browser` | 相違 | `onboarding-what-to-import` にはチェックボックス、未選択の Travel 2025、Archive、Sign-in state、Passwords、History がない（決定 106）。`onboarding-default-browser` は一致する。 |
| `F-Onboarding` | キーチェーンのアクセス要求 | — | 未実装 | 3a はログイン状態を引き継げるか確認した後に実装する（決定 106）。 |
| `F-Onboarding` | 進捗と完了報告 | `onboarding-progress`, `onboarding-done` | 修正済み、VM 再確認待ち | `onboarding-progress` は一致する。`onboarding-done` では報告行を文字に合わせた高さの行（1 行 31 pt、2 行 48 pt）でカード内に折り返し、モックと同じくカードの端を越えない。各行の高さと、最も長いフォルダー状態の行が折り返すことをオフスクリーンのテストで確認する。 |
| `F-Onboarding` | インポートエラーと関連ファイルの警告 | `onboarding-error`, `onboarding-sibling-file` | 一致 | `onboarding-error` と `onboarding-sibling-file` で、エラーと警告の文言、重大度を示す色、各ボタンの一致を確認した（決定 106）。 |
| `Floating` | フローティングサイドバーの概要 | `fullscreen-edge` | 相違 | `fullscreen-edge` のパネル配置は一致するが、中立灰色の箇所が青緑に着色され、ブラウザー全画面で Chromium の Esc 長押しメッセージが出る。非全画面の概要は撮影待ちである。 |
| `Main` | メインウィンドウの概要 | `header-240` | 一致 | VM capture design-rowcontrast-1, `header-240` で白い選択 Today カード、ヘッダー、Today の区切り線、dock を確認した。Main のモック画像ではお気に入りがページに並ぶため、選択カードは A-TabRows を参照し、Main の細部の照合には正常なモック画像が必要である。 |
| `Themes` | Look の概要、色レイヤー、スライダー | `look-55-popover`, `look-55-sidebar`, `look-detent-popover`, `look-detent-sidebar`, `look-glass-popover`, `look-glass-sidebar` | 一致 | VM capture design-rowcontrast-1, `look-55-sidebar`、`look-glass-sidebar`、`look-grain0-sidebar` で、透明度に応じた着色と紺の Look 上での Auto の明るい文字を確認した（決定 113–114）。スライダーとデテントはモックのソースに一致し、未展開のテンプレートにより画像での照合はサイドバーに限られる。 |
