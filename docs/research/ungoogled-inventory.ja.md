# Ararat のための ungoogled-chromium の棚卸し（2026-11-05）

この文書は `ungoogled-inventory.md` の日本語訳である。内容が食い違うときは英語版に従う。

docs/architecture.md の §4.1（ベースのパッチセットの行）、§4.2（棚卸しと 1 回の実測した rebase）、§4.7・§4.9 への入力である。
第 1〜5 節の数値は、*見積もり* と記したものを除き、すべて下記の clone から**実測**した値である。見積もりは第 6 節にまとめる。

## 1. 出典

| Repo | Clone のパス | Commit | 日付 | 対象のバージョン |
|---|---|---|---|---|
| ungoogled-software/ungoogled-chromium（master、`--depth 1`） | `~/chromium-build/ungoogled/ungoogled-chromium` | `28a211ab4ab6b83d919966a4f58a6df23cf4fb29` | 2026-10-30 | `chromium_version.txt` = **156.0.8078.79**、`revision.txt` = 1（tag `156.0.8078.79-1`） |
| ungoogled-software/ungoogled-chromium-macos（master、`--depth 1`） | `~/chromium-build/ungoogled/ungoogled-chromium-macos` | `31f01756a43d55b2c4211e73ca329bfab4ebfcb2` | 2026-11-03 | submodule `ungoogled-chromium` は `28a211ab…`（上と同じ）に固定 → **156.0.8078.79**、`revision.txt` = 1 |
| ungoogled-chromium の PR #4032 "Update to Chromium 157.0.8103.38"（open、mergeable、2026-11-04 更新） | 1 つ目の clone にローカルの branch `pr-4032` として fetch | `de09e0c70c6bc1ac83d4ecdfd0e82c7e250c9a3c` | — | **157.0.8103.38** |
| Ararat の stock の checkout（読み取りのみ、変更していない） | `~/chromium-build/src` | `9a31f0acec1854d44e49a73fbf8017598151a583` | 2026-11-02 | **157.0.8103.39**（shallow、tag なし） |

上流で open のままの tracking issue: #4036 "Updating to Chromium 157.0.8103.39 on macOS"（2026-11-03 起票）、#4035（Linux、.38）、#4037（Windows、.39）。
macOS の repo には 157 の branch も PR もまだ無い。macOS 固有のパッチ `fix-gn-compatibility-chromium-156.patch` は名前にバージョンを含む。

## 2. パッチの series の件数

`patches/series`（コメントと空行を除く）と各パッチファイルから数えた。`+`/`-` の行数は `+++`/`---` のヘッダを含まない。hunk は `@@` の行の数、ファイル数は `+++` の対象の異なり数である。

### ungoogled-chromium（generic）、110 パッチ

| グループ | パッチ | +行 | −行 | Hunk | ファイル |
|---|---:|---:|---:|---:|---:|
| upstream-fixes | 2 | 9 | 1 | 8 | 8 |
| core/inox-patchset | 5 | 15 | 208 | 29 | 17 |
| core/iridium-browser | 2 | 8 | 109 | 6 | 6 |
| core/ungoogled-chromium | 28 | 369 | 8,105 | 945 | 481 |
| core/bromite | 1 | 4 | 23 | 5 | 2 |
| extra/ungoogled-chromium | 58 | 1,449 | 707 | 354 | 165 |
| extra/inox-patchset | 5 | 27 | 98 | 22 | 17 |
| extra/debian | 1 | 0 | 14 | 1 | 1 |
| extra/iridium-browser | 5 | 14 | 30 | 5 | 5 |
| extra/bromite | 3 | 330 | 5 | 50 | 26 |
| **core の合計** | **36** | 396 | 8,445 | 985 | — |
| **extra の合計** | **72** | 1,820 | 854 | 432 | — |
| **合計** | **110** | **2,225** | **9,300** | **1,425** | 異なり **690** |

上流自身の定義（`docs/design.md`）では、**core** はバックグラウンドのリクエスト、Google のサービスのコード、prebuilt のバイナリを扱い、"must be kept up-to-date with all of the changes in Chromium" とされる。**extra** は制御・透明性のための機能で、"not guaranteed to persist across updates" とされる。

hunk は core の 3 つのパッチに集中している（hunk / ファイル / +/−）。

| パッチ | Hunk | ファイル | + | − |
|---|---:|---:|---:|---:|
| core/ungoogled-chromium/remove-unused-preferences-fields | 459 | 231 | 94 | 3,412 |
| core/ungoogled-chromium/fix-building-without-safebrowsing | 216 | 127 | 56 | 1,892 |
| core/ungoogled-chromium/disable-ai | 116 | 60 | 10 | 664 |
| extra/ungoogled-chromium/remove-uneeded-ui | 47 | 31 | 31 | 270 |
| extra/ungoogled-chromium/add-suggestions-url-field | 38 | 13 | 102 | 29 |

この core の 3 つのパッチが、1,425 hunk のうち 791（56 %）を占める。

### ungoogled-chromium-macos、27 パッチ（すべて `ungoogled-chromium/macos/` の下）

| パッチ | +行 | −行 | Hunk | ファイル |
|---:|---:|---:|---:|---:|
| 27 | 530 | 1,096 | 235 | 133 |

大半はビルドのツールチェーンの修正（bindgen、rust、clang のチェック、dsymutil、typescript/esbuild、GN との互換）である。ほかに `fix-disabling-safebrowsing`、`fix-disable-verification-token`、`disable-crashpad-handler`、`set-bundle-identifier`、`add-local-network-usage-description` がある。

macOS のビルドで当てる series を合わせると **137 パッチ、1,660 hunk** である。

### リスト

| ファイル | 行数 |
|---|---:|
| `pruning.list`（tree から削除するファイル。大半は prebuilt のバイナリ） | 14,135 |
| `domain_substitution.list`（Google のドメインを書き換えるファイル） | 17,862 |
| `domain_regex.list`（置換の規則） | 21 |

### フラグ

- 追加する GN の引数: `flags.gn` は 18 行（例: `safe_browsing_mode=0`、`enable_reporting=false`、`enable_mdns=false`、`enable_service_discovery=false`、`enable_remoting=false`、`enable_hangout_services_extension=false`、`disable_fieldtrial_testing_config=true`、`google_api_key=""`、`use_official_google_api_keys=false`、`chrome_pgo_phase=0`、`enable_widevine=true`）である。macOS の `flags.macos.gn` は 18 行（引数 17 とコメント 1）で、official build、ThinLTO、`chrome_pgo_phase=2`、`proprietary_codecs=true`、`ffmpeg_branding="Chrome"`、`enable_updater=false`、`symbol_level=1` などを含む。`chrome_pgo_phase` は両方に設定されている。generic のファイルでは 0、macOS のファイルでは 2 で、macOS のビルドでは後者が優先される（§4.7 の PGO の行に関係する）。
- 実行時のフラグ: `docs/flags.md` には **52** 項目があり、3 つのグループに分かれる。コマンドラインのスイッチ（`chrome://flags` の項目つき）、`--enable-features` で渡す feature flag、既存の Chromium のスイッチに対する `chrome://flags` の項目である。各グループは、全プラットフォーム向けとデスクトップ専用の表に分かれる。

## 3. Ararat 自身のレイヤーとの重なり

各パッチの対象ファイルのパスで照合した（1 つのパッチが複数の行に出ることがある）。Ararat のレイヤーは、`chrome/browser/ui`（`BrowserView` を使わず、Ararat の `BrowserWindow` と seam の実装を置く）、タブストリップ、omnibox（`ARAutocomplete` によるコマンドバー）、プロファイル、拡張機能（ウィンドウの意味論、ポップアップ）、sync、Safe Browsing（Ararat の評判チェックで置き換える。§14）、component updater である。

