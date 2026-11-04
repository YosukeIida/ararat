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

上流のツールは、fuzz を許す refresh を伴う quilt を前提とする。Ararat の `series check`（§4.2）は fuzz を許さないバイト比較である。したがって、ungoogled のリリースは上流が refresh した状態で取り込み、その後 Ararat 側で確認することになる。

## 6. 見積もり（実測していない）

- *見積もり:* PR #4032 の series を 157.0.8103.39 に当てるには、.38 で要した作業以外はほとんど、あるいはまったく要らないはずである。.38 → .39 は branch 8103 の respin だからである。DEPS の sub-repo を含む完全な tree で `--check` を実行するまでは確かめられていない。
- *見積もり（時間の表から。n=2 と n=2）:* generic の repo は、同じ milestone の respin を stable から 1 日以内に、milestone の bump を約 2 日以上で merge する。macOS の repo はその上にさらに数日を要する（156.0.8078.79 では 4 日）。macOS の repo を待つ方式は §4.9 の 7 日の上限には収まるが、in-the-wild の exploit に対する 48 時間の上限には収まらない。generic の series を取り込み、27 の macOS のパッチを Ararat 側で保持すれば、macOS の遅れは無くなる。
- *見積もり:* Ararat が `extra` の UI のパッチの大半を skip する場合（それらは Ararat がインスタンス化しない Views の UI を対象とする）、引き継ぐ hunk 数は 1,425 から、core の約 985 と macOS の 235 の合計に近づく。どちらの場合も core の大きな 3 つのパッチが大半を占め、156 → 157 で内容の変更が最も多かったのもこの 3 つである。
- *見積もり:* ドメインの置換は `chrome/browser/ui/` の下だけで約 486 ファイルを書き換える。これらのファイルへの Ararat のパッチは、置換後の tree と置換前の tree のどちらか一方に対して一貫して書く必要がある。上流の規則は "patches against the unsubstituted tree" である。

## 7. 行わなかったこと

- `git apply --check` は実行していない（バージョンの不一致: 156.0.8078.79 / 157.0.8103.38 と 157.0.8103.39）。
- ビルドも `gclient` も実行しておらず、`~/chromium-build/src` には触れていない。
- パッチごとの keep / skip / 打ち消しパッチの判断と、そのセキュリティ上の帰結（§4.2 の Phase 2 の棚卸し）は、ここでは行っていない。
