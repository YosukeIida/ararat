# Ardia の設計判断の台帳

対象: mantrakp04/ardia（GPL-3.0）。2026-10-30 時点の main と、commit `2713787d` 時点の文書を `gh api` で読んだ。コードは読んでおらず、写してもいない。判断と理由だけを取った。

用語:
- **ArdiaCore**: Chrome 自身の `//chrome:chrome_framework` に自前の層 `//ardia/core` を入れた framework。Dia の ArcCore と同じ方式である。
- **自前層**: `//ardia/core`（`engine/ardiacore/src`）と `//chrome/browser/ardia`（`engine/chromium/src`）。どちらも repo に置き、`apply.sh` で tree に複写する。
- **hook**: Chrome のファイルに置いた `g_ardia_*` の関数ポインタ。未設定なら Chrome は素のまま動く。
- **store**: React Native 側の zustand の状態。ワークスペース（サイドバーの並び・ピン・グループ・split）を持つ。
- **review**: 2026-10-01 の `docs/architecture-review.md`（`2713787d` にのみ存在）。

変遷の年表（すべて 2026 年）:

| 日付 | 版 | 出来事 |
|---|---|---|
| 〜09-25 | 0.1 以前 | CEF Alloy（Chrome の `Browser` を使わない）。終了時に約 7,500 行を削除 |
| 09-25 | 0.1.0 | CEF 154 Chrome style ＋ 不可視の「ghost」 Chrome window を RN window の背後に置く方式。ungoogled-chromium |
| 09-26 | 0.2.0 | Chrome-hosted window（Chrome の window を app window にし、RN の root をその中に入れる）。ghost を削除 |
| 09-26 | 0.2.4 | アカウント無しの E2E 暗号化同期 |
| 10-01 | — | review。推奨 5 で ArdiaCore へ。同日 spike で GO-WITH-CHANGES |
| 10-02 | 0.2.22 | ArdiaCore に切替（CEF と同じ Chromium 154 のまま、データ移行なし） |
| 10-09 | 0.2.31 | CEF を tree から削除 |
| 10-19 | 0.2.38 | Chromium 155、official build ＋ ThinLTO ＋ PGO。uBO Lite（MV3）から uBlock Origin（MV2）へ |
| 10-24 | 0.2.40 | ungoogled-chromium から Helium の patch 群へ。配布物が GPL-3.0 になる |
| 10-26 | 0.2.41 | Chromium 156。DRM サイトを WebKit で開く第二エンジン |
| 10-28 | 0.2.43-nightly.4 | 自前のタブ sleep を捨て、Chrome の Memory Saver に置換 |

---

## 1. 判断の台帳

適用欄: 採る／採らない／要検討。新ブラウザ（Swift/AppKit の UI、Chromium fork に自前層を置く ArcCore 方式、Rust の中核、後で Windows/Linux/iPhone）への適用を書く。

### 1.1 エンジンの組み込み（CEF → ArdiaCore）

| 判断 | 理由 | 退けた代替案 | 根拠 | 新ブラウザへの適用 |
|---|---|---|---|---|
| CEF を捨て、`//chrome:chrome_framework` に自前層を link し、自前の `BrowserWindow`（`BrowserView`・frame・tab strip・toolbar を持たない普通のオブジェクト）を実装する | CEF が 3 つの構造的な衝突を強いる。(1) Chrome style の CEF browser は Views の widget window そのもので、window 層を 2 週間で 2 回作り直した。(2) Chrome が自分で作るタブ（`window.open`、拡張、`chrome.windows.create`）を callback で横取りして adopt する仕組みが要り、POST body が落ちた。(3) external message pump で autofill がクリックを無視し、30 Hz の idle poll が要った。前週の app・engine commit の 42%、修正 commit の 56% が CEF/Chrome の継ぎ目に触れ、engine patch の行の 77% が CEF の API に Chrome のオブジェクトを通すためだけにあった | CEF の API を拡張し続ける。TabStripModel を唯一の真実にする。Alloy（`Browser` 無し）。OWL 型の別プロセス host（ChatGPT Atlas）。SwiftUI/AppKit への UI 書き換え | review › 推奨 5、§ A、§ B | 採る。最初から ArcCore 方式で始め、CEF の段階を踏まない |
| 移行は strangler だが「window の種類ごと」ではなく「同じ JS API の背後に第二の native 実装を作り、parity で一度に切り替える」 | CEF と ArdiaCore はどちらも完全な Chromium で、1 プロセスに同居できない。review の当初案（Little Ardia から 1 種類ずつ）は不可能と spike で判明 | 1 つの app の中で window 種類ごとに置き換える | ardiacore-spike.md › 冒頭の Verdict、› Codex second opinion | 採る（教訓として）。中核 API を UI から切り離しておけば、エンジン差し替えは裏側の実装の交換で済む |
| Chromium がプロセスの run loop を持つ（`ChromeMain` → `MessagePumpNSApplication` → `[NSApp run]`）。`NSApp` は Chrome の `BrowserCrApplication`、RN の host はその中で起動する | external pump の不具合（idle work が走らない、wakeup 41 → 15/s のための poll）が根から消える。Dia の Swift UI も同じ構成 | `CefRunMessageLoop` へ戻す（終了処理の再設計が要る中規模作業とされた） | review › 推奨 5 (3)、§ G、agent-brief.md › Stack | 採る。ただし制約として扱う: `NSApp` に触るのは Chromium 起動後のみ。Swift/AppKit の UI も Chromium のループの中で起こす設計にする |
| Chrome の `AppController` は作らず代役を立て、`terminate:`・Dock・logout の quit Apple event を自前で受け、beforeunload・ダウンロード確認を経る取り消し可能な close/quit を実装する | CEF の patch が `AppController` を消していたため、無いと window が無い状態で app が生き残れず、`terminate:` の経路も壊れる。quit が page に取り消されたとき keep-alive を保持する必要がある | Chrome の `AppController` をそのまま使う | ardiacore-spike.md › Stage 1 runtime、› What the spike does not prove | 採る。自前 `BrowserWindow` を持つなら必ず生じる責務として最初から設計に入れる |
| app window 1 枚 = `ArdiaCoreWindow` 1 つ（Views-backed の `NSWindow`）。そこに profile ごとの `Browser` を複数つなぐ | Chrome の bubble・dialog・menu・autofill の dropdown が子 window としてその window に付く。profile 切替が view の差し替えになり、旧方式の `MoveRoot`（切替 1 回で main thread 15–25 ms）と profile ごとの Chrome window が消える | profile ごとに Chrome window を持つ（0.2.0 の方式。full screen で補助の子 window が要った） | agent-brief.md › Stack、ardiacore-spike.md › What was built、review › 推奨 5 (1) | 採る。widget-backed window は Chrome の bubble を付ける安価な方法として Codex も同意している |
| popup・`target=_blank`・⌘-click は Chrome が作った `WebContents` と navigation をそのまま受け取り、自前 `Browser` のタブに書き換える | `Browser::AddNewContents` が作成済み・navigation 済み（POST 込み）の `WebContents` を渡すので、adopt も replay も要らない | CEF の `OnBeforePopup` → JS → id で adopt（30 s の orphan timer）、Chrome が勝手に作った window を隠して URL を再生する `StrayWindowClient` | review › 推奨 5 (2)、ardiacore-spike.md › What was built › Popups | 採る |
| Chrome が自分で作る window（`chrome.windows.create`、incognito、undocked DevTools）は `Browser` のコンストラクタの hook で host に問い合わせ、自前 window に収める | 放置すると Views の `BrowserView` window ができる | `Browser` の生成経路を全部自前にする | ardiacore-spike.md › Stage 1 runtime（S5）、perf/vs-browsers.md › New window | 採る。ただし Ardia では新規 window が既存 window に吸われる parity の不具合が 2026-10-16 時点で残っていた |
| 自前層への入口は plain C: 全 export が `ac_<domain>_<verb>` で同一シグネチャ（profile dir、JSON 引数、reply callback）。app は `dlsym` で引き、欠けていれば abort。private profile への呼び出しを許すかはエンジン側だけが決める | 新しい能力ごとに CEF の header・translator・wrapper・marker が要った負担を消す。app とエンジンは同梱なので、欠けた export は「想定外のエンジンを同梱した」誤りとして即死させる | CEF の C API の拡張。Dia は mojom から ObjC binding を生成（146 クラス、205 header） | engine-build.md › Our own code in the tree、review › § B「What Dia does」、research `chromium-ui-layer.md`（`2713787d`）› Evidence | 要検討。Rust 中核との FFI をどちらに寄せるか（JSON 一本か、mojom 生成の型付き binding か）の比較材料になる。JSON は型が無い代わりに表面が 1 つで済む |
| 中核の JS API（`WebView`、モジュール）は CEF 時代のまま残し、native 側だけを差し替える | 移行中も store と UI を進め続けられる。2 つの app target が同じ JS から build される | API ごと作り直す | review › 推奨 5、ardiacore-spike.md › Migration plan | 採る（UI が Swift でも、UI と中核の境界を固定する考え方は同じ） |
| renderer 側は自前の `ContentRendererClient` ＋ mojom で page script を全 frame の main world に注入し、`ardia:` scheme を `NavigationThrottle` で扱う | CEF が提供していた process message・page script を置き換える | — | ardiacore-spike.md › Stage 1 runtime（S4） | 採る。ただし副作用として、この mojo binding が prerender を全部キャンセルさせた（§ 1.6） |