| 領域 | Generic のパッチ | macOS のパッチ | 主なパッチ |
|---|---:|---:|---|
| `chrome/browser/ui/` | 36 | 2 | remove-unused-preferences-fields（42 ファイル）、fix-building-without-safebrowsing（15）、disable-ai（15）、remove-uneeded-ui（7）、および約 20 の `extra` の UI フラグ（hover card、タブの閉じるボタン、grab handle、タブのスクロール、アバターボタン、ウィンドウボタン、拡張機能メニュー、フルスクリーン終了の UI、閉じる前の確認、最後のタブでウィンドウを閉じる、新しいタブボタンでの paste-and-go、再読み込みメニュー、NTP のブックマークバー、QR ジェネレータ、シークレットのテーマ、クラッシュの bubble、初回起動のページ） |
| タブストリップ | 7 | 0 | add-flag-for-tab-hover-cards、add-flag-to-hide-tab-close-buttons、add-flag-for-grab-handle、add-flag-to-close-window-with-last-tab、enable-paste-and-go-new-tab-button、remove-uneeded-ui、disable-ai |
| Omnibox / 検索エンジン / autocomplete | 10 | 0 | add-suggestions-url-field（10 ファイル）、add-flag-for-omnibox-autocomplete-filtering、add-flag-for-search-engine-collection、prepopulated-search-engines、replace-google-search-engine-with-nosearch、disable-ai-search-shortcuts、block-trk-and-subdomains |
| プロファイル | 7 | 1 | remove-unused-preferences-fields（23）、disable-ai（5）、fix-building-without-safebrowsing（3）、0006-modify-default-prefs、disable-profile-avatar-downloading。macOS は fix-disable-verification-token |
| 拡張機能 | 11 | 1 | extensions-manifestv2、disable-webstore-urls、0005-disable-default-extensions、add-flag-to-configure-extension-downloading、add-flag-to-hide-extensions-menu、fix-building-without-safebrowsing（20） |
| Sync | 2 | 1 | remove-unused-preferences-fields（10）、fix-building-without-safebrowsing（1） |
| Safe Browsing | 5 | 1 | fix-building-without-safebrowsing（24）、remove-unused-preferences-fields（57）、iridium の safe_browsing の reporting のパッチ 2 件、inox 0001 |
| Component updater | 6 | 1 | 0015-disable-update-pings、disable-webstore-urls、disable-ai、fix-building-without-safebrowsing |

注: 「プロファイル」と「Sync」の行はパスの部分文字列（`profile`、`sync`）で照合しているため、わずかに多めに当たっている。

ドメインの置換も、これらの領域のファイルを書き換える（`domain_substitution.list` の項目数）。`chrome/browser/ui/` 486（うち `ui/views/tabs/` 6）、`chrome/browser/extensions/` 132、`extensions/` 95、`components/omnibox/` 78、`components/safe_browsing/` 42、`components/sync*` 27、`chrome/browser/profiles/` 16、`components/component_updater/` 1 である。pruning はこれらの領域にほとんど触れない（`chrome/browser/ui/` 1、`components/safe_browsing/` 3）。

所見（実測した事実のみ。結論は §4.2 の棚卸しに委ねる）:
- `extra` に含まれる `chrome/browser/ui` とタブストリップのパッチは、ほぼすべてが Chrome の `BrowserView`、Views のタブストリップ、ツールバーに作用する。Ararat はこれらをインスタンス化しない。したがって、これらは衝突ではなく skip list の候補である。
- `core` の大きな 3 つのパッチ（prefs の削除、Safe Browsing の削除、AI の削除）は、`chrome/browser/ui`、プロファイル、拡張機能、sync、Safe Browsing を一度にまたぐ。Ararat が引き継ぐ hunk 数の大半は、この 3 つを skip するか keep するかで決まる。
- §4.2 が言う Safe Browsing の削除は、`fix-building-without-safebrowsing` と `safe_browsing_mode=0` の組である。

## 4. バージョンの差と適用可否の確認

- **実測:** 上流の master と macOS の repo の対象は **156.0.8078.79** であり、Ararat の checkout は **157.0.8103.39** である。バージョンが一致しないため、`~/chromium-build/src` の worktree に対する `git apply --check` は**実行していない**（タスクの規則による）。
- **実測:** 最も近い上流の作業は、**157.0.8103.38**（Ararat より 1 つ下のパッチリリース）を対象とする PR #4032 で、まだ open である。これもバージョンが厳密には一致しないため、Ararat の .39 の tree に対しては実行していない。.38 → .39 は同じ branch（8103）の respin なので、この PR が merge されたとき、または owner がこの PR に対する確認を認めたときには、この PR が自然な候補となる。
- **実測:** 156 の series が触れる 690 ファイルのうち、663 が Ararat の 157 の src の git repo に存在する。残りの 27 の内訳は次のとおりである。17 はパッチが新規に作るファイル（`components/ungoogled/*`、`*_flag_entries.h`、`trk_protocol_handler.*`、`referrer_sanitizer.*` など）である。8 は `src` の `git worktree` に含まれない DEPS の sub-repo にある（`third_party/devtools-frontend` 5、`v8/` 3）。`third_party/search_engines_data/.../prepopulated_engines.json` も同様である。`chrome/browser/enterprise/connectors/reporting/telomere_reporting_context.cc` は 157 に存在しない。
- 今後の確認への帰結（レイアウトについての事実であり、実行はしていない）: `src` の `git worktree` だけでは series を当てられない。`v8/` と `third_party/devtools-frontend` へのパッチには、それらの sub-repo の checkout も要る。上流は release の tarball（`chromium-<ver>-lite.tar.xz`、`downloads.ini`）に当てており、そこではすべてが 1 つの tree にある。
- **実測（156 → 157 の rebase。PR #4032 と master の比較）:** 70 ファイルが変更され、+1,165 / −1,163 である。
  - パッチ: 64 が変更、2 が削除された（`upstream-fixes/wasm-interpreter-fixes` は上流に取り込まれた。`core/ungoogled-chromium/disable-tos-dialog` は不要になった）。64 のうち 45 は hunk のオフセットかヘッダだけが変わった（quilt の refresh）。**19 は内容が変わった**。
  - 内容の変更が大きいもの: remove-unused-preferences-fields（+351/−249）、disable-ai（+142/−308）、fix-building-without-safebrowsing（+101/−218）、remove-uneeded-ui（+37/−40）、add-flag-for-search-engine-collection（+37/−14）、add-suggestions-url-field、disable-gcm。
  - リスト: `domain_substitution.list` は +147 / −65 項目、`pruning.list` は +133 / −2 項目。
  - 時間（上流は stable が更新されるとプラットフォームごとに "Updating to Chromium X" の issue を自動で起票する。issue の `createdAt` = stable の日付）:

    | 更新 | 種類 | Stable の issue の起票 | PR の作成 | Merge | Stable → merge |
    |---|---|---|---|---|---|
    | 156.0.8078.47 | milestone の bump | 2026-10-20 20:53Z | 2026-10-18（stable より前） | 2026-10-23 01:55Z | 約 2.2 日 |
    | 156.0.8078.73 | 同じ milestone の respin | 2026-10-27 20:52Z | 2026-10-27 21:01Z | 2026-10-28 00:26Z | 約 3.6 時間 |
    | 156.0.8078.79 | 同じ milestone の respin | 2026-10-29 21:52Z | 2026-10-29 21:56Z | 2026-10-30 14:19Z | 約 16.5 時間 |
    | 157.0.8103.38 | milestone の bump | 2026-11-03 21:52Z（macOS では .39） | 2026-11-01（stable より前） | 2026-11-05 時点で open | 現時点で約 1.5 日超 |

    macOS のパッケージングは generic の repo より遅れる。macOS の repo が 156.0.8078.79 を取り込んだのは 2026-11-03 で、generic の merge（2026-10-30）の 4 日後であった。

## 5. 上流のバージョン更新の手順（上流の文書による）

generic の repo の `docs/developing.md` の "Workflow of updating to a new Chromium version":
1. ソースの tarball を取得する（`utils/downloads.py retrieve/unpack -i downloads.ini`）か、clone する（`utils/clone.py`）。
2. `devutils/update_lists.py -t build/src` で `pruning.list` と `domain_substitution.list` を再生成する。
3. ドメインの置換を当て**ない**状態で、`source devutils/set_quilt_vars.sh` の後に `quilt push -a --refresh` を実行する。失敗したら `quilt push -f` を実行し、`quilt edit/add/remove` で直して `quilt refresh` し、これを繰り返す。`quilt refresh` の信頼性を保つため、大きな削除は `#if 0` やコメントではなく 1 行ずつ行う。
4. `quilt pop -a`、`devutils/validate_config.py`、`devutils/validate_patches.py -l build/src`。
5. 置換を当てた状態でビルドが失敗したら、`utils/domain_substitution.py revert` を実行し、パッチを直し、置換を当て直して再ビルドする。
6. generic の repo に PR を出す。merge の後、各プラットフォームの repo を更新する。

