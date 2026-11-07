# Ararat

この文書は `AGENTS.md` の日本語訳である。agent が読むのは英語版で、内容が食い違うときは英語版に従う。

Arc の操作感と Yab の縦タブを Chromium の上に作る macOS ブラウザ。UI は Swift（AppKit）。エンジンは Chromium の fork で、自前の層を tree の中に組み込む（Dia の ArcCore、Ardia の ArdiaCore と同じ方式）。OS をまたぐ中核は Rust。Windows・Linux・iPhone は後で対応するが、構成は最初からそれを前提にする。設計は `docs/architecture.md`。

## 言語

repo の中のファイル（README、AGENTS.md、`docs/` の下すべて、コードのコメント、commit message）は、ファイルに別の指定がない限り英語で書く。正本は英語のファイルである。Markdown の文書には、日本語訳を `<名前>.ja.md` として隣に置き（`README.ja.md`、`docs/architecture.ja.md`）、英語版と同じ変更で更新する。毎セッション上書きする作業用のメモ（`docs/HANDOVER.md`、`docs/reviews/PENDING.md`）と、レビュアーの出力そのもの（`docs/reviews/*-codex.md`）には日本語訳を置かない。

## 作業の進め方（サンドイッチ）

作業の 1 単位ごとに、design、orchestrator、implementation、review の席で分担する。

1. 範囲と設計: Codex の `gpt-6.1-terra`、effort high、personal アカウントを使う。作るもの、触るファイル、不変条件、境界の場合を書く。orchestrator も同じモデル、effort、アカウントを使う。
2. 実装: 2 つの席を別々の worktree で並べて動かす。1 つは Codex の `gpt-6.1-terra`、effort high、personal アカウント、もう 1 つは GLM-5.3-Flash、effort max、OpenCode Go（`opencode-go/glm-5.3-flash`）を使う。Go の quota が尽きたときだけ `opencode/glm-5.3-flash-free` を使う。personal の Codex の週枠が尽きたときは、GLM でできる作業だけを続け、枠の復帰を待つ。Codex は `CODEX_HOME=$HOME/.codex-personal` を使い、Ararat では labteam を使わない。
3. レビュー: Codex の `gpt-6.1-sol`、effort high、personal アカウントを使う。指摘ごとに、直すか直さないかとその理由を決め、直すものを 2 に戻す。

際どい境界の不具合では順序を逆にする。implementation が調べ、design がセカンドオピニオンを出し、implementation が修正し、review が確認する。

計測と設計の段階の作業（研究ノート、`docs/architecture.md`）は、オーナーが頼まない限りレビューを要しない。

席は、Orca の中の Codex のセッションからは orca-agent-team（役割ごとに Orca のタブ 1 つ）で、herdr の中のセッションからは herdr-agent-team で動かす。agent は、dotfiles の agent-switch の shim から devshell を得る。shim は、repo で `claude` か `codex` が起動するときに direnv を読み込む。`command -v cargo` が `/nix/store` を指さないときは、別のツールチェーンでビルドせず、repo から agent を起動し直す。2 つ目のツールチェーンは同じ `target/` に書き込むためである。

## 先行実装

- Ardia（`mantrakp04/ardia`、GPL-3.0）: Chromium の fork と自前の層。この repo も GPL-3.0 なので、コードを流用してよい。流用したファイルには出典を残す
- Cra（`VictorKildahl/cra`、MIT）: Swift + CEF。UI の実装の参考
- Arc・Dia・Yab: 非公開。公開されている解析結果と、規約が許す範囲の静的な解析だけを使う。コードや素材は写さない
- 調査の記録は `docs/research/`
- REA（`morluto/rea`）で解析するときは、npm の配布物（`npx rea-agents`）ではなく、repo を clone して使う。node は devshell に閉じる。Yab の規約（2026-09-30 版）は lawful な利用を認め、解析を禁じる条項は無い
