# Default destination メニューの診断

implementation-8 の静的調査では、(a) メニューが開かない、(b) 項目名が異なる、(c) 項目が無効、(d) binding が反映されない、のいずれかを特定できなかった。両 destination Picker は `SettingsAirTrafficSection.pickerContext` を使用し、同じ `DestinationChoice.mostRecent` tag と `Most Recent Space` ラベルを定義している。default の binding は `AirTrafficModel.setDefault` を呼び出す。ただし、これらのコードから VM の native menu の実際の状態は確定できない。

check は phases 8〜10 に tracking を開始する全メニューを記録する。記録対象は項目名、enabled/hidden、選択状態、ハイライトである。action observer は各通知の採否と理由、選択した index、action の実行前後を記録する。default popup のクリックを post できたかも記録する。記録は stdout の `atc_menu_trace` と timeout diagnostics の `details.atc_menu_trace` に出力する。

action の条件は、項目名の完全一致、表示中、有効、separator 以外のままであり、native menu tracking 中に実行する。setter fallback と製品コードの変更は追加していない。独立した observer が一度限りの action observer の解除後も記録を続け、check の解放時に解除される。

次の design による VM 実行で、記録から原因を判別する必要がある。この調査ではホストのアプリと VM を起動していない。既存の `engine/patch-state.sha256` の変更と `docs/HANDOVER.md` は変更対象外である。

検証では Xcode の `DEVELOPER_DIR` と `SDKROOT` を明示し、全件の `swift test --no-parallel` が成功した。PromptFixtureTests 152 件、UI テスト 653 件、計 805 件、失敗 0 件である。両テストプロセスの window guard は画面上のウィンドウが存在しないことを確認した。ログは `/tmp/atcfield-10-swift-test.log` にある。新規テスト 1 件で phase による記録制限、選択状態等のシリアライズ、observer の拒否理由を検証した。既存の両 destination の action テストには採用・action の trace 検証を追加した。`git diff --check` も成功した。