macOS の repo の `README.md` の "Updating": `devutils/update_patches.sh merge`（generic と macOS の series を merge する）、`set_quilt_vars.sh`、ソースの取得（`--all`、またはフェーズごとに `-g`/`-p`）、`src/tools/rust/update_rust.py` の `RUST_REVISION` に合わせた Rust のツールチェーンの更新（nightly の日付を調べる）、同じ quilt のループ、`validate_config.py`、`update_patches.sh unmerge`、`check_patch_files.sh`、commit の順である。

上流の文書とコードの食い違い: `docs/developing.md` は、新しいスイッチを `resources/patches/ungoogled-chromium/add-third-party-ungoogled.patch` を編集して `third_party/ungoogled/ungoogled_switches.cc` に入れると書いている。しかし tree に `resources/` のディレクトリは無く、スイッチのファイルは `patches/extra/ungoogled-chromium/add-components-ungoogled.patch` によって `components/ungoogled/ungoogled_switches.cc` として作られる。

上流のツールは、fuzz を許す refresh を伴う quilt を前提とする。Ararat の `series-check`（§4.2）は fuzz を許さないバイト比較である。したがって、ungoogled のリリースは上流が refresh した状態で取り込み、その後 Ararat 側で確認することになる。

## 6. 見積もり（実測していない）

下の 1 つ目の見積もりは、後に実測した（2026-11-05。対象は 137 本すべてではなく、Ararat の phase 2 の 27 本）。git + gclient の 157.0.8103.39 の tree では、取り込んだ 25 本のうち 14 本が 156 のコミットのままでは当たらなかった。その 14 本は PR #4032 の版で fuzz なしに当たった。macOS の repo の `disable-crashpad-handler.patch` は、crashpad の `InitialStart` に `embedder_port` 引数が増えたため、手で当て直す必要があった。こちらの 2 本はそのまま当たった。取得の開始から series 全体の適用までおよそ 8 分、正式なビルドのフルビルドは 4,821 秒であった（architecture の §4.2、§4.7）。

- *見積もり:* PR #4032 の series を 157.0.8103.39 に当てるには、.38 で要した作業以外はほとんど、あるいはまったく要らないはずである。.38 → .39 は branch 8103 の respin だからである。DEPS の sub-repo を含む完全な tree で `--check` を実行するまでは確かめられていない。
- *見積もり（時間の表から。n=2 と n=2）:* generic の repo は、同じ milestone の respin を stable から 1 日以内に、milestone の bump を約 2 日以上で merge する。macOS の repo はその上にさらに数日を要する（156.0.8078.79 では 4 日）。macOS の repo を待つ方式は §4.9 の 7 日の上限には収まるが、in-the-wild の exploit に対する 48 時間の上限には収まらない。generic の series を取り込み、27 の macOS のパッチを Ararat 側で保持すれば、macOS の遅れは無くなる。
- *見積もり:* Ararat が `extra` の UI のパッチの大半を skip する場合（それらは Ararat がインスタンス化しない Views の UI を対象とする）、引き継ぐ hunk 数は 1,425 から、core の約 985 と macOS の 235 の合計に近づく。どちらの場合も core の大きな 3 つのパッチが大半を占め、156 → 157 で内容の変更が最も多かったのもこの 3 つである。
- *見積もり:* ドメインの置換は `chrome/browser/ui/` の下だけで約 486 ファイルを書き換える。これらのファイルへの Ararat のパッチは、置換後の tree と置換前の tree のどちらか一方に対して一貫して書く必要がある。上流の規則は "patches against the unsubstituted tree" である。

## 7. 行わなかったこと

- この一覧を書いた時点では、`git apply --check` を実行しておらず（バージョンの不一致: 156.0.8078.79 / 157.0.8103.38 と 157.0.8103.39）、ビルドも `gclient` も実行していなかった。phase 2 の series は後に適用してビルドした。計測したリベースは第 6 節の冒頭にある。
- パッチごとの判断は第 8 節にある。

## 8. パッチごとの判断

第 1〜5 節と同じ clone と数え方を用いる（hunk = 各パッチファイルの `@@` で始まる行）。
series は 156.0.8078.79 のものであり、Ararat のベースは 157.0.8103.39 である（第 8.5 節を参照）。

用いた判断の規則:

- **維持**: Google のサービスへの通信やテレメトリを取り除くか、Ararat のビルドに必要であり、かつ Ararat の要件（Web Store からのインストールと更新、MV3、パスキー、自動入力、権限のプロンプト、DevTools、proprietary codecs、Ararat の評判チェック、場合によっては Widevine、Ararat 自身の UI）のいずれとも衝突しない。
- **スキップ**: 要件と衝突する、Ararat が置き換える Chrome の UI にしか触れない、オプトインの chrome://flags の項目である、または Ararat のレイヤーが代わりに設定する設定の既定値である。
- **打ち消しパッチ**: 維持したうえで、そのパッチが取り除くものを戻す Ararat 自身の変更を加える。
- **暫定**: 未決の項目に依存する。その項目を括弧内と第 8.4 節に記す。

### 8.1 集計

| 判断 | Generic のパッチ | Generic の hunk | macOS のパッチ | macOS の hunk |
|---|---:|---:|---:|---:|
| 維持 | 22 | 227 | 2 | 4 |
| 維持（暫定） | 3 | 19 | 1 | 8 |
| スキップ | 78 | 909 | 24 | 223 |
| スキップ（暫定） | 4 | 27 | 0 | 0 |
| 打ち消しパッチ | 1 | 12 | 0 | 0 |
| 打ち消しパッチ（暫定） | 2 | 231 | 0 | 0 |
| **合計** | **110** | **1,425** | **27** | **235** |

Ararat が取り込む series から引き継ぐ hunk（Ararat 自身の打ち消しパッチの hunk は含まない）:

| 場合 | Hunk |
|---|---:|
| 常に維持（維持 + 打ち消しパッチ、両方の series） | 243（`update_checker.cc` の hunk を除くと 242） |
| + ドメインの置換を適用（`block-trk-and-subdomains`、`fix-learn-doubleclick-hsts`） | +18 |
| + Safe Browsing を別の情報源で置き換え（`fix-building-without-safebrowsing`、inox `0001`、macOS の `fix-disabling-safebrowsing`、`safe_browsing-disable-reporting-of-safebrowsing-over`） | +240 |
| + pruning を適用（`fix-building-with-prunned-binaries`、`disable-mei-preload`、`disable-privacy-sandbox`） | +23 |
| + uBlock Origin（MV2）を選択（`extensions-manifestv2`） | +4 |
| 範囲: Google Safe Browsing、置換なし、pruning なし、uBO Lite → 暫定のものをすべて維持 | 243 → 528 |

macOS のビルドの series 全体は 1,660 hunk である（第 2 節）。core の大きな 3 つのパッチは、判断が 3 通りに分かれる。`disable-ai`（116）は維持し、`fix-building-without-safebrowsing`（216）は Safe Browsing の項目に依存し、`remove-unused-preferences-fields`（459）はスキップする。

### 8.2 パッチごとの判断

#### 8.2.1 ungoogled-chromium（generic）、110 パッチ