### 1.2 Chromium の fork の管理（patch series・hook・Helium/ungoogled・GN・ビルド基盤・rebase）

| 判断 | 理由 | 退けた代替案 | 根拠 | 新ブラウザへの適用 |
|---|---|---|---|---|
| 新しいエンジンのコードは新規ファイル（`//chrome/browser/ardia`、`//ardia/core`）に置き、Chrome のファイルには小さな hook だけを入れる。tree を直接編集しない | rebase の費用は Chrome のファイル内の hunk の数で決まり、新規ファイルはほぼ衝突しない | 大きな in-place patch（例: PiP の 1,012 行・13 ファイルの patch） | review › 推奨 7、engine-build.md › Our own code in the tree | 採る |
| 大きな in-place patch は新規クラス＋小さな hook に書き直す（PiP の overlay window を `VideoOverlayWindowViews` の subclass にし、hook は 6 メソッドを virtual にするだけ） | 同上。約 100 行を超えて Chrome のファイルを書き換える patch はすべて対象 | patch のまま保守 | review › 推奨 7、engine-build.md › patch 表 `chromium-pip-overlay-window` | 採る |
| hook は `g_ardia_*` の関数ポインタで、宣言は 1 つのヘッダ（`ac_hooks.h`、`ac_content_hooks.h`）に集め、Chrome 側と自前層が同じヘッダを include する | シグネチャがずれたら初回呼び出し時のクラッシュではなくコンパイルエラーになる。未設定なら Chrome は素のまま動く | 名前空間を借りる（CEF の `cef::` seam を流用していた時期があった） | engine-build.md › Our hooks in Chrome's code | 採る |
| patch の順序は `series` ファイルが唯一の正本。1 patch = 1 関心、名前は関心で付け、名前の接頭辞（`zz-`、`zzz-`）で順序を表さない | 名前で順序を表していた時期に、ある patch が別の patch の marker を運んでいた | 名前の辞書順で適用 | review › 推奨 7、engine-build.md › The patch series、engine/patches/series の冒頭のコメント | 採る |
| `series.py check`: 適用前の base を記録し、scratch に series 全体を fuzz 無しで適用して tree とバイト単位で比較する。nightly で回す | series が実際に build している tree を再現することを保証する。tree だけで行った編集（patch に無い変更）を検出する | 目視、CI 無し | engine-build.md › The patch series | 採る |
| `apply.sh` の hook は marker 付きで冪等。全部あれば skip、一部だけなら拒否、`--check` で欠落を報告 | 二重適用と部分適用を防ぐ | — | engine-build.md › ArdiaCore's layer | 採る |
| series の現状は `chromium` 行 64 本＋layer 2 本（2026-10-30）。2026-10-01 の棚卸し時は CEF 層 16 本（+3,403 行）＋Chromium 21 本（+1,001 行） | 本数は fork 後に増えたが、中身は hook、Helium の打ち消し、性能（frame rate、凍結、Bluetooth の poll）、セキュリティの硬化（Safe Storage、パスワードの消去、DevTools の token）に寄っている。CEF の API を通すための patch は消えた | — | engine/patches/series、review › § C | 要検討。本数より「Chrome のファイルに入る hunk の量」を指標にする |
| CEF の 117 patch を 1 本ずつ処分（大半を dropped、一部を `chromium-cef-carryover.patch` に畳み、seam は自前 hook H1–H6 に置換） | 不要な理由を patch ごとに記録した: Windows/Linux 専用、OSR、Alloy、CEF の API・Views・build、crash upload | まとめて捨てる | engine-build.md › CEF's 117 patches | 採る（手法として）。Windows/Linux 専用として落とされた patch の数は、後で Windows/Linux の自前 `BrowserWindow` を持つときの作業の目安になる（要検討） |
| 基盤を ungoogled-chromium から Helium（ungoogled ベース）に替え、skip list と guard で Helium の一部 patch を外し、Helium の挙動の一部を自前 patch で打ち消す | commit `d730de33` と 0.2.40 の release notes は結果だけを書き、理由の明文は無い。読み取れる利点は、Helium が Chromium に追従する（新しい Helium tag = 新しい Chromium）、fingerprint の noise・HTTPS-First・InfiniteTabsFreezing などの既定値、uBO（MV2）の扱い | ungoogled のまま | engine-build.md › Helium、commit `d730de33`、release-notes 0.2.40 | 要検討。理由は推測である。代償として GPL-3.0 化（次行）と、打ち消し patch の保守（Web Store 直結、updater、onboarding、!bangs、NTP など 10 本以上）が生じた |
| Helium の patch が GPL-3.0 のため、engine と配布物全体を GPL-3.0 にする。自前ファイルは Apache-2.0、ungoogled 由来の patch は BSD-3-Clause のまま。各 release に Corresponding Source（tag と source tarball）を付ける | ライセンス上の帰結 | — | engine-build.md › Licence and source、releasing.md › Source and licenses | 要検討（配布物のライセンスは基盤の patch 集に従う: ungoogled は BSD-3-Clause、Helium は GPL-3.0） |
| Helium の patch のうち、パスワード管理の無効化・keychain 名の変更・Sparkle の組み込み・crash dialog・build 設定などは skip する。guard が「skip した patch が series に残っているか」「適用する patch が skip の守る対象に触れていないか」を検査する | Ardia は Chrome のパスワード管理を使い、Safe Storage の keychain item 名が全ユーザーのデータの鍵であり、updater は app が持つ | Helium を丸ごと適用 | engine-build.md › Helium › Skipped | 採る（上流の patch 集を取り込むなら、守る対象を guard で機械検査する） |
| GN args は `gn_defines.sh` に全部書く。official build（ThinLTO、strip）＋ PGO（Chromium の mac-arm profile）、DCHECK 無し、symbol 無し、proprietary codecs、Widevine 有効（ただし Google の VMP 署名が要る）、`safe_browsing_mode=0` | 0.2.38 で official build ＋ PGO にし、起動と tab switch が速くなった | — | engine-build.md › Rebuilding › GN args、release-notes 0.2.38 | 採る（official ＋ PGO）。要検討: Safe Browsing を compile out した穴（issue #249 が最大の欠落と指摘、未解決） |
| ビルドは repo 外の `~/chromium-build`、incremental のみ。初回は M5 Pro で約 2–2.5 h、incremental は compile ＋ ThinLTO relink で約 7 min、ディスク約 45 GB。Chromium の版上げは `out/` を消す full build なので owner の承認が要る | 1 台の機体で agent が並行作業するため、chromium lock で engine の編集・build を直列化する | 第二の `out` を別 checkout に持つ（ディスクと初回 5 時間のため owner 判断として保留） | engine-build.md › Rebuilding、agent-brief.md › The engine、review › § F | 採る（lock）。要検討: engine の build を並列化する手段 |
| CI は engine を build しない。engine は手元で build し、`engine/` の git tree hash をキーに prerelease へ上げ、app の build はその hash で prebuilt を取る | 普通の CI job では Chromium framework を build できない | CI で engine を build | releasing.md › Engines、engine-build.md › Using it | 採る |
| 版上げの手順を文書化: shallow な `src` は tag を depth 1 で取り、dep が止まったら dep の checkout を消して取り直す（156 では 3.5 分） | 素の `git fetch` が全履歴の pack を要求し、server 側で 1 時間無音になる | — | engine-build.md › Rebuilding › Moving to a new Chromium version | 採る |
| rebase の練習を spike の合格条件に入れた（154 → 155 で ArdiaCore 側は約 6 箇所の小さな修正） | 自前 `BrowserWindow` は milestone ごとに動く大きな interface なので、費用を事前に見る | — | ardiacore-spike.md › Practice rebase、review › 推奨 5 | 採る |

