# Ararat

この文書は `AGENTS.md` の日本語訳である。agent が読むのは英語版で、内容が食い違うときは英語版に従う。

Arc の操作感と Yab の縦タブを Chromium の上に作る macOS ブラウザ。UI は Swift（AppKit）。エンジンは Chromium の fork で、自前の層を tree の中に組み込む（Dia の ArcCore、Ardia の ArdiaCore と同じ方式）。OS をまたぐ中核は Rust。Windows・Linux・iPhone は後で対応するが、構成は最初からそれを前提にする。設計は `docs/architecture.md`。

## 言語

repo の中のファイル（README、AGENTS.md、`docs/` の下すべて、コードのコメント、commit message）は、ファイルに別の指定がない限り英語で書く。正本は英語のファイルである。Markdown の文書には、日本語訳を `<名前>.ja.md` として隣に置き（`README.ja.md`、`docs/architecture.ja.md`）、英語版と同じ変更で更新する。毎セッション上書きする作業用のメモ（`docs/HANDOVER.md`、`docs/reviews/PENDING.md`）と、レビュアーの出力そのもの（`docs/reviews/*-codex.md`）には日本語訳を置かない。

## 作業の進め方（サンドイッチ）

設計・実装の 1 単位ごとに、次の 3 段で進める。

1. 設計・実装: Claude Opus 5.5（`claude-opus-5-5`）、effort medium
2. 詳細なレビュー: Codex の `gpt-6.1-sol`、effort medium。labteam のアカウントで動かす（起動の前に `cx labteam` で切り替える）。レビューだけを頼み、編集はさせない
3. 総合判断: Claude Opus 5.5、effort medium。レビューの指摘ごとに、直す・直さないとその理由を決め、直すものを 1 に戻す

タスクに切り分けたあとは、orca-agent-team の席（design / orchestrator / implementation / review）で回してよい。

## 先行実装

- Ardia（`mantrakp04/ardia`、GPL-3.0）: Chromium の fork と自前の層。この repo も GPL-3.0 なので、コードを流用してよい。流用したファイルには出典を残す
- Cra（`VictorKildahl/cra`、MIT）: Swift + CEF。UI の実装の参考
- Arc・Dia・Yab: 非公開。公開されている解析結果と、規約が許す範囲の静的な解析だけを使う。コードや素材は写さない
- 調査の記録は `docs/research/`
- REA（`morluto/rea`）で解析するときは、npm の配布物（`npx rea-agents`）ではなく、repo を clone して使う。node は devshell に閉じる。Yab の規約（2026-09-30 版）は lawful な利用を認め、解析を禁じる条項は無い