| パッチ | Hunk | 判断 | 理由 | セキュリティ上の帰結 |
|---|---:|---|---|---|
| `upstream-fixes/missing-dependencies.patch` | 6 | 維持 | series のビルドに要る、欠けている GN の deps と include 1 つを追加する。 | なし |
| `upstream-fixes/wasm-interpreter-fixes.patch` | 2 | スキップ | 上流に取り込まれた。157 の series（PR #4032）には無く、Ararat のベースは 157 である。 | なし |
| `core/inox-patchset/0001-fix-building-without-safebrowsing.patch` | 15 | 打ち消しパッチ（暫定: Safe Browsing） | `safe_browsing_mode=0` のためのビルドの修正である。file-type-policies の component の読み込みも止めるが、Ararat のダウンロードの UI はこれを要する。 | ダウンロードのファイル種別ごとの危険度の動的な更新と、SSL のインタースティシャルの拡張機能イベントがなくなる。ファイル種別の読み込みを戻す（第 8.3 節）。 |
| `core/inox-patchset/0003-disable-autofill-download-manager.patch` | 5 | 維持 | 自動入力のクラウドソーシングの問い合わせと、Google へのアップロードを止める。ローカルの自動入力のヒューリスティクスは引き続き動作する。 | なし |
| `core/inox-patchset/0005-disable-default-extensions.patch` | 6 | スキップ | `webstore_installer.cc` の hunk は、Web Store のダウンロードとインストールの経路を取り除く。アプリ内決済の hunk はブランディングで分岐し、Web Store のアプリの hunk は feature（`kWebstoreHostedApp`）で分岐する。 | スキップすれば、検証済みの Web Store からのインストールが残る（§9）。 |
| `core/inox-patchset/0015-disable-update-pings.patch` | 1 | スキップ | `chrome/updater` を編集するが、これは `enable_updater=false` ではビルドされない。Sparkle がこれを置き換える。 | なし |
| `core/inox-patchset/0021-disable-rlz.patch` | 2 | 維持 | RLZ（プロモーションの追跡）をビルドの段階で無効にする。小さな hunk が 2 つである。 | なし |
| `core/iridium-browser/safe_browsing-disable-incident-reporting.patch` | 5 | 維持 | インシデントと拡張レポートの Google へのアップロードを止める。レポートにだけ作用する。 | なし |
| `core/iridium-browser/safe_browsing-disable-reporting-of-safebrowsing-over.patch` | 1 | 維持（暫定: Safe Browsing） | クライアント側のフィッシング検出が Google に判定を問い合わせる要求を取り除く。 | Google Safe Browsing を用いる場合、クライアント側のフィッシング検出はページをブロックできなくなる。別の情報源を用いる場合はなし。 |
| `core/ungoogled-chromium/disable-crash-reporter.patch` | 4 | 維持 | Google へのクラッシュのアップロードを止め、macOS では Crashpad 全体を止める。 | なし（ローカルのクラッシュダンプも残らない。第 8.4 節を参照） |
| `core/ungoogled-chromium/disable-google-host-detection.patch` | 22 | 維持 | X-Client-Data ヘッダと、Google だけに向けたリクエストの処理を取り除く。 | ポリシーで強制する SafeSearch・YouTube の制限と、Google の bound-session cookie が動作しなくなる。エンタープライズのポリシーか Chrome へのサインインが無ければ影響はない。 |
| `core/ungoogled-chromium/replace-google-search-engine-with-nosearch.patch` | 1 | スキップ | 検索エンジンの既定値は、Ararat のレイヤーが設定する設定である。対象のファイルは DEPS の sub-repo にある。 | なし |
| `core/ungoogled-chromium/toggle-translation-via-switch.patch` | 9 | 維持 | スイッチがスクリプトの URL を指定しない限り、Google の翻訳スクリプトを取得しない。 | なし |
| `core/ungoogled-chromium/disable-untraceable-urls.patch` | 3 | スキップ | `rlz/lib` を編集するが、`disable-rlz` がこれをすでにビルドから外している（未検証。第 8.5 節）。 | なし |
| `core/ungoogled-chromium/disable-profile-avatar-downloading.patch` | 1 | 維持 | gstatic からのアバターのダウンロードを止める。 | なし |
| `core/ungoogled-chromium/disable-gcm.patch` | 10 | 維持 | GCM の check-in と、Google への MCS の接続を止める。 | なし（Web Push が動作しなくなる。第 8.4 節） |
| `core/ungoogled-chromium/disable-domain-reliability.patch` | 9 | 維持 | Google への Domain Reliability のビーコンを止める。 | なし |
| `core/ungoogled-chromium/block-trk-and-subdomains.patch` | 17 | 維持（暫定: ドメインの置換） | `trk:` と `*.qjz9zk` の URL をブロックする。ドメインの置換の安全網であり、置換が無ければ役に立たない。 | なし |
| `core/ungoogled-chromium/disable-gaia.patch` | 1 | 維持 | Gaia の認証の取得を止める。 | なし |
| `core/ungoogled-chromium/disable-fonts-googleapis-references.patch` | 6 | 維持 | リーダーモードが fonts.googleapis.com からフォントを読み込むのを止める。6 つの hunk のうち 4 つは出荷されない文書にある。 | なし |
| `core/ungoogled-chromium/disable-webstore-urls.patch` | 13 | スキップ | 拡張機能の更新確認、Web Store からのインストールのダウンロード、ストアの拡張機能の内容の検証をすべて取り除く。 | スキップすれば、拡張機能の自動更新、内容の検証、Web Store 専用のプロセスが残る。 |
| `core/ungoogled-chromium/fix-learn-doubleclick-hsts.patch` | 1 | 維持（暫定: ドメインの置換） | ドメインの置換が HSTS の生成器を壊さないようにするためにだけ要る。 | なし |
| `core/ungoogled-chromium/disable-webrtc-log-uploader.patch` | 4 | 維持 | Google への WebRTC のログのアップロードを止める。 | なし |
| `core/ungoogled-chromium/disable-ai.patch` | 116 | 維持 | Gemini（Glic）、ScreenAI など、Google と通信するかモデルをダウンロードする AI の機能を取り除く。 | ML による静かな権限のプロンプトがなくなる。PDF の OCR とアクセシビリティの注釈がなくなる。 |
| `core/ungoogled-chromium/fix-building-with-prunned-binaries.patch` | 19 | スキップ（暫定: pruning） | `pruning.list` が prebuilt のファイルを削除するときにだけ要る。Ararat の checkout にはそれらのファイルがある。 | なし |
| `core/ungoogled-chromium/disable-network-time-tracker.patch` | 1 | 維持 | Google への時刻の問い合わせを止める。 | システムの時計のずれが原因の証明書エラーを、その原因によるものとして特定しなくなる。 |
| `core/ungoogled-chromium/disable-mei-preload.patch` | 3 | スキップ（暫定: pruning） | preload のデータファイルを pruning で削除したときにだけ要る。このファイルはローカルのデータであり、通信は無い。 | なし |
| `core/ungoogled-chromium/fix-building-without-safebrowsing.patch` | 216 | 打ち消しパッチ（暫定: Safe Browsing） | Safe Browsing をビルドから取り除く。別の評判の情報源を用いる場合は、このパッチを維持し、§9 と Ararat のダウンロードの UI が要るものを戻す。 | URL・ダウンロードの評判チェック、拡張機能の kill switch（Safe Browsing と Omaha の属性）、ファイル種別の危険度がなくなる。第 8.3 節が後の 2 つを戻す。 |
| `core/ungoogled-chromium/remove-unused-preferences-fields.patch` | 459 | スキップ | Safe Browsing とサインインの設定を Preferences ファイルから削除する。それらの設定が制御する通信は、disable-gaia と空の API キーによってすでに止まっている。最大のパッチである（459 hunk）。 | スキップすれば設定は残る。漏洩したパスワードの確認には引き続き Google の API キーが要り、無効のままである。 |
| `core/ungoogled-chromium/block-requests.patch` | 12 | 打ち消しパッチ | NTP、プロファイルのリセット、affiliation、DevTools の取得を止めるが、`update_checker.cc` の hunk が component updater を無効にする。 | 打ち消しパッチが無ければ、CRLSet、PKI のメタデータ（ルートストア、CT のログリスト）、ファイル種別のポリシー、Widevine が更新されない。 |
| `core/ungoogled-chromium/disable-privacy-sandbox.patch` | 1 | スキップ（暫定: pruning） | attestations のファイルを pruning で削除したときにだけ要る。 | なし |
| `core/ungoogled-chromium/doh-changes.patch` | 4 | スキップ | 設定の既定値の変更である。Secure DNS を無効にし、DoH への自動の切り替えを無効にする。 | スキップすれば、DNS-over-HTTPS への自動の切り替えが残る。 |
| `core/ungoogled-chromium/extensions-manifestv2.patch` | 4 | スキップ（暫定: コンテンツブロッカー） | MV2 の廃止の処理を取り除く。owner が uBlock Origin（MV2）を選んだときにだけ役に立つ。 | なし |
| `core/ungoogled-chromium/remove-f1-shortcut.patch` | 1 | スキップ | Chrome のアクセラレータの表を編集するが、Ararat のホストがこの表を置き換える。 | なし |
| `core/ungoogled-chromium/move-js-optimizer-unfamiliar-sites.patch` | 6 | スキップ | `remove-unused-preferences-fields` が Safe Browsing の設定を取り除くためにだけ存在する。 | なし |
| `core/ungoogled-chromium/remove-navigation-source-param.patch` | 1 | 維持 | 検索の URL に追跡用のパラメータ `source=chrome.ob` を付けるのを止める。 | なし |
| `core/ungoogled-chromium/disable-tos-dialog.patch` | 1 | スキップ | 157 の series には無い（不要になった）。 | なし |
| `core/bromite/disable-fetching-field-trials.patch` | 5 | 維持 | variations の seed の取得を止める。5 つの hunk のうち 4 つは Android の Java であり、作用しない。 | なし |
| `extra/ungoogled-chromium/add-ungoogled-flag-headers.patch` | 7 | スキップ | chrome://flags の項目のための基盤である。フラグのパッチを維持するときにだけ要る。 | なし |
| `extra/inox-patchset/0006-modify-default-prefs.patch` | 13 | スキップ | 設定の既定値である。自動入力、パスワードマネージャ、支払いを無効にするが、Ararat はこれらを要する。 | スキップすれば、パスワードと自動入力は有効のままである。プライバシーの既定値は Ararat のレイヤーに移る（第 8.3 節）。 |
| `extra/inox-patchset/0008-restore-classic-ntp.patch` | 3 | スキップ | 新しいタブのページは Ararat の UI である。 | なし |
| `extra/inox-patchset/0013-disable-missing-key-warning.patch` | 1 | スキップ | Chrome の UI の起動時の infobar である。 | なし |
| `extra/inox-patchset/0016-chromium-sandbox-pie.patch` | 1 | スキップ | Linux 専用である。Linux への移植のときに再検討する。 | なし |
| `extra/inox-patchset/0019-disable-battery-status-service.patch` | 4 | スキップ | Web API の挙動の選択であり、Google への通信ではない。 | スキップすれば、Battery Status API がページから見えるままである（フィンガープリンティングの対象面）。 |
| `extra/debian/disable/google-api-warning.patch` | 1 | スキップ | Chrome の UI の起動時の infobar である。 | なし |
| `extra/iridium-browser/mime_util-force-text-x-suse-ymp-to-be-downloaded.patch` | 1 | スキップ | macOS には関係しない。 | なし |
| `extra/iridium-browser/prefs-always-prompt-for-download-directory-by-defaul.patch` | 1 | スキップ | 設定の既定値である。Ararat のダウンロードの UI が決める。 | なし |
| `extra/iridium-browser/updater-disable-auto-update.patch` | 1 | スキップ | `app_controller_mac.mm` を編集するが、Ararat はこのファイルを置き換える（§4.5）。 | なし |
| `extra/iridium-browser/Remove-EV-certificates.patch` | 1 | スキップ | 表示の選択である。現在の Chrome は EV を区別して表示しない。 | なし |
| `extra/iridium-browser/browser-disable-profile-auto-import-on-first-run.patch` | 1 | スキップ | 初回起動時のインポートは Ararat のレイヤーが抑止する。インポートは Ararat が持つ（§9）。 | なし |
| `extra/bromite/fingerprinting-flags-client-rects-and-measuretext.patch` | 27 | スキップ | オプトインのフラグであり、Google への通信ではない。 | なし |
| `extra/bromite/flag-max-connections-per-host.patch` | 9 | スキップ | オプトインのフラグである。 | なし |
| `extra/bromite/flag-fingerprinting-canvas-image-data-noise.patch` | 14 | スキップ | オプトインのフラグである。 | なし |
| `extra/ungoogled-chromium/add-components-ungoogled.patch` | 3 | スキップ | bromite のフラグのためのスイッチの基盤である。 | なし |
| `extra/ungoogled-chromium/disable-formatting-in-omnibox.patch` | 2 | スキップ | Ararat が置き換える omnibox・ステータスバブルの UI である。 | なし |
| `extra/ungoogled-chromium/add-ipv6-probing-option.patch` | 6 | スキップ | IPv6 の到達性の確認を定数で置き換える。この確認は Google にパケットを送らない。 | なし |
| `extra/ungoogled-chromium/remove-disable-setuid-sandbox-as-bad-flag.patch` | 1 | スキップ | Linux の bad-flags の infobar である。 | なし |
| `extra/ungoogled-chromium/disable-intranet-redirect-detector.patch` | 1 | 維持 | 起動時のランダムなホスト名への DNS の探索を止める。 | なし |
| `extra/ungoogled-chromium/disable-download-quarantine.patch` | 9 | スキップ | ダウンロードの quarantine を取り除く。 | スキップすれば macOS の quarantine 属性が残り、Gatekeeper がダウンロードしたアプリを検査する。 |
| `extra/ungoogled-chromium/fix-building-without-mdns-and-service-discovery.patch` | 10 | 維持 | `flags.gn` の `enable_mdns=false` と `enable_service_discovery=false` のためのビルドの修正である。 | なし |
| `extra/ungoogled-chromium/add-flag-to-configure-extension-downloading.patch` | 8 | スキップ | オプトインのフラグである。 | なし |
| `extra/ungoogled-chromium/add-flag-for-search-engine-collection.patch` | 10 | スキップ | オプトインのフラグである。 | なし |
| `extra/ungoogled-chromium/add-flag-to-disable-beforeunload.patch` | 3 | スキップ | オプトインのフラグである。 | なし |
| `extra/ungoogled-chromium/add-flag-to-force-punycode-hostnames.patch` | 3 | スキップ | オプトインのフラグである。Ararat の UI は URL を自前で整形する。 | なし |
| `extra/ungoogled-chromium/add-flag-to-show-avatar-button.patch` | 3 | スキップ | Chrome のツールバーの UI である。 | なし |
| `extra/ungoogled-chromium/add-suggestions-url-field.patch` | 38 | スキップ | chrome://settings の検索エンジンの編集画面である。Ararat のコマンドバーは独自の編集画面を持つ（第 8.5 節）。 | なし |
| `extra/ungoogled-chromium/add-flag-to-hide-crashed-bubble.patch` | 2 | スキップ | Chrome の UI である。 | なし |
| `extra/ungoogled-chromium/add-flag-to-scroll-tabs.patch` | 7 | スキップ | Chrome のタブストリップの UI である。 | なし |
| `extra/ungoogled-chromium/enable-paste-and-go-new-tab-button.patch` | 3 | スキップ | Chrome のタブストリップの UI である。 | なし |
| `extra/ungoogled-chromium/add-flag-for-bookmark-bar-ntp.patch` | 4 | スキップ | Chrome のブックマークバーの UI である。 | なし |
| `extra/ungoogled-chromium/enable-menu-on-reload-button.patch` | 1 | スキップ | Chrome のツールバーの UI である。 | なし |
| `extra/ungoogled-chromium/add-flag-for-omnibox-autocomplete-filtering.patch` | 9 | スキップ | オプトインのフラグである。Ararat のコマンドバーがプロバイダを選ぶ。 | なし |
| `extra/ungoogled-chromium/disable-dial-repeating-discovery.patch` | 2 | 維持 | ローカルネットワーク上の SSDP（DIAL/Cast）の定期的な探索を止める。 | なし |
| `extra/ungoogled-chromium/remove-uneeded-ui.patch` | 47 | スキップ | chrome:// の WebUI の文字列とリンクである。Ararat がどの WebUI のページを表示するかに依存する（第 8.5 節）。 | なし |
| `extra/ungoogled-chromium/add-flag-to-close-window-with-last-tab.patch` | 5 | スキップ | Chrome のタブストリップの挙動である。ウィンドウは Ararat のホストが持つ。 | なし |
| `extra/ungoogled-chromium/add-flag-to-convert-popups-to-tabs.patch` | 5 | スキップ | オプトインのフラグである。ポップアップの振り分けは Ararat が持つ（§4.6）。 | なし |
| `extra/ungoogled-chromium/add-flag-to-disable-local-history-expiration.patch` | 4 | スキップ | オプトインのフラグである。 | なし |
| `extra/ungoogled-chromium/add-extra-channel-info.patch` | 1 | スキップ | chrome://version の文字列である。 | なし |
| `extra/ungoogled-chromium/prepopulated-search-engines.patch` | 1 | スキップ | 設定の既定値である。 | なし |
| `extra/ungoogled-chromium/add-flag-to-clear-data-on-exit.patch` | 7 | スキップ | オプトインのフラグである。 | なし |
| `extra/ungoogled-chromium/add-flag-for-qr-generator.patch` | 5 | スキップ | Chrome の UI である。 | なし |
| `extra/ungoogled-chromium/add-flag-for-grab-handle.patch` | 3 | スキップ | Chrome のタブストリップの UI である。 | なし |
| `extra/ungoogled-chromium/add-flag-for-close-confirmation.patch` | 12 | スキップ | Chrome の UI である。終了の処理は Ararat の AppController が持つ（§4.5）。 | なし |
| `extra/ungoogled-chromium/keep-expired-flags.patch` | 3 | スキップ | chrome://flags にだけ作用する。 | なし |
| `extra/ungoogled-chromium/add-flag-for-custom-ntp.patch` | 4 | スキップ | 新しいタブのページは Ararat が持つ。 | なし |
| `extra/ungoogled-chromium/add-flag-for-tab-hover-cards.patch` | 7 | スキップ | Chrome のタブストリップの UI である。 | なし |
| `extra/ungoogled-chromium/add-flag-to-hide-tab-close-buttons.patch` | 4 | スキップ | Chrome のタブストリップの UI である。 | なし |
| `extra/ungoogled-chromium/add-flag-to-disable-tls-grease.patch` | 3 | スキップ | オプトインのフラグである。 | なし |
| `extra/ungoogled-chromium/add-flag-to-change-http-accept-header.patch` | 5 | スキップ | オプトインのフラグである。 | なし |
| `extra/ungoogled-chromium/add-flag-for-disabling-link-drag.patch` | 7 | スキップ | オプトインのフラグである。 | なし |
| `extra/ungoogled-chromium/add-flag-to-hide-extensions-menu.patch` | 5 | スキップ | Chrome のツールバーの UI である。 | なし |
| `extra/ungoogled-chromium/add-flag-to-hide-fullscreen-exit-ui.patch` | 4 | スキップ | Chrome の UI である。終了の警告は Ararat の seam が持つ（§4.6）。 | なし |
| `extra/ungoogled-chromium/add-flag-for-incognito-themes.patch` | 4 | スキップ | Chrome の UI である。 | なし |
| `extra/ungoogled-chromium/add-flags-for-referrer-customization.patch` | 17 | スキップ | オプトインのフラグである。 | なし |
| `extra/ungoogled-chromium/default-webrtc-ip-handling-policy.patch` | 1 | スキップ | 設定の既定値である。disable-non-proxied-UDP を設定するが、§4.8 は `default_public_interface_only` を求める。 | Ararat のレイヤーが `default_public_interface_only` を設定する必要がある（第 8.3 節）。設定しなければ、ローカルの IP は Chromium の既定値に従う。 |
| `extra/ungoogled-chromium/add-flags-for-existing-switches.patch` | 3 | スキップ | 既存のスイッチに対する chrome://flags の項目である。 | なし |
| `extra/ungoogled-chromium/first-run-page.patch` | 5 | スキップ | Chrome の初回起動の UI である。 | なし |
| `extra/ungoogled-chromium/add-flag-to-reduce-system-info.patch` | 6 | スキップ | オプトインのフラグである。 | なし |
| `extra/ungoogled-chromium/add-flag-to-remove-client-hints.patch` | 9 | スキップ | オプトインのフラグである。 | なし |
| `extra/ungoogled-chromium/enable-extra-locales.patch` | 5 | スキップ | Chrome の UI のロケールである。Ararat の UI は Swift である。 | なし |
| `extra/ungoogled-chromium/remove-pac-size-limit.patch` | 1 | スキップ | リソースの上限を取り除くものであり、Google への通信ではない。 | スキップすれば、PAC ファイルのサイズの上限が残る。 |
| `extra/ungoogled-chromium/enable-certificate-transparency-and-add-flag.patch` | 2 | スキップ | feature の既定値とフラグである。Ararat のレイヤーが代わりにこの feature を有効にする。 | Ararat のレイヤーが `kCertificateTransparencyAskBeforeEnabling` を有効にする必要がある（第 8.3 節）。有効にしなければ、ブランドのないビルドでは CT が強制されない。 |
| `extra/ungoogled-chromium/add-flag-to-spoof-webgl-renderer-info.patch` | 6 | スキップ | オプトインのフラグである。 | なし |
| `extra/ungoogled-chromium/add-flag-to-increase-incognito-storage-quota.patch` | 6 | スキップ | オプトインのフラグである。 | なし |
| `extra/ungoogled-chromium/add-credits.patch` | 5 | 維持 | ungoogled-chromium の BSD の表示を about:credits に追加する。Ararat は、取り込むパッチに対してこの表示の義務を負う。 | なし |
| `extra/ungoogled-chromium/disable-ai-search-shortcuts.patch` | 2 | 維持 | @gemini、@aimode、@page の starter pack の項目を隠す。隠さなければ、これらは Ararat のコマンドバーに表示される。 | なし |
| `extra/ungoogled-chromium/disable-fedcm-by-default.patch` | 1 | スキップ | feature の既定値である。FedCM は、サイトがサインインに使う Web 標準である。 | なし |
| `extra/ungoogled-chromium/bundle-hyphenation-patterns.patch` | 1 | スキップ | Apple のプラットフォームでは効果が無い（`!is_apple`）。 | なし |
| `extra/ungoogled-chromium/add-flag-for-disabling-jit.patch` | 5 | スキップ | オプトインのフラグである。 | なし |
| `extra/ungoogled-chromium/add-flag-to-hide-window-buttons.patch` | 11 | スキップ | Chrome のフレームの UI である。 | なし |