### 1.3 window とタブのモデル

| 判断 | 理由 | 退けた代替案 | 根拠 | 新ブラウザへの適用 |
|---|---|---|---|---|
| タブの view（`WebContentsViewCocoa`）を自前の view tree に直接入れる | Dia と同じ合成モデル。prototype で最も入力→表示の遅延が小さく（p50 15.8–23.3 ms、120 fps）、web content の上に `CABackdropLayer` の blur をかけられる | OSR（IOSurface → `CAMetalLayer`、60 fps 上限、42 ms）。OWL 型（入力・IME・accessibility の再配線が要る） | research `chromium-ui-layer.md`（`2713787d`）› Prototype measurements | 採る |
| ワークスペースのタブ（未 load のタイル、parked pin、「表示時に load」）は `WebContents` を持たない | ワークスペースの多くのタブに live な `WebContents` は要らない | TabStripModel を唯一の真実にする（全タブに `WebContents` が要る） | review › 推奨 1、§ B | 採る |
| タブの view は profile ごとに自前の compositor を持つ（Chrome は window に 1 つ） | 自前の view tree にタブを入れる方式の帰結 | window ごとに compositor を共有（タブ view の描画方式の書き換えになるため保留） | perf/vs-browsers.md › Tab switch | 要検討。tab switch のたびに frame sink と begin-frame source を作り直し、vsync の格子から外れる代償がある（§ 1.6） |
| 生きたタブの操作は command（id 付き）で送り、エンジンが commit し、revision 付きの transaction で返す（詳細は § 1.4） | 下記 | — | store-api.md › Live tabs | 採る |
| Peek（一時的なタブ）は Recently Closed にも Chrome の session にも残さない（hook で除外） | 一時的なページが本物の履歴項目を押し出さない | — | engine-build.md › `chromium-temporary-tab-restore-hook.patch` | 採る（機能を持つなら） |
| session は自前（`session.json`）が持ち、Chrome の `SessionService` は自前の `Browser` を追跡しない | 自前の session と二重に復元されない | Chrome の session restore を使う | engine-build.md › `chromium-hosted-browsers-no-session-service.patch` | 採る |
| test instance の window は通常より 1 段低い level に置き、activation を全部拒否する | 並行して動く agent の test instance が owner のキー入力を奪った事故がある | `open -g` だけ | agent-brief.md › Rules、testing.md › Test instances | 採る（agent で開発するなら） |

### 1.4 状態の持ち主

| 判断 | 理由 | 退けた代替案 | 根拠 | 新ブラウザへの適用 |
|---|---|---|---|---|
| one writer per fact: store がワークスペース（並び・ピン・グループ・split・window ごとの表示タブ）を、Chrome の `TabStripModel` が生きたタブ（どの `WebContents` がどの `Browser` にあるか、順序、active）を持つ | 双方向の権限を JS が推測していた時期に、activation の ping-pong（20 タブ開くと window の更新が 230 回、12 回開くと切替が 46–75 回）が起き、3 回の追加修正が要った。1 週間で mirroring のファイルに 41 commit、うち修正 12 | TabStripModel を唯一の真実にする。Chrome が変更前に app に聞く | review › 推奨 1、§ B、store-api.md › Live tabs | 採る |
| Chrome が commit し、app に事前に聞かない | 拡張の関数（`tabs.update({active})` など）は同じ呼び出しの中で変更して結果を読み返す。非同期の問い合わせにすると多数の呼び出し元の完了の意味が変わる（Codex の指摘で review の初稿を逆転） | Chrome が変更前に app に問い合わせる | review › 推奨 1、§ H | 採る |
| transaction は `{rev, cmd, strips}`。`rev` は単調増加、`cmd` は原因（自分の command の id、自分の engine 呼び出しは `-1`、Chrome 自身の変更は `null`）。1 つの transaction は原因を混ぜない。JS 再起動時は `tabStrips()` を起点にする | echo の時間窓・「自分が起こしたか」の flag・timer を全部消す。遅れた報告が状態を巻き戻さない | 1 秒の echo window と flag | store-api.md › Live tabs、review › 推奨 1 | 採る |
| Chrome が自分で行った変更（拡張の `chrome.tabs.move`、close 後の後継選択）は store が差分を取って同じ変更をワークスペースに反映する。後継タブは Chrome の選択ではなく store の規則（split の連続、collapsed・未 load のタブを飛ばす）で決める | 製品の規則は Chrome に無い | Chrome の後継選択に従う | store-api.md › Live tabs、review › § H | 採る |
| Chrome が既に持つデータ（履歴、閉じたタブ、favicon、zoom、ブックマーク、ダウンロード）を自前の JSON に二重に持たない。UI は自前のまま Chrome のデータの上に載せる | 二重・三重の保存がずれ、拡張が見る履歴・ブックマークと UI が食い違った。1.8 MB の JSON を変更のたびに書き直していた | 自前の JSON を維持 | review › 推奨 2（2026-10-01 時点で履歴・閉じたタブ・favicon・ブックマークは移行済み） | 採る |
| 残す自前: omnibox の順位付けと UI、同期（Chrome Sync は Google が要る）、他ブラウザからの import（ただし書き込み先は Chrome の store） | Chrome の importer は Arc・Dia を読めない | — | review › 推奨 2、§ E | 採る |
| パスワード・autofill・拡張管理・zoom・検索エンジンは、隠した chrome:// の WebUI を DevTools で script する方式をやめ、自前層から Chrome の service を直接呼ぶ | WebUI の private API は Chromium の版ごとに変わり、版上げのたびに設定が黙って壊れる危険がある。隠しページの timeout | WebUI の scripting | review › 推奨 4、agent-brief.md › Stack | 採る |
| 互換の分岐を持たない。app とエンジンは同梱なので、`respondsToSelector`・optional な native 呼び出し・旧名の alias を禁止。残すのは版付きのディスク上のデータ移行、版付きの同期 payload、app/engine の API version の一致検査だけ | JS/native の skew は、共有の Metro が古い native build に新しい JS を配ったことだけが原因だった | 互換行列を維持（review 時点で 24 の `#if` と 14 の feature macro） | review › 推奨 3、conventions.md › Backwards compatibility | 採る |
| 環境変数は 1 箇所（`ArdiaLaunchConfig`）で読み、エンジンには command-line switch で渡す。エンジンは環境変数を読まない（例外 3 行） | テスト用の偽装が本番に効かないようにする。`ARDIA_TEST` は配布署名でない build・scratch data dir・mock keychain の 3 条件を満たすときだけ効く | — | conventions.md › Environment variables、engine-build.md › ArdiaCore's layer | 採る |

