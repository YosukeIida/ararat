# Ararat

この文書は `AGENTS.md` の日本語訳である。agent が読むのは英語版で、内容が食い違うときは英語版に従う。

Arc の操作感と Yab の縦タブを Chromium の上に作る macOS ブラウザ。UI は Swift（AppKit）。エンジンは Chromium の fork で、自前の層を tree の中に組み込む（Dia の ArcCore、Ardia の ArdiaCore と同じ方式）。OS をまたぐ中核は Rust。Windows・Linux・iPhone は後で対応するが、構成は最初からそれを前提にする。設計は `docs/architecture.md`。

## 言語

repo の中のファイル（README、AGENTS.md、`docs/` の下すべて、コードのコメント、commit message）は、ファイルに別の指定がない限り英語で書く。正本は英語のファイルである。Markdown の文書には、日本語訳を `<名前>.ja.md` として隣に置き（`README.ja.md`、`docs/architecture.ja.md`）、英語版と同じ変更で更新する。毎セッション上書きする作業用のメモ（`docs/HANDOVER.md`、`docs/reviews/PENDING.md`）と、レビュアーの出力そのもの（`docs/reviews/*-codex.md`）には日本語訳を置かない。

## 作業の進め方（サンドイッチ）

作業の 1 単位ごとに、Claude と Codex で分担する。Codex は閉じた論理の一貫性を保つのが得意で、Claude は緩く制約された多くの変数から信号を拾うのが得意である。そのため、Claude が範囲を決めてレビューし、Codex が実装する。

1. 範囲と設計: Claude Opus 5.5（`claude-opus-5-5`）。作るもの、触るファイル、不変条件、境界の場合を書く。
2. 実装: Codex の `gpt-6.1-sol`、effort low（オーナーの選択、2026-11-02、使用量を抑えるため。行き詰まったら medium に上げる）。labteam のアカウント（`CODEX_HOME=$HOME/.codex-labteam`）で動かす。Terra ではなく Sol を使う。OpenAI の Codex のモデルの案内は、コードには Sol を勧め、Terra を文章、画像の理解、コンピュータ操作向けとしている。
3. レビュー: Claude Opus 5.5。指摘ごとに、直すか直さないかとその理由を決め、直すものを 2 に戻す。

際どい境界の不具合では順序を逆にする。Codex が調べ、Claude がセカンドオピニオンを出し、Codex が実装し、Claude がレビューする。

計測と設計の段階の作業（研究ノート、`docs/architecture.md`）は、オーナーが頼まない限りレビューを要しない。

席は、Orca の中の Claude のセッションからは orca-agent-team（役割ごとに Orca のタブ 1 つ）で、herdr の中のセッションからは herdr-agent-team で動かす。agent は、dotfiles の agent-switch の shim から devshell を得る。shim は、repo で `claude` か `codex` が起動するときに direnv を読み込む。`command -v cargo` が `/nix/store` を指さないときは、別のツールチェーンでビルドせず、repo から agent を起動し直す。2 つ目のツールチェーンは同じ `target/` に書き込むためである。

## 先行実装

- Ardia（`mantrakp04/ardia`、GPL-3.0）: Chromium の fork と自前の層。この repo も GPL-3.0 なので、コードを流用してよい。流用したファイルには出典を残す
- Cra（`VictorKildahl/cra`、MIT）: Swift + CEF。UI の実装の参考
- Arc・Dia・Yab: 非公開。公開されている解析結果と、規約が許す範囲の静的な解析だけを使う。コードや素材は写さない
- 調査の記録は `docs/research/`
- REA（`morluto/rea`）で解析するときは、npm の配布物（`npx rea-agents`）ではなく、repo を clone して使う。node は devshell に閉じる。Yab の規約（2026-09-30 版）は lawful な利用を認め、解析を禁じる条項は無い
