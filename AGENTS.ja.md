# Ararat

この文書は `AGENTS.md` の日本語訳である。agent が読むのは英語版で、内容が食い違うときは英語版に従う。

Arc の操作感と Yab の縦タブを Chromium の上に作る macOS ブラウザ。UI は Swift（AppKit）。エンジンは Chromium の fork で、自前の層を tree の中に組み込む（Dia の ArcCore、Ardia の ArdiaCore と同じ方式）。OS をまたぐ中核は Rust。Windows・Linux・iPhone は後で対応するが、構成は最初からそれを前提にする。設計は `docs/architecture.md`。

## 言語

repo の中のファイル（README、AGENTS.md、`docs/` の下すべて、コードのコメント、commit message）は、ファイルに別の指定がない限り英語で書く。正本は英語のファイルである。Markdown の文書には、日本語訳を `<名前>.ja.md` として隣に置き（`README.ja.md`、`docs/architecture.ja.md`）、英語版と同じ変更で更新する。毎セッション上書きする作業用のメモ（`docs/HANDOVER.md`、`docs/reviews/PENDING.md`）と、レビュアーの出力そのもの（`docs/reviews/*-codex.md`）には日本語訳を置かない。

## 作業の進め方（サンドイッチ）

作業の 1 単位ごとに、design、orchestrator、implementation、review の席で分担する。

1. 範囲と設計: Claude を使う。作るもの、触るファイル、不変条件、境界の場合を書く。orchestrator も Claude の席である。
2. 実装: 2 つの席を別々の worktree で並べて動かす。1 つは personal アカウントの Codex、もう 1 つは OpenCode Go の席である。personal の Codex の週枠が尽きたときは、OpenCode の席でできる作業だけを続け、枠の復帰を待つ。難しい作業（engine の変更、入力とイベントの処理、境界の不具合、review で 2 回差し戻されたもの）は Codex の席に、仕様が決まった機械的な作業（文書、check の一覧、小さな UI の修正）は OpenCode の席に回す。Codex は `CODEX_HOME=$HOME/.codex-personal` を使い、Ararat では labteam を使わない。
3. レビュー: Claude を使う。指摘ごとに、直すか直さないかとその理由を決め、直すものを 2 に戻す。

各席のモデルと effort は、ここではなくチームの設定 `~/.config/herdr-agent-team/ararat.json` で決める。

際どい境界の不具合では順序を逆にする。implementation が調べ、design がセカンドオピニオンを出し、implementation が修正し、review が確認する。

計測と設計の段階の作業（研究ノート、`docs/architecture.md`）は、オーナーが頼まない限りレビューを要しない。

席は、Orca の中の Codex のセッションからは orca-agent-team（役割ごとに Orca のタブ 1 つ）で、herdr の中のセッションからは herdr-agent-team で動かす。agent は、dotfiles の agent-switch の shim から devshell を得る。shim は、repo で `claude` か `codex` が起動するときに direnv を読み込む。`command -v cargo` が `/nix/store` を指さないときは、別のツールチェーンでビルドせず、repo から agent を起動し直す。2 つ目のツールチェーンは同じ `target/` に書き込むためである。

## 先行実装

- Ardia（`mantrakp04/ardia`）: Chromium の fork と自前の層。配布物のアプリは GPL-3.0、Ardia 自身のソースファイルは Apache-2.0 である（同梱の NOTICE）。どちらもこの GPL-3.0 の repo に流用してよい。流用したファイルには出典を残す。Apache-2.0 のコードは、Ardia の著作権表示を残し、`third_party/ardia/LICENSE.Apache-2.0` を示し、変更点を書く。`third_party/ardia/` には LICENSE・LICENSE.Apache-2.0・NOTICE を置き、アプリに同梱する
- Cra（`VictorKildahl/cra`、MIT）: Swift + CEF。UI の実装の参考
- Yab（`yetanotherbrowser/yab`、2026-11-14 から Apache-2.0。clone は `~/workspace/github.com/yetanotherbrowser/yab`）: Swift。既定は WebKit で、Chromium は helper のプロセスの CEF で動かす（`docs/chromium-*.md`）。同じものを両方が作っているときは、2 つの実装を突き合わせて質の良い方を取り込む。動きの値はこれまでどおり Arc の計測に従う。Arc の実測がない項目は Cra と Yab の値を比較し、採用する値とその理由を設計資料に記録する。Apache-2.0 のコードは GPL-3.0 のこの repo に流用してよい。流用したファイルには Yab の著作権表示とライセンスと変更点を残し、Yab の NOTICE をこの repo の notice に引き継ぐ。名前・ロゴ・アプリのアイコンは商標で、同梱の Central Icon System のアイコンは別のライセンスなので、写さない
- Arc・Dia: 非公開。公開されている解析結果と、規約が許す範囲の静的な解析だけを使う。コードや素材は写さない
- 調査の記録は `docs/research/`
- REA（`morluto/rea`）で解析するときは、npm の配布物（`npx rea-agents`）ではなく、repo を clone して使う。node は devshell に閉じる