### 1.5 同期（アカウント無しの方式）

| 判断 | 理由 | 退けた代替案 | 根拠 | 新ブラウザへの適用 |
|---|---|---|---|---|
| サーバもアカウントも Apple の entitlement も持たない。ユーザーが選んだフォルダ（既定は iCloud Drive の下）に封をしたファイルを読み書きし、フォルダの同期サービス（iCloud Drive、Dropbox、NAS、USB）に運ばせる | Chrome Sync は Google が要る。CloudKit container も entitlement も要らない | Dia 型のサーバ＋6 文字のペアリングコード | sync.md 冒頭、release-notes 0.2.4 | 採る（候補の第一）。ただし iPhone・Windows で同じフォルダに届く経路は要検討 |
| 鍵は 24 語の BIP-39 recovery phrase（256 bit）から HKDF で導く。file-key（AES-256-GCM）と name-key（HMAC-SHA256）。phrase の entropy は各 Mac の login Keychain に this-device-only で保存し、iCloud Keychain に入れない。phrase を表示・コピーする native 呼び出しの前に Touch ID かパスワードを要求する（成功は 60 s 有効） | phrase が鍵そのもの。256 bit なので password stretching は不要。リセット手段は無い（メールで送る相手がいない） | — | sync.md › Recovery phrase and keys | 採る |
| フォルダ名・ファイル名は鍵付き HMAC かランダム。内容は 1 KiB 単位に padding し、圧縮しない。AAD でファイルを「フォルダ／名前」に束ねる | 名前から profile・サイト・種類が漏れない。攻撃者が選んだページ題名でパスワードを圧縮率から探る CRIME 型を防ぐ。rename・移動・切り詰めを検出する | 圧縮する | sync.md › Threat model、› Folder layout | 採る |
| 各端末はファイルを新規作成するだけで、既存ファイルを変更しない。同じ volume の一時フォルダに書いてから `NSFileCoordinator` の下で移動する | 2 台が同じファイルを書かないので、同期サービスに競合が起きない。半端なファイルが本名で見えない | 共有ファイルの更新 | sync.md › Folder layout › Writing | 採る |
| ファイルは log（端末ごとの seq 付き変更の束）と snapshot（replica 全体＋版ベクトル）。merge はレコード単位の last-writer-wins を hybrid logical clock で決める join（可換・結合的・冪等）。削除は tombstone | ファイルの到着順に依らず収束する。時計が遅れた Mac でも、他の端末の編集を見た後の編集は新しくなる | CRDT の木構造など（言及なし） | sync.md › Merge | 採る |
| 3-way: scope ごとに base（直前の publish か apply の後の状態）を持ち、未 publish の編集がある key には remote を適用しない | 読み込み中に行った編集が上書きされない | — | sync.md › Merge | 採る |
| 送信前に journal（封をしたファイル）へ書いてからフォルダに書く。seq は再利用しない。quit は保存の queue を最大 3 s 待つ | クラッシュ後に同じ batch を同じバイト列で書き直す。二重に届いても no-op | — | sync.md › Folder layout › Writing | 採る |
| compaction: 40 ファイル超かつ 10 分間 snapshot 無しで snapshot を書き、1 時間後に覆われたファイルを消す。tombstone は 45 日、版ベクトルに穴があるときは 90 日保持、履歴は 90 日 | snapshot は自己完結しているので並行 compaction が安全 | causal stability（全端末が適用した後に tombstone を消す）。試して revert した（`7b334d07`） | sync.md › Compaction | 採る（数値は既知の残存とセットで）。§ 3 参照 |
| パスワードは Chrome のパスワード store から engine 経由で読み、JS には同期鍵で封をした値だけを渡す。nonce は login とパスワードの HMAC（同じパスワードは全 Mac で同じ封になり、開かずに比較できる）。1 件でも復号できない行があれば読み込み全体を skip する | 平文を JS に出さない。部分的な一覧は削除と読み違えられる | Chrome の `passwordsPrivate`（毎回 device 認証が要る） | sync.md › Passwords | 採る |
| 拡張の同期は Chrome Sync と同じ対象（Web Store からユーザーが入れたもの）。インストールは版を指定せず入れ、権限警告があれば無効のまま入れ、他の Mac で承認された版と権限に一致したときだけ有効にする。削除は tombstone ではなく `{removed: true}` という生きた値 | Chrome の updater は取ってきた版の権限をそのまま与える。tombstone は compaction と古い Mac に消される | — | sync.md › Extensions | 採る |
| 新しい record 種別は旧版が読まない prefix で足し、旧版が勝手に消したり書き戻したりしない形にする（`pth:`、`share:`、`pgc:`、`pord:`、`pgh:`） | nightly の Mac が 1 版古い stable の Mac と同期する。同期 payload だけは版付きの互換を持つ | 既存 record にフィールドを足す（旧版が書き戻して落とす） | sync.md › What syncs の表、conventions.md › Backwards compatibility | 採る |

### 1.6 メモリ・性能

| 判断 | 理由 | 退けた代替案 | 根拠 | 新ブラウザへの適用 |
|---|---|---|---|---|
| タブの sleep は最終的に Chrome の Memory Saver に任せる（既定で有効、Moderate／Balanced／Maximum、常に active にするサイト） | 自前の sleep と Memory Saver が衝突する（Helium の Memory Saver 既定化 patch を skip していた理由）。自前の sleep を捨てるので patch を再適用した | 自前の tabLifecycle を維持（review 推奨 2 は「policy は自前、Chrome の discard を入力にする」としていた） | commit `1af72e64`、release-notes 0.2.43-nightly.4 | 採る。経緯は § 2 |
| 背景タブの凍結（`InfiniteTabsFreezing`）に Ardia 独自の parameter を足す: WebSocket・WebTransport・WebRTC を一度も開いていない凍結タブは 10 分ごとに解凍、開いたタブは凍結しない | Chrome の凍結は WebSocket を落とす。Chrome は 1 分ごとに 5 秒解凍し、YouTube が 3.35 mW を使っていた | Chrome の既定 | engine-build.md › `chromium-thaw-live-connections.patch`、perf/vs-browsers.md › Power | 採る |
| `ThrottleMainFrameTo60Hz` を有効にし（main frame 60 Hz、compositor 120 Hz）、表示直後 1 秒・scroll 中・入力後 1 秒は全速に戻す patch を足す | YouTube の視聴ページで renderer の電力が 79 → 54 mW。ただし 60 Hz の main frame で scroll がずれた（38–47% の frame で 1 draw 遅れ） | throttle 無し | perf/vs-browsers.md › Power、› Scrolling at full rate | 採る |
| Battery Saver の 30 Hz 上限を入力の間だけ外す | Battery Saver は scroll と入力まで 30 Hz に落とす | — | engine-build.md › `chromium-battery-saver-full-rate-on-input.patch` | 採る |
| idle の wakeup を hook で削る: CPU health の 15 s sampling を止める、空きディスク確認を 60 s に、Bluetooth の 500 ms poll を discovery 中だけに、caBLE の BLE scan を QR 表示中だけに | Google の sign-in ページを開いたままにすると Bluetooth の poll が 1 core の約 2% を使い続けた | — | engine-build.md › Our hooks in Chrome's code | 採る |
| 計測値（2026-10-16、Ardia 0.2.37 対 Chrome 155）: 1 タブのメモリ 290 MB 対 370 MB、20 タブで 1,183 MB 対 919 MB（renderer 1 タブあたり 41 MB 対 24 MB）、tab switch が表示されるまで 40 ms 対 8 ms | 20 タブのメモリ差は renderer。content blocker の content script と全 frame に注入する page script が容疑。tab switch の差は JS と React の往復（約 25 ms）と、表示時に止まっている display link | — | perf/vs-browsers.md › Results | 要検討（数値は参考値） |
| tab switch は JS の往復を待たず native で先に表示し（10–16 ms に）、sidebar の mouse-down で page に no-op の rAF を走らせて display link を先に起こす（クリックから表示まで 13 → 5 ms、クリック 1 回あたり main thread 約 60 µs） | display link の keep-alive 延長は最大 120 wakeup/s を払う。window 単位の compositor 共有は描画の書き換え | keep-alive 延長、compositor 共有 | perf/vs-browsers.md › Tab switch（Update） | 要検討。Swift UI でも「タブの表示を UI 層の往復で待たせない」は採る |
| Hermes の heap と PartitionAlloc の断片化を、タブ数が落ち着いて入力が無いときに `gc()` と `ReclaimAll` で回収する | 20 タブから 1 タブに戻したときの browser process の保持が 121 → 105 MB | tab 単位の partition（engine の大工事になるので保留） | perf/vs-browsers.md › Memory（Update） | 採らない（RN 固有の部分が大きい）。PartitionAlloc の回収は要検討 |
| 起動: quit 時に撮った window の絵と live のページで、React Native の起動前に native の early window を出す。更新後の初回起動の Gatekeeper scan（3–13 s）を、Install and Relaunch の待ち時間に hidden で 1 回 exec して済ませる | warm 起動で RN の起動（bridge と Hermes）が 135 ms。初回起動の遅さは `main` より前の Gatekeeper の scan（framework の symbol table 175 MB も効く） | — | perf/launch-critical-path.md › Headline、› Early window、release-notes 0.2.42 | 採る（更新後の prewarm と symbol の strip）。early window は UI が native なら不要に近い |
| prerender・preconnect は作って外した | Chrome の「Preload pages」が既定で無効（ungoogled の設定）。有効にしても、自前の mojo binding（page channel）が prerender を許されずに全部キャンセルされる | — | perf/ideas.md | 要検討。自前の renderer 側 binding を設計するとき、prerender 中のページで遅延 bind できるようにする |