#### 8.2.2 ungoogled-chromium-macos、27 パッチ

「ツールチェーンの shim」と記した macOS のパッチは、いずれも、macOS の repo が pruning した tree を独自のツールでビルドするために存在する。`build.sh` は GN をソースからブートストラップし、bindgen をビルドし、esbuild を `npm install` で導入し、`/opt/homebrew/bin/{esbuild,tsc}` を参照する。Ararat の checkout `~/chromium-build/src` には、Chromium の prebuilt の `third_party/llvm-build`、`third_party/rust-toolchain`、`third_party/crubit`、`third_party/node/mac_arm64`、`third_party/devtools-frontend/src/third_party/esbuild`、`buildtools/mac/gn`、`third_party/cpython3/host/bin`、`tools/clang/dsymutil/bin` がある（2026-11-05 に実測）。architecture §4.7 の stock の 157 のビルドは、これらのパッチを 1 つも用いずに成功した。そのビルドは official の構成ではなかった（`symbol_level=0`、ThinLTO なし、PGO なし）。したがって、official の構成でだけ意味を持つ shim（`disable-symbol-order-verification`、`fix-dsymutil`、`fix-complex-builtins`）は、ビルドではなく、それらが置き換えるツールが存在することを根拠にスキップする。

| パッチ | Hunk | 判断 | 理由 | セキュリティ上の帰結 |
|---|---:|---|---|---|
| `ungoogled-chromium/macos/build-bindgen.patch` | 3 | スキップ | pruning した tree のためのツールチェーンの shim である。Ararat の gclient の checkout には Chromium のツールチェーンがある。 | なし |
| `ungoogled-chromium/macos/disable-clang-version-check.patch` | 2 | スキップ | ツールチェーンの shim（古い clang）である。 | なし |
| `ungoogled-chromium/macos/disable-crashpad-handler.patch` | 2 | 維持 | Crashpad のハンドラのプロセスを起動させない。macOS の repo は、これを disable-crash-reporter と並べて保持している。 | なし |
| `ungoogled-chromium/macos/disable-symbol-order-verification.patch` | 1 | スキップ | ツールチェーンの shim（独自の libc++ のビルド）である。 | なし |
| `ungoogled-chromium/macos/fix-build-with-rust.patch` | 3 | スキップ | ツールチェーンの shim（独自の Rust のツールチェーン）である。 | なし |
| `ungoogled-chromium/macos/fix-clang-format-path.patch` | 1 | スキップ | ツールチェーンの shim（システムの clang-format）である。 | なし |
| `ungoogled-chromium/macos/fix-disabling-safebrowsing.patch` | 8 | 維持（暫定: Safe Browsing） | `safe_browsing_mode=0` のための macOS のビルドの修正である。`chrome_content_browser_client.cc` の hunk は disable-ai に由来する（ScreenAI と TranslateKit の sandbox のパス）。 | このパッチ自体にはなし。保護の変化は fix-building-without-safebrowsing にある。 |
| `ungoogled-chromium/macos/fix-dsymutil.patch` | 2 | スキップ | ツールチェーンの shim（システムの dsymutil）である。 | なし |
| `ungoogled-chromium/macos/no-unknown-warnings.patch` | 1 | スキップ | ツールチェーンの shim（古い clang）である。 | なし |
| `ungoogled-chromium/macos/build-bindgen-target-override.patch` | 5 | スキップ | ツールチェーンの shim（ローカルの bindgen のビルド）である。 | なし |
| `ungoogled-chromium/macos/bindgen-disable-static.patch` | 1 | スキップ | ツールチェーンの shim（ローカルの bindgen のビルド）である。 | なし |
| `ungoogled-chromium/macos/set-rustc-nightly-capability.patch` | 1 | スキップ | ツールチェーンの shim（独自の Rust のツールチェーン）である。 | なし |
| `ungoogled-chromium/macos/revert-v8-sanitizer-changes.patch` | 3 | スキップ | ツールチェーンの shim（古い clang）である。 | なし |
| `ungoogled-chromium/macos/fix-nasm-build-config.patch` | 1 | スキップ | ツールチェーン・SDK の shim である。Ararat の stock のビルドは、これなしで nasm をコンパイルする。 | なし |
| `ungoogled-chromium/macos/fix-anyappleos-availability.patch` | 2 | スキップ | ツールチェーンの shim（`anyAppleOS` を持たない clang）である。 | なし |
| `ungoogled-chromium/macos/fix-build-without-crubit.patch` | 64 | スキップ | 独自のツールチェーンに Crubit が無いため、Crubit の使用箇所を取り除く。DevTools の Storage ドメインも削除する。 | スキップすれば、DevTools の Storage ドメインが残る。 |
| `ungoogled-chromium/macos/use-system-python.patch` | 1 | スキップ | ツールチェーンの shim（システムの python）である。 | なし |
| `ungoogled-chromium/macos/fix-disable-verification-token.patch` | 31 | スキップ | Crubit なしのビルドのために Private Verification Tokens を取り除く。 | なし |
| `ungoogled-chromium/macos/fix-esbuild.patch` | 4 | スキップ | ツールチェーンの shim（Homebrew の esbuild）である。 | なし |
| `ungoogled-chromium/macos/fix-typescript.patch` | 3 | スキップ | ツールチェーンの shim（Homebrew の tsc）である。 | なし |
| `ungoogled-chromium/macos/restore-typescript-js-compiler.patch` | 13 | スキップ | ツールチェーンの shim（tsgo の代わりに node の tsc）である。 | なし |
| `ungoogled-chromium/macos/fix-gn-compatibility.patch` | 11 | スキップ | ソースからビルドした GN のための shim である。Ararat の checkout には Chromium の GN がある。 | なし |
| `ungoogled-chromium/macos/fix-gn-compatibility-chromium-156.patch` | 64 | スキップ | ソースからビルドした GN のための shim である。名前に 156 のバージョンを含む。 | なし |
| `ungoogled-chromium/macos/fix-typescript-isolated-declarations.patch` | 2 | スキップ | ツールチェーンの shim（古い tsc）である。 | なし |
| `ungoogled-chromium/macos/fix-complex-builtins.patch` | 2 | スキップ | ツールチェーンの shim（独自の Rust の compiler_builtins）である。 | なし |
| `ungoogled-chromium/macos/set-bundle-identifier.patch` | 2 | スキップ | Ararat の bundle identifier は Ararat のブランディングから決まる。 | なし |
| `ungoogled-chromium/macos/add-local-network-usage-description.patch` | 2 | 維持 | macOS がローカルネットワークへのアクセスに要求する `NSLocalNetworkUsageDescription` を、アプリとヘルパーの plist に追加する。 | なし |

