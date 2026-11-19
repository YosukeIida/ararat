# U20 モックとの照合

照合元は `~/.config/herdr-agent-team/ararat/reports/design-u20/u20mock/project` にあるオーナーの U20 プロジェクトである。各ページと併せて、`reports/design-u20` の `mock-decisions.md` と `ui-inventory.md` を参照する。図とオーナー決定が異なる場合は決定を優先する。このディレクトリには 76 ページがあり、Batch A のリンク 7 件に対応するページも同名で収録されている。

## トークンテストと構造検査

[照合表](research/mock-values.json)には 134 件あり、このうち 126 件を Swift と比較する。選択行の影については、オフセット、ぼかし、不透明度を検査する。残る 8 件は、オーナーの寸法規則など、照合表に理由を記載した項目である。Library の Downloads の行間隔も、照合表に記録した Arc の実測値と比較する。一つの CSS 宣言が複数のトークンに対応したり、外観によって異なる値になったりする場合がある。

76 ページから抽出した CSS 宣言の候補は 27,782 件で、118 件を確認し、27,664 件の分類が残った。集計では、ファイル名と行番号、セレクタ、プロパティ名、CSS の値の組み合わせを 1 件と数え、照合元の記述と一致することを検査する。候補には、ページ間で共有する規則、注釈、インラインで指定した状態差、未実装画面の値も含む。この件数は残りの候補数の上限であり、Swift に対応付ける必要がある件数は未確定である。

下の台帳には 109 行ある。各行を状態別に 1 件と数えると、一致 16 件、相違 20 件、未レビュー 62 件、未実装 11 件である。

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

VM チェック欄には、レビュー済みの行ではチェック名と撮影の段階、未レビューの行では JSON の `name` を記載する。ファイル名に付く接頭辞、UUID、拡張子は省く。未レビューの行には少なくとも 1 枚の撮影処理があり、設計担当が VM の画像をモックと照合する。撮影が必要な状態は根拠欄に記載する。「一致」「相違あり」は、根拠欄に示す範囲の判定である。

