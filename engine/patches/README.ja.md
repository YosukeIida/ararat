# エンジンのパッチセット

パッチの順序は `series` だけで定める。パスはこのディレクトリからの相対パスであり、ungoogled/generic を ungoogled/macos より先に適用する。取り込んだ 25 件のパッチは下記のコミットに由来する。独自のパッチは 6 件であり、対抗パッチ、ScreenAI の修正、レイヤーと hook の 3 件、viewless ウィンドウの修正からなる。

| ソース | コミット | Chromium |
|---|---|---|
| ungoogled-software/ungoogled-chromium、pull request #4032（2026-11-05 時点で未マージ） | de09e0c70c6bc1ac83d4ecdfd0e82c7e250c9a3c | 157.0.8103.38 |
| ungoogled-software/ungoogled-chromium-macos | 31f01756a43d55b2c4211e73ca329bfab4ebfcb2 | 156.0.8078.79 |

generic のパッチは pull request の head のバイト単位のコピーである。対象は 157.0.8103.38 であり、Ararat の 157.0.8103.39 に fuzz なしで適用できる。マージ後はマージされたコミットから取り込み直す。macOS の 2 件のうち、`add-local-network-usage-description.patch` はコピーし、`disable-crashpad-handler.patch` は手作業で 157 にリベースした（crashpad の `InitialStart` に `embedder_port` 引数が加わったため）。元の効果は維持しており、`InitialStart` は空の send right を返し、`StartHandler` は false を返す。

両プロジェクトは BSD-3-Clause である。LICENSE ファイルは `ungoogled/generic/LICENSE` と `ungoogled/macos/LICENSE` に変更せず保存する。

## 取り込んだ 25 件と独自の 6 件（series 順）

| # | `series` 内のファイル | 出典 |
|---|---|---|
| 1 | `ungoogled/generic/upstream-fixes/missing-dependencies.patch` | generic, upstream-fixes |
| 2 | `ungoogled/generic/core/inox-patchset/0003-disable-autofill-download-manager.patch` | generic, core/inox-patchset |
| 3 | `ungoogled/generic/core/inox-patchset/0021-disable-rlz.patch` | generic, core/inox-patchset |
| 4 | `ungoogled/generic/core/iridium-browser/safe_browsing-disable-incident-reporting.patch` | generic, core/iridium-browser |
| 5 | `ungoogled/generic/core/ungoogled-chromium/disable-crash-reporter.patch` | generic, core |
| 6 | `ungoogled/generic/core/ungoogled-chromium/disable-google-host-detection.patch` | generic, core |
| 7 | `ungoogled/generic/core/ungoogled-chromium/toggle-translation-via-switch.patch` | generic, core |
| 8 | `ungoogled/generic/core/ungoogled-chromium/disable-profile-avatar-downloading.patch` | generic, core |
| 9 | `ungoogled/generic/core/ungoogled-chromium/disable-gcm.patch` | generic, core |
| 10 | `ungoogled/generic/core/ungoogled-chromium/disable-domain-reliability.patch` | generic, core |
| 11 | `ungoogled/generic/core/ungoogled-chromium/disable-gaia.patch` | generic, core |
| 12 | `ungoogled/generic/core/ungoogled-chromium/disable-fonts-googleapis-references.patch` | generic, core |
| 13 | `ungoogled/generic/core/ungoogled-chromium/disable-webrtc-log-uploader.patch` | generic, core |
| 14 | `ungoogled/generic/core/ungoogled-chromium/disable-ai.patch` | generic, core |
| 15 | `ungoogled/generic/core/ungoogled-chromium/disable-network-time-tracker.patch` | generic, core |
| 16 | `ungoogled/generic/core/ungoogled-chromium/block-requests.patch` | generic, core |
| 17 | `ararat/restore-component-updater.patch` | 独自 |
| 18 | `ungoogled/generic/core/ungoogled-chromium/remove-navigation-source-param.patch` | generic, core |
| 19 | `ungoogled/generic/core/bromite/disable-fetching-field-trials.patch` | generic, core/bromite |
| 20 | `ungoogled/generic/extra/ungoogled-chromium/disable-intranet-redirect-detector.patch` | generic, extra |
| 21 | `ungoogled/generic/extra/ungoogled-chromium/fix-building-without-mdns-and-service-discovery.patch` | generic, extra |
| 22 | `ungoogled/generic/extra/ungoogled-chromium/disable-dial-repeating-discovery.patch` | generic, extra |
| 23 | `ungoogled/generic/extra/ungoogled-chromium/add-credits.patch` | generic, extra |
| 24 | `ungoogled/generic/extra/ungoogled-chromium/disable-ai-search-shortcuts.patch` | generic, extra |
| 25 | `ungoogled/macos/ungoogled-chromium/macos/disable-crashpad-handler.patch` | macos |
| 26 | `ungoogled/macos/ungoogled-chromium/macos/add-local-network-usage-description.patch` | macos |
| 27 | `ararat/remove-screenai-sandbox-parameter.patch` | 独自 |
| 28 | `ararat/link-ararat-layer.patch` | 独自 |
| 29 | `ararat/extra-parts-hook.patch` | 独自 |
| 30 | `ararat/browser-window-factory.patch` | 独自 |
| 31 | `ararat/viewless-read-anything.patch` | 独自 |

## この 25 件を選んだ理由

パッチごとの維持・スキップ・対抗パッチの判断と、セキュリティ上の帰結は `docs/research/ungoogled-inventory.md` §8 にある。

## 独自の 6 件に関する注記

`ararat/remove-screenai-sandbox-parameter.patch` は `chrome/browser/chrome_content_browser_client.cc` の sandbox パラメータから ScreenAI の分岐を削除する。`disable-ai` が ScreenAI を削除するため、この分岐を残すと `ScreenAIInstallState::GetInstance()` が未定義シンボルになり、リンクに失敗する。

`ararat/restore-component-updater.patch` は `components/update_client/update_checker.cc` にある `block-requests` の hunk だけを元に戻す。これにより component updater はネットワーク経由の更新確認を再び実行する。他の hunk はすべて有効のままとする。Google Safe Browsing もビルドに残す。`fix-building-without-safebrowsing` を取り込まず、`engine/args.gn` に `safe_browsing_mode=0` を設定しないためである（いずれの場合も API キーは設定していない）。

`ararat/link-ararat-layer.patch` は `//ararat/core` を framework の依存に追加し、`ararat.exports` をリンカに渡し、独自のシンボルを `chrome/app/framework.order` に追加する。`ararat/extra-parts-hook.patch` は `ChromeContentBrowserClient::CreateBrowserMainParts` の末尾で `g_ararat_add_browser_main_extra_parts` が設定されていれば呼び出す。未設定の場合、Chrome は標準どおりに動作する。`ararat/browser-window-factory.patch` は `Browser` のコンストラクタで独自の window factory が設定されていれば呼び出す。未設定の場合と null が返った場合は、Chrome が標準ウィンドウを生成する。location bar がないウィンドウでは、その状態の保存も省く。hook の一覧は architecture §4.3 にある。

`ararat/viewless-read-anything.patch` は、side panel のない独自の viewless ウィンドウで side panel の後処理を省く。