### 1.7 拡張

| 判断 | 理由 | 退けた代替案 | 根拠 | 新ブラウザへの適用 |
|---|---|---|---|---|
| 本物の `Browser` と `TabStripModel` を持ち、`chrome.tabs`・`chrome.windows`・action popup・side panel を Chrome の実装のまま使う | Alloy 時代に、拡張の API・パスワード・autofill・権限・passkey・Cast・side panel を失った | Alloy（`Browser` 無し） | review › § B、research `chromium-ui-layer.md` › Why (a) wins | 採る |
| toolbar が無いので、Chrome が toolbar を前提にする UI（action popup、install prompt、installed bubble、side panel、パスワードの bubble）は hook で自前の実装に差し替える。action popup は Chrome の `ExtensionViewHost` を自前 window に付けた `NSPanel` に置く | Dia も `arc/browser/ui/*.cc` で 45 の seam を自前実装している | Chrome の Views bubble をそのまま使う（toolbar に anchor できない） | ardiacore-spike.md › What was built、engine-build.md › patch 表 | 採る |
| 自前の内部 window は拡張から見えなくする（一覧に出さない、id で引けない、events を出さない） | 隠した helper window が拡張に漏れていた | — | engine-build.md › `chromium-extension-window-hidden.patch` | 採る |
| uBlock Origin Lite（MV3）から uBlock Origin（MV2）に替え、component extension として署名済み bundle から直接読む。component extension がどのページでも script を実行できる Chrome の既定を、自前の bundle 分だけ制限する | uBOL の DNR ruleset の index が bundle に書き込まれていた。uBO は書かない。data dir の写しは同じユーザーの他プロセスが書き換えられた | uBOL を data dir に写して使う | engine-build.md › Nothing writes into the app bundle、› `chromium-component-extension-restricted-urls.patch`、release-notes 0.2.38 | 要検討。MV2 は Chromium の上流で削除が進む前提で、保守の見通しを立てる |
| Web Store のインストールと更新は Google に直結し、Google の拡張 kill switch（Omaha の malware 属性）を復活させる | Helium の proxy は onboarding の同意が要り、同意を求めない Ardia では dummy host に飛んでいた。Safe Browsing を外すと malware の blocklist も消える | Helium の proxy | engine-build.md › `chromium-webstore-direct.patch`、› `chromium-extension-omaha-attributes.patch` | 採る |
| ユーザースクリプト用の unpacked 拡張は content script だけを許す ManagementPolicy を全 profile に入れ、symlink の差し替えも拒否する | ディスク上の manifest を書き換えて特権拡張を side-load されるのを防ぐ | — | engine-build.md › `chromium-extension-management-policy-hook.patch` | 採る（機能を持つなら） |

### 1.8 配布・署名・更新

| 判断 | 理由 | 退けた代替案 | 根拠 | 新ブラウザへの適用 |
|---|---|---|---|---|
| Safe Storage の keychain item 名（「Ardia Safe Storage」）は load-bearing とし、版上げでも基盤の差し替えでも変えない | 全ユーザーの保存パスワードと cookie がその鍵で暗号化される | Helium の keychain 名変更 patch を適用 | engine-build.md › `chromium-safe-storage-name.patch`、› Helium › Skipped | 採る（最初に名前を決めて固定する） |
| Safe Storage の鍵を黙って作り直さない。新規 profile と判定できるときだけ作成を許し、それ以外は 3 回 × 1 s 再試行して fail closed、原因別の dialog を出す。追加は add-only | login 直後に item が一瞬見えないと Chromium が新しい鍵を作り、全パスワードと cookie が復号できなくなった（0.2.40 で修正） | Chromium の既定 | engine-build.md › `chromium-safe-storage-no-silent-reset.patch`、release-notes 0.2.40 | 採る |
| 復号したパスワードの平文を解放前にゼロ埋めする（`PasswordString` と `os_crypt` の一時領域） | Chromium は clear するだけで、解放済みメモリに平文が残っていた | — | engine-build.md › `chromium-password-string-erase.patch`、› `chromium-os-crypt-decrypt-erase.patch` | 採る |
| app bundle に一切書き込まない。release の前に export した app を 1 回起動して署名を再検証する | 1 ファイル足すだけで `codesign --verify --deep --strict` が落ちる。読み取り専用 volume や translocation で書けない | — | engine-build.md › Nothing writes into the app bundle | 採る |
| 更新は Sparkle 2（stable と nightly の 2 channel、build 番号で比較、EdDSA 署名）。feed URL・EdDSA 鍵・Developer ID・designated requirement を固定する | エンジン切替（0.2.22）でも名前変更（0.2.33）でも Sparkle がその場で更新でき、macOS が権限・keychain・passkey を保つ | — | releasing.md › Channels、› The engine switch、› The rename | 採る（macOS）。Windows/Linux の更新経路は要検討 |
| エンジン切替時はデータを移行しない。同じ Chromium 版にして同じ data dir と keychain item を読ませ、往復（旧 → 新 → 旧）まで `carryover.sh` で検証する | 移行の失敗点を作らない | 移行スクリプト | releasing.md › The engine switch、ardiacore-parity.md › Before switching | 採る（エンジンの大きな変更は Chromium の版上げと別の release にする） |
| CI の sign phase は build phase と隔離する: 依存のインストールも cache の復元もせず、build の成果物を untrusted として展開・検査し、鍵を消してから起動検査をする。actions は commit SHA で固定 | 依存のコードが署名鍵の隣で動かない | 1 job で build と署名 | releasing.md › CI releases | 採る |
| publish は GitHub 上の branch を lock にし、build 番号が feed の全項目より大きいことを確かめる | 2 つの publish が同じ snapshot に載らない。古い build が latest を後退させない | — | releasing.md › CI releases | 採る |
| framework と helper の名前は「Chromium」のまま | 名前は branding file（GN arg）由来で、変えると full rebuild。bundle id と team は自前なので、見えるのは Activity Monitor だけ | — | releasing.md › The engine switch | 採る（最初の build で名前を決めておけば済む） |
| test instance の profile gate: 配布署名の build が実 data dir で起動したら、profile を外部制御に開く switch（CDP など）を起動時と chrome://flags 適用後の 2 回除去し、`SSLKEYLOGFILE` を消す | 実 profile の TLS 鍵や CDP を外部に開かない | — | testing.md › Test instances、conventions.md › Environment variables | 採る |