| モックページ | 要素 | VM チェック | 状態 | 根拠または確認事項 |
| --- | --- | --- | --- | --- |
| `A-BottomDock` | Library、追加メニュー、スペースセル | `dock (cells)` | 一致 | Library と + は dock にある。構造検査 library-dock は PASS。VM の実行 mp2（646da87、2026-11-19）。比較画像は Design の reports/design-mockparity-1/sheets にある。 |
| `A-BottomDock` | 現在のスペースセルと他スペースのドット | `dock (cells, mid)` | 相違 | 開いているスペースは文字のセルを保ち、他はドットになる。図のとおりである。VM の実行 mp2（646da87、2026-11-19）。比較画像は Design の reports/design-mockparity-1/sheets にある。開いているセルは、オーナーが承認した F ボードの白いオーバーレイ（ライト 55%、ダーク 10%）と通常のラベル色を使う。A ボードは 60% と 13% のオーバーレイとアクセント色のグリフを描く。 |
| `A-BottomDock` | 開いている Library の塗り | `keyboard-archive-list` | 一致 | 開いた時点のスペースの Look のアクセントで塗る（mock-decisions.md:33）。 |
| `A-FavouriteTiles` | ファビコンタイル、読み込み、音声、未読マーク | `organize-first-favorite` | 未レビュー | 最初のタイルを撮影する。ほかの状態には個別のフレームが必要である。 |
| `A-FavouriteTiles` | お気に入りが空のときの領域 | `organize-empty-favorites` | 未レビュー | プレースホルダーを表示せず、領域をたたむ（決定 13）。 |
| `A-Folders` | 展開したフォルダ、空行、現在の行の保持 | `folder-empty (line, drop)` | 一致 | 空のフォルダに No tabs の行が出る。構造検査は PASS。VM の実行 mp2。 |
| `A-Header` | 幅に応じたナビゲーションとツールチップ | `header-240`, `header-232`, `header-231`, `header-200`, `header-199`, `header-164`, `header-tooltip-toggle_sidebar`, `header-tooltip-back`, `header-tooltip-forward`, `header-tooltip-reload`, `header-loading`, `header-stopped` | 未レビュー | Reload は 200 pt、サイドバー切り替えは 232 pt で表示する（決定 7–10）。 |
| `A-Header` | ショートカット押下中と狭い幅でのオーバーフロー | `header-command`, `header-command-r`, `header-command-r-narrow`, `header-command-w` | 未レビュー | コントロールとキーキャップの押下時の表示を比較する（決定 9–10）。 |
| `A-Header` | ヘッダーのオーバーフローメニュー | `header-overflow-menu` | 未レビュー | AppKit のメニューが開いている間にウィンドウの表示領域を撮影する。JSON には親ウィンドウのビュー階層を記録する。 |
| `A-Layout` | サイドバーの配置 | `header-240` | 未レビュー | 既定幅 240 pt と選択行の寸法はトークンテストの対象である。 |
| `A-SpaceName` | 名前、シェブロン、メニュー、ピンの折りたたみ | `space-name-hover`, `space-name-collapsed`, `space-name-menu`, `space-name-renamed` | 未レビュー | ホバー、折りたたみ、ネイティブメニュー、改名後の状態を撮影する。 |
| `A-TabRows` | ピンと Today の行、スピナー、未読、クラッシュ、音声 | `sidebar-rows-selected`, `sidebar-rows-hover`, `sidebar-rows-pressed`, `sidebar-rows-rows`, `sidebar-rows-loading`, `sidebar-rows-unread`, `sidebar-rows-crashed`, `sidebar-rows-muted` | 未レビュー | ホバーと押下の画像では、選択されていない読み込み済みのピンを対象とする。選択時の画像では、隣の Today の行を対象とする。 |
| `A-TabRows` | 分割セグメントの寸法と非フォーカス時の背景 | `split-focus (a), split-commands (vertical, split)` | 一致 | 対応表に載せた寸法と両外観の非フォーカス時の背景は、トークンテストとオフスクリーンテストで一致した。 |
| `A-TabRows` | 複数選択 | — | 未実装 | 複数選択はフェーズ 5 より後に実装する（§7）。 |
| `A-TabRows` | 選択行と選択セグメントの影 | `sidebar-rows-selected`, `split-focus-a` | 一致 | Today の選択行と分割行のフォーカス中のセグメントは同じ塗りを使う。ライトでは不透明な白と影がボードと一致する。ダークでは白を不透明度 19.5% で重ねる。既定の背景上ではボードの sRGB (67, 63, 75) に 8 ビットの各チャンネルで 1 階調以内に一致し、他のダーク Look では背景の色相が残る。 タイトルとグリフの色は、行の位置の Look に選択背景を重ねた色とのコントラストで決める。 オフスクリーンでのタイトルのコントラスト比は、不透明で最も明るいダーク Look で 20.20:1、既定のダーク背景で 10.36:1 となる。 |
| `A-TabRows` | 複数行の選択 | — | 相違 | 現在のサイドバーでは選択行は 1 行。選択状態の描画には全行で共通の規則を使う。 |
| `A-TabRows` | 読み込み中とクラッシュのアイコン | `sidebar-rows-loading`, `sidebar-rows-crashed` | 未レビュー | 読み込み中はファビコンの位置にスピナーを表示する（決定 15）。 |
| `A-TabRows` | 未読の行とミュートした行 | `sidebar-rows-unread`, `sidebar-rows-muted` | 未レビュー | 未読ドットは、読み込み済みで非表示のタブのタイトル変更を契機に付く（決定 19、24）。 ドットにはスペースの Look のアクセントを使う。Look が色を持たない場合はモックの青緑、プライベートウィンドウでは中性色を使う。 |
| `A-TabRows` | 行のアーカイブと閉じるボタン | `header-command-w`, `sidebar-rows-hover`, `sidebar-rows-pressed` | 未レビュー | 行の種類と読み込み状態に応じてアクションが変わる（決定 29、32）。 |
| `A-TodayNewTab` | Today の区切り線、Clear、New Tab | `today (today, cleared, new-tab-row)` | 一致 | 区切り線と Clear が Today の上にあり、New Tab が先頭にある。構造検査は PASS。VM の実行 mp2。 |
| `A-TodayNewTab` | Clear 後の区切り線 | `today (cleared)` | 一致 | Today が空になると区切り線が消える。構造検査は PASS。VM の実行 mp2。 |
| `A-TodayNewTab` | Appearance で New Tab を非表示 | `today-new-tab-hidden` | 未レビュー | ワークスペースの設定で New Tab の行を隠した状態を撮影する。 |
| `B-CreateSpace` | スペース作成フォーム | `space-name-create-page` | 未レビュー | フォームはサイドバー内に表示する。 プルインジケーターは表示中のスペースのアクセントに従う。 |
| `B-CreateSpaceStates` | スペース作成の成功と失敗 | `create-space-created`, `create-space-failure` | 一致 | 有効な Create Space ボタンにはモックのチャコール色を指定し、Cancel には標準のラベル色を使う。作成の失敗と成功を個別に撮影する。 |
| `B-Drag` | サイドバーのドロップ位置、フォルダ上のホバー、拒否 | `organize-drop`, `organize-hover-open`, `dock-refused` | 未レビュー | 行のドラッグと、別プロファイルへのドロップ拒否を確認する。 |
| `B-Drag` | 別プロファイルへのドロップ拒否 | `dock-refused` | 未レビュー | セルを暗くし、ポインタに拒否マークを付ける（決定 68）。 |
| `B-DragPage` | 分割を作るページ上のドロップ領域 | `split-commands-drop-target` | 未レビュー | ドロップを確定する前に分割のインジケーターを撮影する。 ドロップ先の枠と背景には表示中のスペースのアクセントを使う。 |
| `B-Floating` | フローティングサイドバーの配置と内容 | `fullscreen-edge` | 未レビュー | ブラウザーの全画面表示中に画面端から開いたフローティングパネルを撮影する。 |
| `B-FloatingDark` | ダークのフローティングサイドバー | `fullscreen-dark-floating` | 一致 | ダークの既定背景は実測値 sRGB (22, 15, 31) を使う。画面上の合成結果はフローティングの再撮影で確認する。 |
| `B-FloatingMotion` | 端からの表示、待機時間、非表示 | `fullscreen-floating-before-reveal`, `fullscreen-dark-floating`, `fullscreen-floating-after-hide` | 未レビュー | ポインタを表示領域の端に置き、パネルを開いてから離す。3 枚は静止状態の画像で、待機時間と動作時間の判定には計測が必要である。 |
| `B-Fullscreen` | ページとブラウザの全画面表示、端からの表示 | `fullscreen-page`, `fullscreen-browser`, `fullscreen-edge` | 未レビュー | 状態ごとに撮影する。 |
| `B-History` | 履歴削除のエラーバナーと Retry | `toasts-banner` | 未レビュー | 削除失敗時に同一プロファイルの全ウィンドウで表示する（決定 56）。 |
| `B-HistoryStates` | 履歴ストアの失敗と再試行 | `toasts-banner` | 未レビュー | 失敗時のバナーを撮影する。再試行に成功するとバナーは消える。 |
| `B-Library` | Library のレールとアーカイブ一覧 | `keyboard-archive-list` | 相違あり。Clear Archive… は Ararat が [Phase 5](architecture.ja.md) で追加した操作である。Downloads は [Arc の Library レールの実測](research/arc-sidebar-layout.ja.md)に従って表示する。 | レールのタイルはラベルの上にアイコンを置き、ライト表示では選択中のタイルを白で塗る。フッターは dock の上に置く。Library を開いている間、dock のボタンは開いた時点のスペースの Look のアクセントで塗る。表示は Archive の撮影で確認する。 |
| `B-LibraryStates` | アーカイブ一覧の状態 | `keyboard-archive-list`, `keyboard-archive-search`, `keyboard-archive-no-matches`, `keyboard-archive-empty` | 相違あり。Ararat が [Phase 5](architecture.ja.md) で追加した Clear Archive… を dock の上に置く。 | 一覧、URL での絞り込み、検索結果なし、空一覧の各撮影でフッターを確認する。ライトとダークの両方でレールの選択表示を確認する。 |
| `B-Menus` | 行、スペース、分割のネイティブメニュー | `sidebar-rows-tab-menu`, `space-name-menu`, `split-commands-menu-open` | 未レビュー | Today のタブ、スペース名、左ペインのネイティブメニューを開いて撮影する。ほかの行種別とメニューの派生状態は別途撮影が必要である。 |
| `B-NoTab` | 空のページカードとショートカット案内 | `keyboard-no-tab` | 一致 | 空のカードと既定の 2 つの案内をオフスクリーンテストで確認した。VM の keyboard の撮影（merge/mockfix f9246dc、2026-11-19）で、カードと 2 つの案内の表示を確認した。 |
| `B-SpacePaging` | ページ切り替えとドックのクロスフェード | `dock-mid` | 未レビュー | ホイールによるページ切り替えのタイミングは別のチェックで記録する。 |
| `B-Split` | 2 ペイン、フォーカスリング、共通のナビゲーション | `split-focus (a, b)` | 一致 | 2 ペイン、フォーカス中のペインにアクセントのリング、ペインごとのバーは無い。サイドバーは 1 行にペインごとのセグメントを並べる（A-TabRows に従い、このページの一つの塗りには従わない）。VM の実行 mp2。 リングは表示中のスペースの Look に従い、編集中も更新する。プライベートウィンドウでは中性色を使う。 |
| `B-SplitStates` | 複数ペイン、仕切り、ドラッグ、移動 | `split-commands-vertical`, `split-commands-split`, `split-focus-frozen`, `split-focus-release`, `dialogs-transfer` | 未レビュー | 説明文は Swift が連続した仕切り線を描くとする。SplitDividerView はホバー中とドラッグ中にグリップを描画する。 |
| `B-SplitStates` | 一つのサイドバー行に並ぶ 3 ペイン | `split-commands (vertical)` | 一致 | 縦の split でもセグメントは三つ横に並ぶ。構造検査は PASS。VM の実行 mp2。 |
| `B-Tooltips` | ボタンと行のツールチップ、キーキャップ | `header-tooltip-toggle_sidebar`, `header-tooltip-back`, `header-tooltip-forward`, `header-tooltip-reload`, `header-command`, `header-command-r`, `header-command-w` | 未レビュー | ヘッダーのツールチップには個別の画像がある。Command-W の画像では行の閉じるボタンが押下状態になる。行のツールチップは撮影が必要である。 |
| `B-WindowStates` | ウィンドウ枠、最小幅、非アクティブ状態 | `window-drag-sidebar` | 未レビュー | ドラッグの画像はサイドバーを撮影する。非アクティブ時の色は別途撮影する。 |
| `C-DialogHost` | ページカード上のダイアログ | `permission`, `permission-dialog`, `javascript`, `javascript-dialog`, `dialogs-permission`, `dialogs-permission-dialog`, `dialogs-long-origin`, `dialogs-long-origin-dialog`, `dialogs-javascript`, `dialogs-javascript-dialog`, `dialogs-queued-permission`, `dialogs-queued-permission-dialog`, `dialogs-split`, `dialogs-split-dialog` | 未レビュー | 接頭辞のない画像は prompts、dialogs で始まる画像は dialogs を実行して取得する。ダイアログと親ウィンドウを個別に撮影する。 |
| `C-Downloads` | Library の進捗、ポップオーバー、全履歴 | `downloads-flight`, `downloads-ring`, `downloads-popover`, `downloads-library`, `downloads-popover-complete` | 相違あり。全履歴は実測の 56 pt の行間隔を維持する。 | 各状態の行を参照する。 |
| `C-Downloads` | 進捗リングとファイルアイコンの移動 | `downloads-ring`, `downloads-flight` | 未レビュー | 視差効果を減らす設定ではアイコンの移動を省く（§7）。 リングには表示中のスペースの Look のアクセントを使い、プライベートウィンドウでは中性色を使う。 |
| `C-Downloads` | 処理中と完了後のポップオーバー | `downloads-popover`, `downloads-popover-complete` | 未レビュー | 各段階の状態表示と実行できるアクションを比較する。 |
| `C-Downloads` | Library のダウンロード履歴 | `downloads-library` | 相違あり。全履歴は Arc 実測の 56 pt の行間隔を維持し、フッターに Clear All を置く。 | 見出しはウィンドウの操作ボタンの下に置き、幅の狭い行ではファイル名を独立した行に置く。幅 197 pt の一覧でモックのファイル名が収まることをオフスクリーンテストで確認した。表示は Downloads の撮影で確認する。 |
| `C-Extensions` | URL 欄のピン留め拡張機能とオーバーフロー行 | `ext-actions-action`, `ext-actions-overflow`, `ext-actions-three-actions` | 未レビュー | ホスト名に最低 64 pt を確保する（決定 47）。 |
| `C-Extensions` | 拡張機能アクションのオーバーフロー | `ext-actions-overflow`, `ext-actions-three-actions` | 未レビュー | アイコンの寸法、行の高さ、複数行に折り返す条件を個別に確認する。 |
| `C-Permissions` | 権限の確認とブロック済みサイトの表示 | `permission-dialog`, `site-controls-popover` | 未レビュー | permission-dialog は prompts、ブロック済みサイトのポップオーバーは site-controls で取得する。 |
| `C-SiteControls` | 撮影タイルとセキュリティ表示 | `site-controls (popover, certificate)` | 相違あり | モックでは四つのアクションを描く。製品には §7 に記載した二つを実装している。 |
| `C-SiteControls` | 縦長キャプチャ、翻訳、拡張機能グリッド、未実装の設定 | — | 未実装 | 対象の機能は §7 と §14 で実装を見送っている。 |
| `C-SiteControlsStates` | ポップオーバーの各状態の寸法 | `site-controls-popover`, `site-controls-overlay`, `site-controls-toast` | 未レビュー | 幅、パディング、間隔、ボタン寸法はトークンテストの対象である。 |
| `C-SiteControlsStates` | 証明書シート | `site-controls-certificate` | 未レビュー | セキュリティ表示から開く（決定 5）。 |
| `C-UrlField` | ホスト名、プレースホルダー、末尾のボタン | `urlfield (host, placeholder, internal, long-host)` | 相違あり | VM 実行 mp2 では、余白があっても IP ホストが「127.0....」と切れた。ボタンはモックどおり。main にホスト名の修正が入ったため、再撮影後に外観を確認する。 URL 欄、Copy Link、サイト操作ボタンのフォーカス枠には表示中のスペースのアクセントを使う。 |
| `C-UrlField` | 長いホスト名と狭い URL 欄 | `urlfield (long-host, long-host-narrow)` | 相違あり | VM 実行 mp2 では、先頭のフェードに加え末尾も切れた（「…example.inva...」）。`cac6112` ではラベルにホスト名全体を収める幅を確保し、末尾が早く切れる問題を修正した。再撮影後に外観を確認する。 |
| `CommandBar` | 概要のコマンドパネル | `commandbar-search`, `commandbar-recent` | 差異あり | ヒントには Return で選択行を開く操作を表示する。Tab による補完は U23 で廃止した（mock-decisions.md:84）。 |
| `D-CommandBar` | 検索を先頭に出す入力欄と履歴 | `commandbar-search` | 一致 | 検索が先頭に出て、その後に履歴が続く。選択行には表示中のスペースの Look のアクセントを使う。 |
| `D-CommandBarPanels` | コマンドパネルの各状態 | `commandbar-search`, `commandbar-settings`, `commandbar-open-url`, `commandbar-recent`, `commandbar-edit-url` | 差異あり | 選択行には Look のアクセントを使う。最近のタブには「Switch to Tab」を表示する。検索優先の決定に従い、Edit URL では Open URL の 1 行を表示する。 |
| `D-CommandBarRows` | 結果行の寸法、内側余白、行間 | — | 一致 | 対応表に記載した行と入力欄の寸法は一致した。行の外観は未確認である。 |
| `D-ErrorPages` | オフラインと DNS のエラー | `errorpages-offline`, `errorpages-dns` | 差異あり | Try Again にはスペースのアクセントを使う。オフラインのテストページでは、サイドバーに Chromium の内部 URL が表示されることがある。 |
| `D-FindBar` | ページ内検索バーと件数 | `header-find-bar`, `keyboard-find-count` | 未レビュー | header では検索欄を開いた直後を、keyboard ではテストページで件数と選択中の一致箇所が確定した状態を撮影する。 |
| `D-FindBarPage` | ページ上の検索バー | `header-find-bar`, `keyboard-find-count` | 未レビュー | keyboard の画像には、テストページと、件数を表示するページ内検索バーが写る。 |
| `D-LittleWindow` | バー、Open in メニュー、プロファイルメニュー、コマンドバー | `little-window-bar`, `little-window-profile-menu`, `little-window-space-menu`, `little-window-command-bar` | 未レビュー | 対応表はバーの高さ 48 pt の例外を記録し、色とコントロールの値を照合する。 |
| `D-PrivateWindow` | プライベートウィンドウと URL 欄のマスク | `private-window` | 未レビュー | プライベートブラウザのウィンドウを撮影する。 |
| `D-PrivateWindowEmpty` | 空のプライベートウィンドウ | — | 相違あり | 実装では最後のタブを閉じるとプライベートウィンドウも閉じる。モックは空のプライベートウィンドウを描く。オーナー判断待ち。 |
| `D-SadTab` | クラッシュした Today タブとピン | `errorpages-today-crash`, `errorpages-pin-crash` | 差異あり | Reload にはスペースのアクセントを使う。アイコンは点が並んだウィンドウを表示する。 |
| `D-TabSwitcher` | Control-Tab の切り替え画面 | `commandbar-tab-switcher` | 差異あり | 選択タイルには Look のアクセントを使う。パネルはウィンドウの中央にあり、タイルにはアイコンとタイトルを表示する。サムネイルとキーヒントは未実装である。 |
| `D-Toasts` | コピー完了、Clear の Undo、失敗バナー | `toasts-toast`, `toasts-banner` | 未レビュー | 履歴削除の失敗時はプロファイル内のウィンドウにバナーを表示する（決定 56）。 |
| `D-Toasts` | 更新完了と Restart | — | 未実装 | 更新機能は後のフェーズで実装する（§15）。 |
| `Dark` | ダークのブラウザ全体 | `fullscreen-dark-docked` | 一致 | ダークの既定背景は実測値 sRGB (22, 15, 31) を使う。その上で描く選択行は (67, 63, 75) に 8 ビットの各チャンネルで 1 階調以内に一致する。画面上の合成結果は固定サイドバーの再撮影で確認する。 |
| `E-About` | About と更新状態 | — | 未実装 | 現行の設定画面に About ペインはない。 |
| `E-AirTraffic` | ルーティング規則と移動先の編集 | `settings-air-traffic-settings-air-traffic`, `settings-air-traffic-settings-air-traffic-default-before-press` | 未レビュー | 2 枚目はルートを保存した後、Default destination のメニューを開く直前の画像である。 |
| `E-Appearance` | 外観の設定 | `settings-appearance-appearance`, `settings-appearance-theme-light`, `settings-appearance-theme-dark`, `settings-appearance-theme-system` | 差異あり | SwiftUI のスイッチには Look のアクセントを指定し、色が無い場合はモックの青緑を使う。Page zoom は未実装である。 |
| `E-Controls` | 設定画面のコントロールと操作時の状態 | `settings-frame-frame`, `settings-appearance-appearance`, `settings-shortcuts-shortcuts-recorder` | 差異あり | SwiftUI のコントロールとショートカットの記録欄には Look のアクセントを指定する。ネイティブのセグメントでシステムの色が使われる場合があり、モックのステッパーは未実装である。 |
| `E-Extensions` | インストール済み一覧、プロファイルメニュー、レビュー | `settings-extensions-extensions`, `settings-extensions-extensions-profile2`, `settings-extensions-extensions-review` | 未レビュー | インストール済み一覧は Chromium を通して取得する。 |
| `E-Extensions` | Arc から追加 | — | 未実装 | インポート元の調査と権限の設計が必要である（§14）。 |
| `E-Frame` | 設定画面のツールバー、レール、カード | `settings-frame-frame`, `settings-toolbar-toolbar-top`, `settings-toolbar-toolbar-scrolled` | 未レビュー | グループカードの角丸と間隔は対応表の値と一致した。 |
| `E-General` | 既定ブラウザ、起動時の動作、ダウンロード | `settings-general-general` | 未レビュー | この三項目はフェーズ 5 で実装した（§7）。 |
| `E-General` | General の残りの設定 | — | 未実装 | 終了前の確認、検索候補、検索エンジン、スペルチェックは後の実装とする（§7）。 |
| `E-LittleWindow` | ショートカット、移動先、閉じる動作、サイズと位置の保持 | `settings-little-window-little-window` | 未レビュー | 設定チェックで Little Window の各行を操作する。 |
| `E-Passwords` | 保存済みパスワードと Touch ID | — | 未実装 | U20 のパスワード設定は計画段階にある。 |
| `E-Privacy` | 閲覧データの消去、保持期間、Cookie とプライバシー設定 | `settings-privacy-privacy`, `settings-privacy-privacy-sheet` | 未レビュー | 保護機能の仮の項目はこのフェーズの製品に表示しない（§7）。 |
| `E-Privacy` | ブロッカーと危険なサイトの警告 | — | 未実装 | 方式と情報源は未決定である（§14）。 |
| `E-Search` | 設定内検索と該当項目の強調 | `settings-search-search`, `settings-search-search-cleared` | 未レビュー | 検索結果の強調表示の角丸、内側余白、行の高さはトークンテストの対象である。 |
| `E-Shortcuts` | ショートカット一覧、入力、競合の表示 | `settings-shortcuts-shortcuts`, `settings-shortcuts-shortcuts-recorder`, `settings-shortcuts-shortcuts-conflict`, `settings-shortcuts-shortcuts-refusal` | 未レビュー | テスト用の割り当てを元に戻した後、⌘T の割り当て先を表示する競合状態と、システム予約済みの ⇧⌘3 を拒否した状態を撮影する。 |
| `E-SpacePage` | スペース個別の設定 | `settings-spaces-space-page`, `dock-space-settings`, `settings-appearance-look-space-page` | 未レビュー | Spaces と Dock のチェックで、個別のスペースの設定を開く。Appearance のチェックでは Look の行から開く。 |
| `E-Spaces` | スペース一覧とスクロール方向 | `settings-spaces-spaces` | 未レビュー | スクロール方向はワークスペース全体の設定である。 |
| `E-Sync` | 同期設定とデバイス | — | 未実装 | 同期はフェーズ 8 で実装予定である（決定 100）。 |
| `E-Tabs` | タブ設定とスペースへの移動 | `settings-tabs-settings-tabs`, `settings-spaces-space-page` | 未レビュー | Tabs チェックではペインを撮影する。個別のスペースの設定は Spaces チェックで開く。 |
| `E-Websites` | 既定とサイト別の権限 | `settings-websites-websites`, `settings-websites-site-row`, `settings-websites-site-page` | 未レビュー | サイト別の設定を作成してからページを開く。 |
| `Extensions` | ピン留めした拡張機能の概要 | `ext-actions-action`, `ext-actions-overflow` | 未レビュー | 配置は URL 欄に関する決定 42 に従う。 |
| `F-Import` | インポート対象の選択、進捗、完了 | `onboarding (what-to-import, progress, done)` | 相違あり | フィクスチャを使うフローでは、ログイン状態、パスワード、履歴、アーカイブの行を省いている（§7）。 |
| `F-Import` | ログイン状態の引き継ぎとキーチェーン権限 | — | 未実装 | キーチェーンを使うフローにはインポートの調査が必要である（決定 105–106）。 |
| `F-LookControls` | 透明度、Glass のデテント、粒状感、メニュー | `look-55-popover`, `look-detent-popover`, `look-glass-popover` | 未レビュー | ポップオーバーの画像にスライダーとデテントが写る。Look のメニューは撮影が必要である。 |
| `F-LookGallery` | プリセットとカラーピッカー | `look-55-popover` | 未レビュー | モックと同じプリセットページを開いた状態で比較する。 |
| `F-LookPopover` | Look ポップオーバーと色の入力欄 | `look-55-popover`, `look-glass-popover` | 未レビュー | 該当するモック内の見本とポップオーバーのフレームを組み合わせる。 Look が色を持たない場合、設定画面の色見本にはモックの青緑を使う。 |
| `F-LookSidebar` | 設定値ごとのスペース色とサイドバー | `look-55-sidebar`, `look-detent-sidebar`, `look-glass-sidebar` | 未レビュー | サイドバーとポップオーバーを対応する組として記録する。 |
| `F-LookStates` | カラーピッカー、プリセット、粒状感の各状態 | `look-55-popover`, `look-grain0-sidebar`, `look-grain5-sidebar`, `look-grain50-sidebar`, `look-grain100-sidebar` | 一致 | 濃紺の Grain 検査を Auto に設定した。URL のプレースホルダー、行のタイトル、Clear、dock のグリフは明るい前景色になる。粒状感の 4 状態は再撮影で確認する。 |
| `F-Onboarding` | ようこそ、ソース、対象選択、既定ブラウザ、進捗、完了、二つのエラー | `onboarding-welcome`, `onboarding-source`, `onboarding-what-to-import`, `onboarding-default-browser`, `onboarding-progress`, `onboarding-done`, `onboarding-error`, `onboarding-sibling-file` | 未レビュー | ボタンの高さと間隔の例外はオーナー決定としてトークン表に記載した。 |
| `F-Onboarding` | ようこそとインポート元の検出 | `onboarding-welcome`, `onboarding-source` | 未レビュー | インポート元のチェックは Arc 検出のフィクスチャを使う。 |
| `F-Onboarding` | インポート対象と既定ブラウザの設定 | `onboarding-what-to-import`, `onboarding-default-browser` | 未レビュー | インポート対象の行と既定ブラウザの操作を個別に確認する。 |
| `F-Onboarding` | キーチェーンのアクセス要求 | — | 未実装 | 3a はログイン状態を引き継げるか確認した後に実装する（決定 106）。 |
| `F-Onboarding` | 進捗と完了報告 | `onboarding-progress`, `onboarding-done` | 未レビュー | 報告の各行はインポートのフィクスチャに基づく。 |
| `F-Onboarding` | インポートエラーと関連ファイルの警告 | `onboarding-error`, `onboarding-sibling-file` | 未レビュー | 失敗の二つの状態を個別に撮影する。 |
| `Floating` | フローティングサイドバーの概要 | `fullscreen-edge` | 未レビュー | ブラウザーの全画面表示中に画面端から開いた状態を撮影する。通常のウィンドウでの浮動表示は別途撮影が必要である。 |
| `Main` | メインウィンドウの概要 | `header-240` | 相違 | ライトの選択行は白で描く。Main ボードのレンダリングではお気に入りがページにまたがって縦に並ぶため、選択行は A-TabRows と比較する。 |
| `Themes` | Look の概要、色レイヤー、スライダー | `look-55-popover`, `look-55-sidebar`, `look-detent-popover`, `look-detent-sidebar`, `look-glass-popover`, `look-glass-sidebar` | 相違 | Auto の文字色は決定 114 に従う。ボードのレンダリングにテンプレートの未展開箇所があるため、比較できる範囲はサイドバーに限られる。 |