#### 8.2.3 リストとフラグとの相互作用

- `domain_substitution.list` は、Ararat が変更せずに要するファイルの Google のホストを書き換える。対象は `extensions/common/extension_urls.cc`/`.h`（Web Store）、`chrome/browser/extensions/updater/chrome_update_client_config.cc`（拡張機能の更新）、`components/component_updater/component_updater_url_constants.cc`（component updater）、`components/safe_browsing/core/common/features.cc`/`.h`（Safe Browsing）である。置換後のホストは `qjz9zk` で終わり、`block-trk-and-subdomains` がこれをブロックする。したがって、`disable-webstore-urls` をスキップするだけでは足りない。この 6 つのファイルは除外の最小限であり、監査の範囲はより広い（置換は `components/safe_browsing/` の下の 42 ファイル、`chrome/browser/extensions/` の下の 132 ファイル、`extensions/` の下の 95 ファイルに触れる。第 3 節）。置換は、どのパッチも触れない Google のホスト（例: optimization guide、suggest）への通信を止める唯一の手段でもあるため、置換をやめるとその通信が再び有効になる。選択肢は、除外つきの置換か、置換なしでエンドポイントごとの監査を行うかである。
- `pruning.list` は、Ararat の checkout にあり Ararat が要するファイルを削除する。対象は `chrome/browser/resources/media/mei_preload/preloaded_data.pb`、`components/privacy_sandbox/privacy_sandbox_attestations/preload/privacy-sandbox-attestations.dat`、prebuilt のツールチェーンである。pruning を行わなければ、`fix-building-with-prunned-binaries`、`disable-mei-preload`、`disable-privacy-sandbox` と、macOS のツールチェーンの shim はすべて不要である。
- `flags.gn`:
  - `safe_browsing_mode=0` と `google_api_key=""` は Safe Browsing の項目に従う。Google Safe Browsing には `safe_browsing_mode=1` と API キーが要る。
  - `enable_widevine=true` が設定されているが、Widevine の CDM は component updater を通じて届き、`block-requests` が component updater を無効にする（第 8.3 節）。
  - `enable_mdns=false` と `enable_service_discovery=false` は §4.8 と一致し、`fix-building-without-mdns-and-service-discovery` を要する。
  - `enable_reporting=false` は Reporting API と Network Error Logging を取り除くため、サイトはそれらのレポートを受け取れなくなる。これはパッチではなくフラグであり、GN の引数のファイル（§4.7）とあわせて別に判断する必要がある。
