# Yab の静的解析（2026-10-31 時点）

この文書は `yab-static.md` の日本語訳である。内容が食い違うときは英語版に従う。

対象: Yab 0.42.1（`/Applications/yab.app`、bundle id `dev.serafim.fast`）。ソースは公開されていない。Yab の規約（2026-09-30 版）は lawful な利用を認め、解析を禁じる条項は無い。この文書には名前・構造・挙動だけを記録し、デコンパイルしたコード、ページスクリプト、アセットは引用しない。

解析の手順と再現の方法: `yab/README.ja.md`。

## 1. ビルドとエンジン

- universal binary（x86_64 と arm64）である。arm64 部分は 69 MB で、そのうち `__text` が 57 MB を占める。
- エンジンは WebKit である（`WKWebView`。`WebKit.framework` と `JavaScriptCore.framework` にリンクしている）。Chromium と CEF は含まない。
- UI は、ウィンドウとサイドバーが AppKit の view である。SwiftUI もリンクされ、併用している（どこで使うかは調べていない）。
- アプリ本体の Swift モジュールは `Fast` である。内部のモジュールとして `YabStore`（システムの `libsqlite3` を使う `SQLiteConnection`）と `SyncKit`（データベースの handle を持つ `Journal` 型がある）の名前が見える。SQLite のストアとジャーナルの組み合わせは、Ararat の §5.2・§6.2 の設計に近い。Yab のジャーナルが何を記録するかは確かめていない。
- 他に使っている framework には、`FoundationModels`（weak link）、`Translation`、`ScreenCaptureKit`、`AuthenticationServices`、`EventKit`、`Contacts`、`MapKit` がある。

## 2. AppleScript の辞書（`Yab.sdef`）から分かるワークスペースのモデル

辞書は公開されたインターフェースなので、Yab のモデルの根拠として最も確かである。

| クラス | プロパティ |
|---|---|
| window | id、name、index、minimized、visible、active tab、active tab index、**active space**、mode（`incognito` か `normal`。プライベートのタブは一覧に出ない）、incognito |
| tab | id、title、URL、loading、**location**、space |
| space | id、title、icon（絵文字）、color（ライトの外観での色、16 進） |

- タブの `location` は「Arc の呼び方で」と説明され、値は 3 つある。`topApp` はピン（お気に入り）、`pinned` は残しておくタブ、`unpinned` は今日のタブを指す。Yab は Arc の 3 つのコンテナの呼び方をそのまま使っている。これは Ararat のモデルと Arc のインポーター（`pinned`・`unpinned` のコンテナ、`topAppsContainerIDs`）に一致する。
- space はライトの外観での色を 1 つ持つ。辞書には space ごとのプロファイルは出ていない。
- コマンドは次のとおりである。`select`（タブを前面に出し、必要ならその space に移る）、`focus`（space かタブ）、`go back`、`go forward`、`reload`、`stop`、`open small window`（Arc の Little Arc に当たる）、`ask`（⌘J のアシスタント）、`show mail`。

## 3. 領域ごとのクラス一覧

名前が残るのは、Objective-C から見える Swift のクラスだけである。そのようなクラスは 358 個あった。領域ごとに分けると次のとおりである。

| 領域 | クラス |
|---|---|
| サイドバー（「column」） | `ColumnView`、`ColumnPage`、`ColumnPages`（おそらく space ごとに 1 ページ）、`ColumnOverlay`、`ColumnHand` |
| space | `SpaceTray`（`Panel` を持つ）、`SpacePager`、`SpaceSwipe`、`SpaceAnchor`、`SpaceDrop`、`SpaceForm`、`SpaceWash` |
| ウィンドウの枠 | `BrowserWindow`、`Browser`（`WKNavigationDelegate`・`WKUIDelegate`）、`LightsRow`（信号ボタンの列）、`WindowBackdropView`、`BarsLayer`、`LoadBar` |
| 画面端の UI | `EdgeTray`、`FloatEdgeTab`、`EdgeHandle`、`EdgeBlurView` |
| ピクチャインピクチャとフローティング動画 | `Floater`（`Controls`、`Scrubber`、`Clock` を持つ）、`FloatHand`、`FloatLip`、`FloatGlass`、`FloatButton`、`Glider` |
| Peek（リンクのプレビュー） | `PeekView`、`PeekCardView`、`PeekSurfaceView`、`SidePeek`、`StripPeek`、`HeadPeek` |
| 拡張機能 | `ExtensionTab`、`ExtensionWindow`、`ExtensionPanel`、`ExtensionSidePanelPage` |
| その他のウィンドウ | `LinkWindow`（おそらく小さいウィンドウ）、`PopoutWindow`、`SettingsWindow`、`DevDetachedWindow`、`DocumentPiPPanel` |