### 1.9 テスト・計測の基盤

| 判断 | 理由 | 退けた代替案 | 根拠 | 新ブラウザへの適用 |
|---|---|---|---|---|
| 単体テストを 412 件から 82 件に削った（2026-10-01。その後の追加で 2026-10-12 時点は 333 件）。残す基準は「壊れるとデータを失うか漏らす」か「目で見えず、過去に出荷した不具合」 | 定数や書式を固定するテストは目視で十分 | 全部残す | testing.md › What's kept、› What went | 採る |
| UI 層を Node で動かし、native の fake を native module の一覧から型付けする。native のメソッドが変わって fake が追従しないと typecheck が落ちる | native の継ぎ目には単体テストが無く、hidden instance の script だけで検証していた | — | testing.md 冒頭、review › § F | 採る（Rust 中核なら、中核を UI 抜きで動かすテストが同じ役割を担う） |
| E2E は hidden instance（`ARDIA_BACKGROUND=1`、scratch data dir、独自の CDP port）を dev harness と CDP で駆動する。context menu・file panel・dialog・full screen・occlusion を偽装できる | 画面に出せない（owner の作業を妨げない）まま、本番の経路を通す | — | testing.md › Test instances | 採る |
| 性能の release gate は「前の stable を control、RC を candidate」として同じ native-bench の process で run ごとに交互に走らせる | 0.2.22 の gate で 15 分ずらして走らせ、drift を退行と誤認した | 別々の job で計測 | perf/README.md › Gating a release | 採る |
| wall-clock ではなく count（React の commit・render・store 更新・native → JS の task・timer）に天井を置く ratchet で退行を止める。天井は下げるのは自動、上げるのは手で理由付き | 同じ build が忙しい Mac で ±20% 動き、誤報の多い gate は無視される。count は桁まで再現する | wall-clock の閾値 | perf/README.md › The ratchet | 採る |
| 速度の変更は kill switch の後ろで出す。上限 8 本、各 switch に owner と `removeBy`、既定で on、off で元の挙動。experiment は既定で off で、8 本に数えない | 一部の Mac で遅い・壊れる release を、再 build せずに戻す | 環境変数の toggle を増やす | kill-switches.md | 採る |
| cache・prefetch・prewarm には staleness のテストを付け、count は wall-clock を一度動かしたことを示してから gate に入れる | claude.ai の sprint の批評（cache したサイドバーが削除済みの会話を表示し、指標は「良好」だった） | — | perf/sprint.md › Lessons | 採る |
| 外部 review（Codex）を設計と spike の段階で入れた | review の推奨 1 の権限の向きを逆転させ、spike の合格条件を増やし、spike の strangler 計画を変えた | — | review › § H、ardiacore-spike.md › Codex second opinion | 採る |

### 1.10 UI フレームワーク（React Native）

| 判断 | 理由 | 退けた代替案 | 根拠 | 新ブラウザへの適用 |
|---|---|---|---|---|
| React Native for macOS（Expo SDK 54、react-native-macos 0.81、Legacy architecture）を維持し、hot path だけを native に移す | Chrome との衝突は RN から来ていない。Fast Refresh、dev-eval harness、Node で動く store のテスト（約 7k 行）が agent の作業を速くしている。書き換えは TSX 約 21k 行と store・logic 約 17k 行の移植で、304 の parity 項目を取り直す必要がある | SwiftUI/AppKit への書き換え（推奨 5 の後に再検討、するなら段階的に） | review › 推奨 6、§ D | 採らない（新ブラウザは Swift/AppKit）。ただし RN を残した理由の中身は要件として採る: UI と切り離してテストでき、短い反復で回せる中核層が要る |
| RN の代償: pod 約 85、Hermes bundle 3.6 MB、react-native-macos の回避策約 12 件（shadow で crash、`RCTView` が layer を戻す、`setFrameSize` の override 15 件など）、browser の event ごとの JS の往復、JS thread で走る animation 96 本 | — | — | review › 推奨 6、§ D、agent-brief.md › Stack（react-native-macos の patch 群） | 採らない（避ける根拠） |
| 計測された代償: warm 起動で RN の起動 135 ms。tab switch・new tab の表示が React の commit を待っていた（25 ms 前後）。browser process の idle wakeup が Chrome の 2.1/s に対し 3.3/s（RN の timer と display link）。大きな session で最初の React commit を native view に変換するのに約 480 ms | — | — | perf/launch-critical-path.md › Headline、perf/vs-browsers.md | 採らない（避ける根拠） |
| profile のページングは JS から native Animated、AppKit の controller へと移した。React は描画だけを担当する | owner が遅延と取りこぼしを報告し続けた。JS が止まっても動きが止まらない | JS の pager | research/profile-swipe-native-controller.md、research/dia-profile-swipe-binary.md | 採る（gesture と motion は最初から native） |
| macOS で New Architecture（Fabric）へ移らない | macOS の Fabric は部分的で、回避策 12 件の再検証が要る | 移行 | review › 推奨 6 (5) | — |
| ⌘T・⌘L・⌘F の直後の ⌘V を新しい欄に届ける `FocusHandoff`: command がページの responder を同期に resign し、window ごとに 400 ms の gate を開き、command が focus した欄が first responder と確認できたときだけ待たせた編集操作を実行する。それ以外は beep して捨てる | command が JS thread で走るため、30–150 ms の間 AppKit の焦点が旧 responder に残り、⌘V が旧ページ（非表示のタブを含む）に落ちた。⌘1–9 やタブ切替などは安全に直せず parked | — | known-issues/paste-focus-handoff.md、release-notes 0.2.40 | 採らない（回避策として）。採る（教訓として）: command の dispatch を焦点と同じスレッドで同期に行う |
| god file を継ぎ目で割る（review 推奨 8）。帰結として、native は 1 クラス 1 ファイル（category は `Class+Concern`）、Expo module は domain ごとに 1 つ、native を呼ぶのは `platform/` だけで component は `state/` の action 経由、規則ごとに権限を 1 箇所（private profile の可否はエンジンの flag だけ） | `ACClient.mm` が 11 の CEF handler を 1 クラスに持ち（1 週間に 31 commit）、`CefModule.swift` が 94 関数、shortcut の表が 2 言語に、URL mapping が 3 箇所にあった。CEF の routing と製品の規則が混ざっていた | — | review › 推奨 8、§ F、agent-brief.md › ArdiaCore code map、conventions.md › Folders、› Translation layer | 採る（Swift UI と Rust 中核の層の境界として） |
| issue #92（native UI の部分的な導入）は OPEN のまま | — | — | issue #92 | 参考。ArdiaCore の ObjC API があれば native UI の実験は可能と issue が指摘している |

### 1.11 第二の page engine（WebKit）

| 判断 | 理由 | 退けた代替案 | 根拠 | 新ブラウザへの適用 |
|---|---|---|---|---|
| DRM のサイト（Netflix など）は WebKit で開く。Chromium と WebKit の page engine を 1 つの `PageEngine` protocol（同じメソッド名、1 つの event 表）にそろえ、id の接頭辞（`wk-…`）で native が振り分ける。cookie は engine ごと、ワークスペース・履歴・設定は共有 | Widevine には Google の VMP 署名が要る（engine-build.md の GN args の記述）。issue #234 は「Helium は Widevine 無しで出荷される」と書いており、GN args の記述（Widevine は有効、署名が要る）とずれる。WebKit には FairPlay がある | DRM を諦める | release-notes 0.2.41、issue #234、conventions.md › Translation layer、engine-build.md › Rebuilding › GN args | 要検討。iPhone で WebKit が必須になるなら、page engine の抽象を最初から持つ価値がある。一方で拡張と content blocker は Chromium 側だけに残る |

---