- `flags.macos.gn`: `enable_updater=false` によって、`0015-disable-update-pings` はデッドコードになる。

### 8.3 打ち消しパッチと、Ararat のレイヤーが設定する既定値

打ち消しパッチ（維持するパッチの上に加える Ararat の変更）:

1. `block-requests`（12 hunk）: `components/update_client/update_checker.cc` の hunk を除いて保持し（12 hunk のうち 11）、ドメインの置換を適用する場合は `component_updater_url_constants.cc` を置換から除外する。これにより component の更新が戻る。対象は CRLSet、PKI のメタデータ（Chrome Root Store と CT のログリスト）、ファイル種別のポリシー、DRM を選ぶ場合は Widevine の CDM である。拡張機能の更新が使う `update_client` の経路も戻る。
2. `fix-building-without-safebrowsing`（216 hunk。Safe Browsing = 別の情報源の場合の暫定）: 次のものを戻す。
   - 更新の応答に含まれる Google の拡張機能の kill switch を扱う、Omaha の属性の経路（§9）。`chrome/browser/extensions/extension_service.cc`/`.h` の `OmahaAttributesHandler` のメンバと `PerformActionBasedOnOmahaAttributes`、`chrome_extension_system.cc` でのその呼び出し、およびこの経路が依存する `extensions/browser/extension_registrar.cc` の blocklist と greylist の状態の処理である。
   - ダウンロードのファイル種別の危険度。`chrome/browser/download/chrome_download_manager_delegate.cc` の `SetDangerLevel` と `DownloadRestrictions` の case である。
   - 取り除かれた Safe Browsing の URL とダウンロードのチェックがあった位置に置く、Ararat の評判チェックのためのフック（§14）。
3. inox `0001-fix-building-without-safebrowsing`（15 hunk。同じ暫定）: `chrome/browser/component_updater/file_type_policies_component_installer.cc` の動的な更新の読み込みを戻し、ファイル種別のポリシーが component updater を通じて更新されるようにする（打ち消しパッチ 1 を要する）。

スキップしたパッチの代わりに Ararat のレイヤーが設定する既定値（`//chrome/browser/ararat` からの feature の上書き、または登録した設定の既定値であり、Chrome のファイルは編集しない）:

