1. **Major — [docs/architecture.md:260](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/architecture.md:260)：現在のフレーズだけでは復旧用 blob を取得できない。**  
   **問題:** 復旧用 blob の読み出し認可が循環している。  
   **根拠:** 254 行では relay key を epoch secret から導出し、258 行ではその資格情報をすべての読み出しに要求する。端末をすべて失った復旧者は、260 行の blob を復号するまで epoch secret を持たず、取得資格情報を導出できない。フレーズから独立に認証できる復旧経路と、新しい端末鍵の登録権限を規定する必要がある。日本語版 262 行も同じ問題を含む。

2. **Major — [docs/architecture.md:237](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/architecture.md:237)：`no phase` だけではホイールを識別できない。**  
   **問題:** 規則を `phase == .none` で実装すると、トラックパッドの慣性にもホイール用の符号反転と休止を適用してしまう。  
   **根拠:** AppKit の慣性イベントは `phase == .none`、`momentumPhase != .none` である。[Apple の仕様](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html)に従い、両方が `.none` の場合をホイールとして扱い、慣性中も同じジェスチャーの切り替え済み状態を保持する必要がある。現状は「慣性を含め最大 1 space」と競合する。日本語版 239 行も同様。

3. **Moderate — [docs/research/arc-ardia-observed.md:61](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/research/arc-ardia-observed.md:61)：休止機構の断定が計測結果より強い。**  
   **問題:** 切り替え回数から「切り替え後約 300 ms の入力を無視する」「Yab には休止がない」とまでは確定できない。  
   **根拠:** 合成ストリームは常に 30 ms 間隔なので、経過時間と累積入力が同時に増える。回数だけでは時間による抑制と入力蓄積などを区別できず、63 行も休止の起点を未計測としている。Yab の結果が排除するのも同じ約 300 ms の抑制であり、あらゆる休止ではない。§7 はこの推定を計測済み規則として採用している。日英とも、観測結果と機構の仮説を分ける必要がある。

4. **Minor — [docs/research/arc-ardia-observed.md:61](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/research/arc-ardia-observed.md:61)：16 イベントの終端時刻が生成コードと一致しない。**  
   **問題:** 12 または 16 イベントの最後をともに約 330 ms と記載している。  
   **根拠:** [scroll.swift:24](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/research/yab/scroll.swift:24) は各イベントを 30 ms 間隔で送る。先頭を 0 ms とすると、12 イベント目は約 330 ms、16 イベント目は約 450 ms になる。日本語版 61 行も同じ誤りを含む。

5. **日英の意味的一致：no findings。** 指定範囲の問題は両言語に共通している。

6. **§8.2 の削除後の鍵秘匿性：no findings。** 新しい group secret と epoch secret を削除端末に渡さない前提では、復旧用の封緘を追加しても削除保証は崩れない。ただし、フレーズだけでの復旧は指摘 1 により成立していない。

ファイル変更・実機での再計測は未実施。元のイベント記録が repo にないため、計測値自体の再検証は行っていない。