## 2. 失敗と作り直しの記録

| 対象 | 作り直しの回数（設計の数） | 変遷 | なぜ |
|---|---|---|---|
| window 層 | 3 回（設計 4。review は ArdiaCore 以前の 2 回を「約 2 週間で 2 回」と記録） | Alloy（`Browser` 無し）→ ghost window（不可視の Chrome window を RN window の背後に置く、0.1.x）→ Chrome-hosted window（Chrome の window を app window にし、profile ごとに Chrome window、0.2.0）→ ArdiaCore の 1 window・複数 `Browser`（0.2.22） | Alloy は拡張・パスワード・権限を失った。ghost は Chrome が自分で描く UI（dialog、bubble、menu、焦点、shortcut）がすべて ghost に属し、継ぎ目の不具合を 1 件ずつ直した（dialog のための lift、context menu の fallback patch、Chrome の shortcut の keycode 表）。hosted は CEF が「browser window とは何か」を決める制約のままで、profile ごとの window と full screen の補助 window が残った。review は 2 回の作り直しが「同じもの（CEF の window モデル）と戦った」と総括した（review › § A） |
| タブの mirroring | 1 回（設計 2） | store から Chrome に push し、Chrome の報告を echo として 1 秒の時間窓と flag で濾過 → command ＋ revision 付き transaction | activation の ping-pong（20 タブで 230 回の window 更新）、拡張の move と group の取りこぼし。1 週間に 41 commit、修正 12 |
| profile のページング | 3 回（設計 4） | JS pager → native Animated で settle（0.2.17）→ AppKit の gesture controller（0.2.18）→ 1 window 内の view swap（ArdiaCore） | JS 経由の drag で遅延と反転の取りこぼし。CEF 時代はページングだけで約 4,600 行（コード約 2,900 行＋テスト script 1,914 行）と research 文書 4 本 |
| タブの sleep・凍結 | 4 回（設計 5、10-19〜10-28 の約 10 日） | 自前の tabLifecycle（Chrome のメモリ圧迫時の discard と 2 つの policy が並走）→ 0.2.38 背景タブを Chrome の freezing で凍結（直近 5 タブ以外）→ 0.2.42 自前の sleep を強化（直近 4 タブ、20 分）→ 0.2.43-nightly.1 4 時間に延長（Memory Saver に合わせる）→ 0.2.43-nightly.4 Memory Saver に置換 | 自前の policy と Chrome の機構が衝突した（commit `1af72e64`）。review 推奨 2 は「policy は自前で残す」としていたが覆した。置換の判断理由の詳細は commit に無い |
| 基盤の patch 集 | 2 回（設計 3） | CEF ＋ ungoogled-chromium → Chromium ＋ ungoogled（CEF 削除、0.2.31）→ Chromium ＋ Helium（0.2.40） | CEF は § 1.1。Helium への移行理由は明文が無い（§ 4） |
| content blocker | 2 回（設計 3） | uBOL を bundle から読む（0.1.0、初回起動で bundle に index を書き、読み取り専用 bundle では何も block しなかった）→ uBOL を data dir の写しから読む → uBO（MV2）を bundle から直接読む（0.2.38） | bundle への書き込みが署名を壊す。data dir の写しは同じユーザーの他プロセスが編集できた |
| 互換行列 | 1 回（削除） | stock CEF の build と patch 済み CEF の build を `#if` で両対応、JS が古い native を許容 → 削除し、API version の一致検査だけを残す | 共有の Metro が古い native に新しい JS を配ったことだけが skew の原因だった |
| 二重保存のデータ | 1 回 | 履歴・閉じたタブ・favicon・zoom・ブックマークを自前の JSON に保存 → Chrome の service へ | 拡張が見るデータと UI がずれた。1.8 MB の書き直し |
| 隠し WebUI の scripting | 1 回で削除 | `chrome://password-manager` などを DevTools の `Runtime.evaluate` で操作（約 1,000 行）→ 自前層から service を直接呼ぶ | private API が版ごとに変わる。timeout |
| 単体テスト | 1 回 | 412 件 → 82 件 | 定数を固定するだけのテストを削った |
| 同期の tombstone 回収 | 試して revert | causal stability の実装を試み、`7b334d07` で revert | 下記 § 3 の 4 要件を満たせなかった |
| prerender | 作って外した | `5c9d0422` で作成 → 削除 | 既定の設定と自前の mojo binding で効果がゼロ |

---

## 3. 新ブラウザが最初から避けるべきこと

- **CEF を経由しない。** CEF は window・タブ生成・run loop の 3 つで構造的に衝突し、patch の行の 77% が CEF の API に Chrome のオブジェクトを通すためだけに費やされた（review › 推奨 5、§ C）。spike は約 3,200 行の自前層で 2 profile・1 window・popup・autofill・DevTools・MV3 拡張を動かした（ardiacore-spike.md › Verdict）。
- **CEF と自前 framework の段階的な同居を計画しない。** 1 プロセスに Chromium を 2 つ入れられない（ardiacore-spike.md › Codex second opinion）。
- **タブの状態に 2 人の書き手を置かない。** ワークスペースは中核、生きたタブは Chrome、command ＋ revision 付き transaction で結ぶ。echo の時間窓や「自分が起こしたか」の flag を作らない（review › 推奨 1、store-api.md › Live tabs）。
- **Chrome に「変更してよいか」を非同期で問い合わせる設計にしない。** 拡張の関数の同期的な完了の意味が壊れる（review › § H）。
- **Chrome が既に持つデータを中核に二重に持たない。** 履歴・ブックマーク・favicon・閉じたタブ・zoom・ダウンロードは Chrome の service の上に UI を載せる（review › 推奨 2）。Rust の中核に置くのは Chrome が持たないもの（ワークスペース、同期、import）に限る。
- **chrome:// の WebUI を script して設定を操作しない。** 版上げのたびに黙って壊れる（review › 推奨 4）。
- **Chrome のファイルを大きく書き換える patch を作らない。** 新規ファイル＋共有ヘッダで宣言した関数ポインタの hook にし、`series` と byte 比較の check を初日から置く（engine-build.md › Our hooks、› The patch series）。
- **Chrome のタブ sleep・凍結の機構と並走する自前の policy を作らない。** Ardia は 10 日で 4 回作り直し、最後は Memory Saver に戻した（§ 2、commit `1af72e64`）。必要な調整は Chrome の機構の parameter として足す（`chromium-thaw-live-connections.patch` の形）。
- **UI の framework の往復をタブの表示経路に入れない。** tab switch と new tab の表示が React の commit を待ち、Chrome の 8 ms に対して 40 ms だった（perf/vs-browsers.md）。gesture と motion も最初から native にする（research/profile-swipe-native-controller.md）。
- **タブ view ごとに compositor を作り直す代償を設計時に評価する。** 表示のたびに display link の起動に 1–2 refresh かかる（perf/vs-browsers.md › Tab switch）。window 単位の共有に後から移るのは描画の書き換えになる。
- **app bundle に書き込む経路を作らない。** 拡張の DNR index、code sign clone などを data dir に向け、release 前に起動後の署名を再検証する（engine-build.md › Nothing writes into the app bundle）。
- **Safe Storage の keychain item 名を後から変えない、鍵を黙って作り直さない。** 全ユーザーのパスワードと cookie が読めなくなる（engine-build.md › `chromium-safe-storage-*`、release-notes 0.2.40）。
- **ライセンスを基盤の patch 集に決めさせない。** Helium の patch を取り込んだ時点で配布物全体が GPL-3.0 になった（engine-build.md › Licence and source）。基盤（ungoogled は BSD-3-Clause、Helium は GPL-3.0）の選択はライセンス方針として先に決める。
- **Safe Browsing を compile out したまま代替を決めずに出さない。** フィッシング・マルウェアの URL 検査とダウンロード評価が無い状態が未解決の最大の欠落とされている（issue #249）。
- **DRM の扱いを後回しにしない。** Widevine は Google の VMP 署名が要り、Ardia は WebKit の第二エンジンで迂回した（release-notes 0.2.41、engine-build.md › GN args）。
- **同期で tombstone の回収を wall clock に頼らない。** causal stability の試み（`7b334d07` で revert）が示した要件を最初から設計に入れる: (1) ファイルがまだ届いていない書き手も数える、(2) 端末の rebase で adapter が頼る base を消さない、(3) 端末の incarnation と journal を一緒に保存する、(4) バックアップから戻した端末が incarnation と seq を再利用しない（sync.md › Compaction）。現行方式の既知の残存は、45 日（穴があれば 90 日）を過ぎて届いた log が削除済みレコードを戻すことである。
- **同期の record 形式を、旧版が書き戻して壊す形で拡張しない。** 新しい情報は旧版が読まない key で足す（sync.md › What syncs）。
- **互換の分岐で mismatched な中核を許容しない。** app と中核を同梱し、API version の一致検査 1 つにする（conventions.md › Backwards compatibility）。
- **wall-clock だけで性能の退行を gate しない。** ±20% の揺れで誤報が出る。count の ratchet と control/candidate の交互実行にする（perf/README.md）。
- **cache・prewarm を staleness のテスト無しで入れない**（perf/sprint.md › Lessons）。
- **engine の build を並列化できない構成のまま agent を増やさない。** 単一の chromium lock がすべての engine 作業を直列化した（review › § F）。