- セキュリティに関わるもの:
  - `kCertificateTransparencyAskBeforeEnabling` を有効にする（`enable-certificate-transparency-and-add-flag` の代わり）。これが無ければ、ブランドのないビルドは CT を強制しない。組み込みのログリストが古くなった場合も強制は止まるが、打ち消しパッチ 1 がこれを防ぐ。
  - WebRTC の IP の扱いのポリシーを `default_public_interface_only` に設定する（§4.8。`default-webrtc-ip-handling-policy` の代わり。このパッチはより厳しいポリシーを設定し、直接の UDP を壊す）。
- owner が決める設定の選択:
  - `0006-modify-default-prefs` から: ハイパーリンクの監査を無効、サードパーティの cookie をブロック、ネットワークの予測を無効、バックグラウンドモードを無効。
  - 既定の検索エンジン（`replace-google-search-engine-with-nosearch`、`prepopulated-search-engines`）。
  - 初回起動時の自動インポートなし（`browser-disable-profile-auto-import-on-first-run`）。

### 8.4 未決の項目に依存する判断

architecture §14 にすでにある項目:

- **Safe Browsing の情報源。** `fix-building-without-safebrowsing`（216）、inox `0001`（15）、macOS の `fix-disabling-safebrowsing`（8）、`safe_browsing-disable-reporting-of-safebrowsing-over`（1）と、GN の引数 `safe_browsing_mode` と `google_api_key` が対象である。
  - API キーを用いる Google Safe Browsing: 4 つすべてをスキップし、`safe_browsing_mode=1` とキーを設定し、`components/safe_browsing/core/common/features.*` をドメインの置換から除外する。macOS の `fix-disabling-safebrowsing` の disable-ai の hunk がなお要るかは不明である（第 8.5 節）。
  - 別の情報源: 打ち消しパッチ 2 と 3 として維持する。これにより 240 hunk と Ararat 自身の hunk が加わる。
- **DRM。** Widevine は、`enable_widevine=true` にかかわらず打ち消しパッチ 1（component updater）を要する。
- **コンテンツブロッカー。** `extensions-manifestv2`（4）は uBlock Origin（MV2）にだけ要る。現在の方向（uBO Lite）ではスキップする。

§14 に無い項目（新規）:

- **`pruning.list` を適用するか否か。** これにより、`fix-building-with-prunned-binaries`（19）、`disable-mei-preload`（3）、`disable-privacy-sandbox`（1）と、macOS のツールチェーンの shim 24 件（223）が戻るかどうかが決まる。ここでの推奨は、実測した stock のビルドと同じく pruning を行わないことを前提とする。
- **除外つきのドメインの置換か、置換なしでエンドポイントごとの監査か。** これにより `block-trk-and-subdomains`（17）と `fix-learn-doubleclick-hsts`（1）が決まる。置換を行う場合、Web Store、component updater、Safe Browsing のファイルには除外が要る（第 8.2.3 節）。置換を行わない場合、どのパッチも触れない Google のホストに再び到達できるようになる。
- **維持するパッチによる機能の喪失**（owner はまだいずれについても判断していない）:
  - Web Push が止まる（`disable-gcm`）。
  - 翻訳が無効である（`toggle-translation-via-switch`）。
  - Ararat 自身の診断に使うローカルのクラッシュダンプが存在しない（`disable-crash-reporter`、`disable-crashpad-handler`）。
  - PDF の OCR と ScreenAI のアクセシビリティの注釈がなくなる（`disable-ai`）。
  - `chrome.identity.getAuthToken` は、prefs のパッチの有無にかかわらず、Google へのサインインなしでは動作しない。

### 8.5 未確定の事項

- パッチは 1 つも適用しておらず、何もビルドしていない。series の対象は 156.0.8078.79 であり、Ararat のベースは 157.0.8103.39 である。第 4 節は、156 → 157 で内容が変わった 19 のパッチを挙げている（`remove-unused-preferences-fields`、`disable-ai`、`fix-building-without-safebrowsing`、`remove-uneeded-ui`、`add-flag-for-search-engine-collection`、`add-suggestions-url-field`、`disable-gcm` を含む）。これらに対する判断は、157 の series が固定された後に、その series に対して再確認する必要がある。hunk 数は 156 のファイルのものである。
- `fix-building-without-safebrowsing` が `remove-unused-preferences-fields` なしでビルドできるか。後者はモードに依存しない `safe_browsing_prefs` ライブラリを削除する（`components/safe_browsing/core/common/BUILD.gn` は `safe_browsing_mode` の値によらずこのライブラリをビルドする）ため、後者はビルドの要件ではなく整理と読める。これを確かめられるのは `safe_browsing_mode=0` でのビルドだけである。要件であれば、後者は 459 hunk とともに「打ち消しパッチ（暫定: Safe Browsing）」に移り、`move-js-optimizer-unfamiliar-sites`（6）もそれに伴って移る。
- `disable-rlz` が `enable_rlz_support=false` を設定した後に `disable-untraceable-urls` がデッドコードになるか、および `disable-crash-reporter` が macOS で `InitializeCrashpadImpl` から早期に return した後に `disable-crashpad-handler` が冗長になるか。どちらもビルドを要する。
- Glic や ScreenAI のビルドフラグなどの GN の引数で、`disable-ai`（116 hunk）の一部を置き換えられるか。確認していない。
- Ararat がどの chrome:// の WebUI のページ（settings、extensions、history、flags）を表示するか。これにより `remove-uneeded-ui`（47）、`add-suggestions-url-field`（38）、`keep-expired-flags`、`first-run-page` が決まる。これらは、Ararat の UI がそれらのページを置き換えるという前提でスキップしている。
- Ararat のホストが Chrome の起動時の infobar（`AddInfoBarsIfNecessary`）を呼ぶか。呼ぶ場合、API キーが無いことを示す infobar が表示され、`0013-disable-missing-key-warning` と `google-api-warning` は維持する価値を持つ。
- macOS の `fix-disabling-safebrowsing` の disable-ai の hunk（`chrome_content_browser_client.cc` の ScreenAI と TranslateKit の sandbox のパラメータ）は、Google Safe Browsing を用いる場合にも要る可能性がある。
- 組み込みの CT のログリストがどれだけ古くなると Chromium が CT の強制を止めるかは、計測していない。
- 打ち消しパッチ 3 は、`safe_browsing::FileTypePolicies` が `safe_browsing_mode=0` でもビルドされることを前提とする。検証していない。
- official build の構成（`is_official_build`、ThinLTO、PGO、`symbol_level=1`）は試していない。したがって、macOS のツールチェーンの shim のスキップは、official でない stock のビルドについてだけ確かめられている。

### 8.6 Phase 2 でビルドする構成（2026-11-05 に決定、暫定）

Phase 2 は第 8.1 節の最小の場合をビルドする。条件なしで維持または打ち消しパッチとした 25 のパッチ（generic 23、macOS 2。243 hunk）を、156.0.8078.79 の git + gclient の checkout に適用する。

- Safe Browsing: Google Safe Browsing をビルドに残し（`safe_browsing_mode=1`、既定値）、Safe Browsing の 4 つのパッチは適用しない。API キーはまだ設定していないため、照会は行われない。情報源は引き続き owner の §14 の項目であり、日常の使用の前に決める必要がある（§4.9）。これにより、打ち消しパッチ 2 と 3 なしで、§9 の拡張機能の kill switch とダウンロードのファイル種別の危険度が残る。
- ドメインの置換も pruning も行わない（gclient の prebuilt のツールチェーンを残す）。したがって、`block-trk-and-subdomains`、`fix-learn-doubleclick-hsts`、pruning のためのビルドの修正、macOS のツールチェーンの shim 24 件は適用しない。どのパッチも触れない Google のホストには、エンドポイントの監査を行うまで到達できるままである。
- `block-requests` は変更せずに保持し、その後に `update_checker.cc` の hunk を戻す Ararat の打ち消しパッチを適用する。これにより、component updater（CRLSet、PKI のメタデータ、ファイル種別のポリシー）は動作し続ける。
- GN の引数: ungoogled の `flags.gn` と `flags.macos.gn` から `safe_browsing_mode=0` を除いたもの。`enable_reporting=false` は当面残す。
- 第 8.3 節の既定値（CT の強制、WebRTC の IP のポリシー、設定の選択）は Ararat のレイヤーに属し、Phase 3 で導入する。

macOS の repo の遅れ（第 4 節）は、第 6 節の想定ほど重要ではない。27 のパッチのうち適用するのは 2 つである。