- `Float*` のクラスはフローティング動画のもので、サイドバーのものではない。`FloatHand` は「controls-hover」という記録を出し、`FloatLip` は `sliding` と `carried` の状態を持つ。
- フローティングサイドバーを出し入れする処理は見つけられなかった。その処理は名前が除かれた Swift のクロージャの中にある。

## 4. ウィンドウの外のポインタの追跡: `LightsRow`

信号ボタンの列にポインタが乗っている間、`LightsRow` は run loop に 1/30 秒間隔の `NSTimer` を起こし、ローカルとグローバルの両方の `NSEvent` の監視を登録する。処理の中では `NSEvent.mouseLocation` を読み、ボタンの矩形と比べる。診断のために記録する理由には、「no window」「button window」「window inactive/nonkey」がある。

グローバルの監視を登録するクラスは、フローティング動画（`FloatHand`）を除けばこれだけである。architecture §7 のポインタのサンプリングの前例になるが、間隔は表示のリフレッシュレートではなく 30 Hz である。サイドバー自体の挙動を示す根拠にはならない。

## 5. 設定らしい文字列

- `sidebar.density`、`sidebar.left`、`sidebar.left.round`、`sidebar.right`、`sidebar.right.round`: サイドバーは左右どちらにも置け、角を丸めた形があり、密度の設定がある。
- `settings.set.color`、`settings.set.glass`、`settings.set.grain`、`settings.set.sidebar`、`settings.set.transparency`: 外観の設定（色、ガラス、粒子、透明度、サイドバー）。
- `tabs.*`: `awake`、`sleep`、`close`、`pin`、`rename`、`reorder`、`tidy`、`group`、`glyph`、`folderEmoji`、`linkFolders`、`meetingFolders`、`researchFolders`、`optShiftFolders`、`todayEveryWindow`。
- 切り替えの設定らしい名前: `snapToEdges`、`showSidebar`、`hideSidebar`、`turnedSidebar`、`sidebarTabs`、`sidebarPin`。

どれも `UserDefaults` のキーであるとは確かめていない。メニューやコマンドの識別子である可能性がある。多数ある `yab.*` の形の文字列はアイコンの名前である。

## 6. 同梱のリソース

- `skills/`: Yab のアシスタント用の、サイトごとの skill が 42 個ある（Gmail、Google Docs、Slack、Notion、Linear、GitHub、Jira、パスワード管理など）。加えて `skill-creator` がある。
- `PageScripts/`、`DevTools/`、`DarkReader/`、`Charm/`、`Google/`、`Metadata.appintents`（App Intents）。
- Chrome の拡張機能は、WebKit 上で shim のスクリプト（インストールした拡張機能のフォルダにある `yab-shim.js`）を通して動く。その挙動は解析していない。

## 7. 限界

- Swift の関数名は `@objc` のメソッドを除いて除かれており、ほとんどの処理は名前の無い関数として見える。
- Objective-C のメッセージの解析器を外した（`yab/README.ja.md` の 2 節）。そのため、デコンパイルの結果では `objc_msgSend` を通る呼び出しがセレクタに解決されない。セレクタのスタブは手で辿れる。
- 待ち時間や余白の幅のような時間・寸法の値は、静的解析では得られない。それらは Yab の実機での観察（HANDOVER の Next 2）で取る。