---

## 付録: engine/patches/series の patch 名（2026-10-30、`chromium` 64 本＋`layer` 2 本）

並びは series の適用順ではなく、engine-build.md の patch 表の説明から筆者が分類したものである。適用順は series ファイルのとおり、先頭が `chromium-helium-branding`、末尾が `chromium-ardia-layer` → `layer engine/chromium` → `layer engine/ardiacore`。

- **branding・自前層の link・CEF の名残（6）**: `chromium-helium-branding`、`chromium-branding`、`chromium-devtools-window-title`、`chromium-neterror-game`、`chromium-ardia-layer`、`chromium-cef-carryover`
- **hook・toolbar の無い window への適応（20）**: `chromium-autofill-address-bubble-window`、`chromium-device-chooser-hook`、`chromium-cast-dialog-hook`、`chromium-side-panel-hook`、`chromium-ntp-promo-without-side-panel`、`chromium-initial-document-access`、`chromium-hidden-window-current-window`、`chromium-devtools-redock-display`、`chromium-extension-install-prompt-hook`、`chromium-extension-management-policy-hook`、`chromium-extension-sync-installer-hook`、`chromium-unpacked-load-path-hook`、`chromium-extension-window-hidden`、`chromium-password-bubble-hook`、`chromium-window-docked-devtools`、`chromium-window-hosted`、`chromium-extension-installed-bubble`、`chromium-pip-overlay-window`、`chromium-temporary-tab-restore-hook`、`chromium-hosted-browsers-no-session-service`
- **Helium・ungoogled の打ち消しと補い（18）**: `chromium-webstore-direct`、`chromium-extension-updates`、`chromium-component-updater-security-only`、`chromium-extension-omaha-attributes`、`chromium-component-extension-disk-messages`、`chromium-helium-ublock-off`、`chromium-helium-onboarding-off`、`chromium-helium-services-page-off`、`chromium-helium-search-assets-off`、`chromium-helium-bangs-off`、`chromium-helium-rlz-for-cdm-storage-id`、`chromium-helium-ntp-third-party`、`chromium-helium-context-menu-cast`、`chromium-helium-devtools-inspect-shortcut`、`chromium-angle-metal-shader-cache`、`chromium-ungoogled-disable-default-extensions`、`chromium-ungoogled-disable-missing-key-warning`、`chromium-ungoogled-mime-util-ymp`
- **セキュリティ・データ保全（8）**: `chromium-safe-storage-name`、`chromium-safe-storage-no-silent-reset`、`chromium-password-string-erase`、`chromium-os-crypt-decrypt-erase`、`chromium-devtools-control-token`、`chromium-component-extension-restricted-urls`、`chromium-background-instance-no-default-handlers`、`chromium-apple-passwords-host-skipped`
- **性能・電力（6）**: `chromium-video-super-resolution`、`chromium-begin-frame-warm-up`、`chromium-main-frame-throttle-after-show`、`chromium-main-frame-full-rate-on-input`、`chromium-thaw-live-connections`、`chromium-battery-saver-full-rate-on-input`
- **挙動の修正（4）**: `chromium-password-generation-local`、`chromium-devtools-find-detach-keeps-selection`、`chromium-tab-sharing-capturer`、`chromium-desktop-capture-window-audio`
- **説明を読んでいないもの（2）**: `chromium-auto-pip-global-switch`、`chromium-media-session-main-frame-handler`（engine-build.md の patch 表に載っておらず、分類していない）

## 4. 読めなかったファイルと推測で書いた箇所

読めなかった・読まなかったもの:
- `docs/migration-status.md`（`2713787d` 時点のみ存在）は見出しと「Known gaps」の 1 行目だけを読んだ。テストの台帳の本文は読んでいない。
- `docs/research/chrome-hosted-window.md`（`2713787d`）は冒頭・Shipped as default・Summary までを読み、§ 1–7（設計、patch、段階計画、spike）は読んでいない。`docs/research/chromium-ui-layer.md` は「The patch」以降を読んでいない。
- `docs/ardiacore-parity.md` は「Before switching」の途中までを読み、API 表（WebView、`ArdiaCEF` module、拡張、Chrome UI、Swipe、window hosting、Engine C exports）は読んでいない。
- `docs/store-api.md` は「Live tabs」節だけを読んだ。
- `docs/sync.md` の「UX」節の後半と「Left for a person」は読んでいない。
- `docs/perf/` は README（gate と ratchet）、vs-browsers.md、launch-critical-path.md の Headline と Early window の冒頭、sprint.md の Lessons、ideas.md を読んだ。版ごとの gate（0.2.19-to-0.2.20 〜 0.2.41-to-0.2.42）、render-census.md、sprint-baseline.md、field-journeys.md は見出しだけである。
- `docs/release-notes/` は 0.1.0、0.2.0、0.2.4、0.2.22、0.2.31、0.2.38、0.2.40、0.2.41、0.2.42、0.2.43-nightly.1、0.2.43-nightly.4 を読み、他は grep で語を拾っただけである。
- `docs/dia-feature-parity.md`、`docs/dia-spec.md`、`docs/cli.md`、`docs/growth.md`、`docs/omnibox-ux.md`、`docs/onboarding-redesign.md`、`docs/dashboard-triage.md` は依頼の対象外として読んでいない。
- `docs/research/` の現行 2 ファイルは profile-swipe-native-controller.md を全文、dia-profile-swipe-binary.md を見出しだけ読んだ。

推測で書いた箇所:
- **Helium への移行理由**（§ 1.2、§ 2）。commit `d730de33`、`engine-build.md`、release-notes 0.2.40 は何をしたかを書くが、なぜ移ったかを書いていない。挙げた利点（Chromium への追従、既定値）は文書の記述からの推測である。
- **Memory Saver への置換理由**（§ 1.6、§ 2）。commit `1af72e64` は「自前の sleep と Memory Saver が衝突する」「自前の sleep は無くなる」とだけ書き、自前の sleep を捨てると決めた理由は書いていない。
- **WebKit を選んだ理由の食い違い**（§ 1.11）。issue #234 は「Helium は Widevine 無しで出荷される」、`engine-build.md` の GN args は「Widevine 有効、DRM は Google の VMP 署名が要る」と書く。どちらが直接の理由かは未確定である。
- **series の傾向**（§ 1.2）。64 本の内訳の分類（hook、Helium の打ち消し、性能、セキュリティ）は patch 表の説明を読んで付けたもので、行数は数えていない。
- **新ブラウザへの適用欄**は全行が筆者の判断であり、Ardia の文書の主張ではない。
