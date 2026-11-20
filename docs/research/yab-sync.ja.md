# Yab の同期：データはどこにあるか

英語版は `yab-sync.md`。以下はその翻訳である。

対象は Yab のソースのコミット `5a9b57a94cdfbc9bb181b8bab26c1f0611ddf245`（読み取りのみ、`~/workspace/github.com/yetanotherbrowser/yab`）。引用はそのツリー内の `path:line` で示す。各引用は `https://github.com/yetanotherbrowser/yab/blob/5a9b57a94cdfbc9bb181b8bab26c1f0611ddf245/<path>` にもある。価格は 2026-11-20 に引用元のページから読んだ。第 7 節の費用はその価格をもとにした本稿の計算であり、推定である。

結論を先に書く。同期のデータは iCloud にはない。レコードは端末で封をされ、Yab のオーナー自身の Cloudflare アカウント上の Cloudflare Worker に保存される。iCloud が運ぶのはアカウント鍵だけで、同じ Apple ID の 2 台目の Mac はコードを入力せずに参加できる。

設計の全体は `docs/sync.md` にある。本稿は Ararat の E-Sync の判断が必要とする問いだけを扱う。数値はすべて同ファイルか、それが説明するコードから取った。第 7 節の価格だけは、そこに挙げたページから取った。

## 1. 何が同期されるか

1 項目につき 1 レコードで、`{collection, id, fields, stamps, deleted, schema}` である。各フィールドは最後の変更のスタンプを持ち、レコードはコレクションが許す場合に削除のスタンプを持つ（`Record.swift`、`docs/sync.md:13-17` に説明がある）。端末は持っている全レコードを `sync.sqlite` に、未送信の印、サーバー上の版、カーソルとともに保持する（`docs/sync.md:21-22`）。マージはフィールド単位で、新しいスタンプが勝つ。時刻はハイブリッド論理時計で、タブとペアだけは削除がすべてに優先する（`docs/sync.md:14-17`、`docs/sync.md:861-864`）。

コレクション（`docs/sync.md:262-367`）は 5 つの組に分かれる。

| 組 | 運ばれるもの |
|---|---|
| ワークスペース | `space`、`tab`、`folder`、`pair`、`bookmark`（`docs/sync.md:274-278`） |
| 設定と小さなファイル | `setting`、`file`、`icon`、`answer`（`docs/sync.md:279-281`、`docs/sync.md:286`） |
| 秘密 | `login`、`code`、`card`、`address`。キーチェーンを写したもので、各秘密はさらに二重に封をされる（`docs/sync.md:282-285`、`docs/sync.md:368-376`） |
| 拡張 | `extension`、`plugin`、`pluginpart`。この Mac が最後に合意した内容の台帳を伴う（`docs/sync.md:298-300`、`docs/sync.md:403-430`） |
| 端末間 | `routine`、`memory`、`visit`、`chat`、`chatitem`、`project`、`send`、`sendpart`、`commandcap`、`taskcommand`、`task`、`now`、`assistant*` の 5 つ（`docs/sync.md:287-297`、`docs/sync.md:301-306`） |

意図的に送らないもの:

- メインウィンドウ以外のウィンドウ、プライベートのタブ、エージェントのタブ。14 日より古い履歴。14 日間更新がなく、ピン留めもされていないチャット（`docs/sync.md:578-583`）。
- Gmail に関するものすべて。メールを読み込んだチャット、メールが書いた記憶、メールの一覧と抜粋、メールのログイン手順の履歴（`docs/sync.md:599-604`）。
- 各端末の「Today」の行。Today のタブは開いた端末の id を持ち、他の端末は自分の行だけを描く（`docs/sync.md:606-648`）。

## 2. サーバー

1 つの Cloudflare Worker `yab-sync` があり、その Durable Object がデータを持つ（`sync-server/wrangler.jsonc:1-23`、`sync-server/README.md:1-8`）。束ねられているのは `Account`、`Pairing`、`PushBox`、`Directory`、`Host`、`Counts` の 6 クラス（`sync-server/wrangler.jsonc:7-16`）で、いずれも SQLite のストレージを使う（`sync-server/wrangler.jsonc:17-22`）。同期に関わるのは `Account` と `Pairing` だけである。`Directory` と `Host` はクラウド側のアシスタント、`PushBox` はサイト向けの Web Push、`Counts` はサイトの管理画面向けの集計に属する（`sync-server/src/index.ts:20-45`、`sync-server/README.md:15-24`）。

接続先:

- 環境変数の `YAB_SYNC_URL`、次に `Info.plist` の `YabSync`、最後に `https://yab-sync.21st.workers.dev`（`Sources/Fast/SyncCenter.swift:267-274`、`docs/sync.md:177-181`）。この既定値はオーナー自身の Cloudflare アカウントで、`sync-server/` から `npx wrangler deploy` で配備されている。
- アカウントのリクエストは、アカウント id を名前にした `Account` オブジェクトへ行く。ペアリングは全員で 1 つの `Pairing` オブジェクトへ行く（`sync-server/src/index.ts:27-43`）。

アカウントごとに、オブジェクトはレコード 1 件につき 1 行を持つ。封をされた名前、版、連番、封をされた本体、その大きさ、変更時刻である。加えて端末の一覧を、ハッシュ化したトークン、最終確認時刻、プレゼンス、プッシュの登録とともに持つ（`sync-server/src/account.ts:64-96`）。

プロトコルの概略（`docs/sync.md:153-261`）:

- 端末の登録、端末一覧、失効、ペアリングの箱、アカウントの削除は HTTP（`docs/sync.md:183-228`）。
- 端末ごとに WebSocket を 1 本。カーソル付きの `hello`、最大 500 レコードかつ 4 MB のまとめた追いつき、その後の他端末の変更の即時配信、端末ごとの `presence` を他の端末へ中継する処理、競合を返す `pushed` の応答（`docs/sync.md:229-261`、`sync-server/src/account.ts:24-27`）。
- 書き込みは、端末が最後に持っていた版を添える。それがサーバーの版と一致しなければ、サーバーは現在の本体を競合として返し、書き込みを受け付けない（`docs/sync.md:236-239`、`sync-server/src/account.ts:444-465`）。つまりサーバーは権威ある版の番号を持つだけで、マージの場ではない。

上限: 本体は base64 で 96 KB まで、アカウントは 250 MB まで、プレゼンスは 8 KB まで、1 回の push は 500 変更まで、追いつきの 1 まとまりは 500 レコードかつ 4 MB まで（`sync-server/src/account.ts:19-27`、`docs/sync.md:255-260`）。クライアントは 1 回の push で最大 768 KB のレコードを送る（`docs/sync.md:463-466`）。

## 3. 端末間の暗号化

アカウントごとに 32 バイトの鍵 `K` が 1 つ。最初の端末で作り、どこにも送らない（`Sources/SyncKit/Seal.swift:5-8`、`docs/sync.md:50-51`）。ほかはすべて `K` からの HKDF-SHA256 で、info 文字列は 4 つ（`Sources/SyncKit/Seal.swift:12-18`、`Sources/SyncKit/Seal.swift:56-58`、`docs/sync.md:53-58`）。

| 導出されるもの | 何になるか |
|---|---|
| レコード鍵（`yab sync records v1`） | 各レコードの AES-GCM。サーバー上の名前を付加データにする（`Sources/SyncKit/Seal.swift:40-46`） |
| 名前鍵（`yab sync names v1`） | `collection` NUL `id` の HMAC-SHA256 を base64url にしたもの。サーバー上のレコード名になる（`Sources/SyncKit/Seal.swift:33-37`） |
| アカウント id（`yab sync account v1`、16 バイト） | サーバー上のアカウントのアドレス（`Sources/SyncKit/Seal.swift:88-92`） |
| 認証の秘密（`yab sync auth v1`） | 端末が `K` を持つことの証明。サーバーはその SHA-256 だけを持つ（`Sources/SyncKit/Seal.swift:94-98`、`sync-server/src/account.ts:186-190`） |

レコードの中のパスワード、カード番号、住所は、`yab sync secrets v1` から導いた鍵でさらにもう一段封をされる。付加データはそのレコード自身の鍵である。したがってディスク上のジャーナルには、`K` なしで開けるものが残らない（`Sources/SyncKit/Seal.swift:60-76`、`docs/sync.md:368-376`）。

**サーバーが見えるもの。** アカウントごとのレコード数、その大きさ、版、変更時刻。端末一覧と、各端末の名前、機種、最終確認時刻、プッシュのトークン、失効したかどうか。プレゼンスの本体（それ自体も封をされている。`sync-server/src/account.ts:68-80`、`docs/sync.md:844-846`）。そして通信そのもの。Yab のプライバシーのページにも、サーバーはレコードの数と大きさと変更の時刻が見えると書いてある（`docs/privacy.md:19`）。レコードの中身、コレクション、id、タブのアドレスは読めない。アカウント id が鍵のハッシュだから、誰なのかも分からない（`Sources/SyncKit/Seal.swift:88-92`）。

**暗号化が覆わないもの。** レコードに、サーバーが偽造できない署名は付かない。古い封をされたレコードを残したサーバーは、それを再び配ることができる。たとえば削除前のプラグインのレコードである。新しく参加した端末は、それより新しいものを持っていなければ、受け入れてしまう（`docs/sync.md:544-549`）。設計が頼っているのは版の番号と、端末がより新しいレコードを見ていることであり、誰が書いたかではない。

端末の削除はトークンを即座に失効させるが、その端末は `K` を今も知っている。確実にする方法は Remove and Change Key で、新しい `K`、新しいアカウントを作り、他の端末を古いアカウントの下の封をした通知で移す（`docs/sync.md:148-151`）。

## 4. iCloud が担うもの

鍵だけである。Mac は 2 つの写しを持つ。この Mac が同期していることを示すローカルのキーチェーン項目と、iCloud キーチェーンにある同期可能な汎用パスワード項目で、後者は同じ Apple ID の新しい Mac が自分で見つける（`Sources/Fast/SyncKey.swift:6-11`、`Sources/Fast/SyncKey.swift:18-32`、`Sources/Fast/SyncKey.swift:51-66`）。後者が無い場合（その権利で署名されていないビルド、または別の Apple ID）は、コードかリカバリキーが同じ役目を果たす（`docs/sync.md:92-111`）。

挙げておくべき帰結:

- 同期を入れるときは、共有された鍵を 6 秒探す。見つからなければ「最初の端末か」と尋ねる。iCloud キーチェーンは数秒から数分遅れることがあり、その間に作った鍵は同じ人の 2 つ目のアカウントになってしまうからである（`docs/sync.md:60-66`）。
- iCloud キーチェーンを使う権利がないビルドは、単に 2 つ目の写しを持たない。これは異常ではなく通常の状態である（`Sources/Fast/SyncKey.swift:10-11`）。
- タブ、ブックマーク、パスワード、チャットが iCloud Drive や CloudKit に置かれることはない。iCloud が使えなくても同期は続き、同じ Apple ID の新しい Mac が自動で参加することだけができなくなる。

## 5. ペアリングと 2 つの Apple ID

アカウントは鍵そのものである。メールアドレスもパスワードも無く、`K` を持つ者がアカウントである（`docs/sync.md:92-93`）。

- **同じ Apple ID:** 2 台目の Mac は iCloud キーチェーンから鍵を読み、何も入力せずに参加する（`docs/sync.md:95-96`）。
- **別の Apple ID:** Settings › Sync › Add a Device が 8 文字（0・O・1・I・L を除く 31 種の英数字）と `yab://join/ABCD-EFGH` の QR を出す。他の端末はそれを入力するか読み取る（`Sources/SyncKit/Seal.swift:196-203`、`docs/sync.md:101-108`）。
- **コードはサーバーに届かない。** コードは PBKDF2-SHA256 の 300,000 回、ソルト `yab sync pairing v2` で引き延ばされる。その HKDF から、箱の名前、投稿された X25519 鍵に付けるタグの鍵、封筒の鍵のソルトが出る（`Sources/SyncKit/Seal.swift:213-229`、`Sources/SyncKit/Seal.swift:141-168`）。アカウントに入っている端末が、新しい端末の使い捨ての鍵へ `K` を封じる。両方の画面が鍵とコードから作った 4 桁を出し、人が一致を確認してから封をする（`docs/sync.md:109-115`）。
- 箱は 10 分だけ残り、封筒は最大 20 回まで読める（`docs/sync.md:223-224`）。
- **1 つの Apple ID に 2 つのアカウント:** すでに同期している Mac は、自分の鍵と iCloud の鍵を比べ、違えばそう表示する。参加に数字は要らない。2 つのアカウントが出会ったときは端末の多いほうが残り、全端末が封をした `accountmove` レコードで移る（`docs/sync.md:68-92`）。

ペアリングの話が同期を 1 人に閉じないのはこのためである。別の Apple ID の 2 人は、1 つの Apple ID の 2 台の Mac と同じようにアカウントを共有する。

## 6. プッシュ

端末がソケットを開いていない間に、他の端末から受け付けた変更は、その端末へ静かな APNs のプッシュを送る（`content-available`、優先度 5、まとめられる）。頻度は 1 分に 1 回まで（`docs/sync.md:206-214`）。人への問いには独自の経路があり、問いと宛先ごとに 1 回だけ、2 日の重複排除の窓を持つ（`docs/sync.md:902-913`）。これにはチームの APNs 鍵が Worker の秘密に要る。無ければ何も送られない（`docs/sync.md:209-211`、`sync-server/src/env.d.ts:11-16`）。

このコミットの時点でオーナーは APNs 鍵を持っていない。したがってバックグラウンドの iPhone を起こすものは無く、ページや依頼は回線が開いたときに届く（`docs/sync.md:785-789`）。Mac にプッシュは要らない。Yab が動いている間はソケットが開いており、残りはカーソルによる追いつきが覆う。

## 7. 第三者が運用できるか

**ライセンス。** できる。Yab のソースは `sync-server/` を含めて Apache-2.0 である（`LICENSE:1-2`）。写し、変更し、配備できる。ライセンスと NOTICE を伴わせ、変更を明記することが条件である。名前と標識は許諾されない。「Yab」、ロゴ、アプリアイコンは Yab のものであり続ける（`TRADEMARKS.md:1-10`）。配備には独自の名前が要る。

**設定。** Cloudflare のアカウントと node があれば足りる。外部のデータベース、オブジェクトストア、メッセージキューは無い。`npx wrangler deploy` で公開でき、Durable Object のクラスと SQLite のマイグレーションは `wrangler.jsonc` に宣言してある（`sync-server/README.md:57-62`、`sync-server/wrangler.jsonc:17-22`）。秘密は任意である。iPhone へのプッシュには `APNS_KEY`、`APNS_KEY_ID`、`APNS_TEAM`（`sync-server/README.md:64-77`）。`CENSUS_TOKEN` は集計の経路だけを制御し、無ければ 404 を返す（`sync-server/src/index.ts:22-25`）。

**クライアント側。** サーバーのアドレスはプロトコルに埋め込まれていない。`YAB_SYNC_URL` か `Info.plist` の `YabSync` で、ビルドを別の配備へ向けられる（`Sources/Fast/SyncCenter.swift:267-274`）。ただしこれが効くのは Yab 自身のクライアントに対してである。独自のブラウザを持つ第三者は、文書化されたプロトコル（`docs/sync.md:153-261`）に対して自分のクライアントを書くことになる。

**費用（推定）。** 2026-11-20 に、Cloudflare の Workers の価格ページ（最終更新 2026-11-18）と Durable Objects の価格ページ（最終更新 2026-11-13）から読んだ。

| 項目 | 無料 | 有料 |
|---|---|---|
| Workers のリクエスト | 1 日 100,000 | 月 $5 から、1,000 万まで含む、超過は 100 万あたり $0.30 |
| Durable Object のリクエスト | 1 日 100,000 | 月 100 万まで含む、超過は 100 万あたり $0.15 |
| Durable Object の実行時間 | 1 日 13,000 GB-s | 月 400,000 GB-s まで含む、超過は 100 万 GB-s あたり $12.50 |
| SQLite の行の読み書き | 読み 1 日 500 万 / 書き 1 日 100,000 | 読み 月 250 億 / 書き 月 5,000 万まで含む、超過は 100 万行あたり $0.001 と $1.00 |
| SQLite の保存量 | 全体で 5 GB | 月 5 GB まで含む、超過は 1 GB あたり $0.20 |

家庭規模の配備（5 人、15 端末、回線は 1 日 8 時間開く）での本稿の計算:

- 定常的な負荷はプレゼンスである。回線が開いている間は 55 秒ごと（`docs/sync.md:793-795`）なので、1 端末 1 日あたり約 1,600 メッセージ。Cloudflare は受信の WebSocket メッセージを請求上 20 分の 1 に数えるので、15 端末で月に約 36,000 リクエストになる。有料の月 100 万、無料の 1 日 100,000 に対して十分小さい。
- 実行時間はほぼ 0 である。ソケットは Hibernation API を使い、ハンドラが終わると時計が止まる（`sync-server/README.md:7-8`、`sync-server/src/account.ts:310`）。ハイバネーションが無ければ、同じ 15 端末が 5 つのアカウントのオブジェクトを 1 日 8 時間開いたままにし、月に約 550,000 GB-s になる。含まれる 400,000 を超え、およそ $2 の追加になる。
- 保存量: アカウントは 250 MB まで（`sync-server/src/account.ts:22`）。5 つが満杯でも含まれる 5 GB に収まる。
- 書き込み: 受け付けた変更 1 件につき 1 行で、月 5,000 万行には遠い。

したがって家庭規模の配備は、無料の計画なら $0、有料の計画なら月 $5 で、この規模では超過しない見込みである。Cloudflare の外に 2 つの費用がある。

- iPhone の静かなプッシュには Apple Developer Program の会員資格が要り、年 $99 である（2026-11-20 に `developer.apple.com/programs/` から読んだ）。Mac だけの同期には要らない。現在の Yab がそのとおりである。
- `workers.dev` にドメインは要らない。独自ドメインはここでは価格を調べておらず、この規模の配備にも要らない。

後から読む人のために、ツリーが自らと食い違っている点を 2 つ挙げる。`docs/sync.md:255-256` と `sync-server/src/account.ts:22` はアカウントの上限を 250 MB とするが、`sync-server/README.md:83` は 50 MB と書いている。また `docs/sync.md:5-6` は計画の文書として `PLAN-sync.md` を指すが、このコミットのツリーには無い。

## 8. Ararat の E-Sync の判断に向けて

mock の決定では、ペインは計画どおりのまま、同期は phase 8 で、サーバーの置き場所は未決定である（設計セッションの `reports/design-u20` にある `mock-decisions.md:100`）。Ararat 自身の設計はすでに 2 点で Yab より厳しい。署名した blob と端末ごとの鍵、削除時に始める epoch であり、どちらもリカバリフレーズの下にある（`docs/architecture.md:393-412`）。保存は Rust のリレーが SQLite か S3 互換のストアで行う（`docs/architecture.md:426-428`）。同期するコレクションも少ない。ワークスペース、経路の規則、キーの割り当て、設定、パスワード、拡張である（`docs/architecture.md:422-424`）。Yab はチャットと、電話から Mac を操作するコマンドまで運ぶ（`docs/sync.md:290-306`）。以下は 3 つの案について、何が得られ何が要るかを書き、推奨はしない。

**A. Yab の設計を自前の Worker で使う。** 見えない名前の下に封をしたレコード、アカウントごとに 1 つの共有対称鍵、版の番号だけを持つリレー、引き延ばしたコードかフレーズでの参加、鍵を運ぶのは iCloud キーチェーンかコード。

- 得られるもの: 動いていて文書化されたプロトコルと、Yab がそれに対して出荷しているクライアント（Mac と iPhone）。アカウントの仕組みが不要。家庭規模で月 $0〜5 のサーバーで、運用するデータベースが無い。マージの規則はコレクションごとに書き切ってあり、こちらで発明するものが無い。
- 要るものと限界: Cloudflare に固有である（Durable Object、WebSocket、オブジェクト内の SQLite）。書き直さない限り他へは移せない。端末ごとの署名が無いので、リレーは古いレコードを再送したり巻き戻したりできる（`docs/sync.md:544-549`）。Ararat の §8.2 はこれを要求しており、Yab の設計は明示的に行わない。削除は epoch を始めるのではなく、全端末を新しいアカウントへ移す（`docs/sync.md:148-151`）。鍵の既定の運び手である iCloud キーチェーンは Apple のプラットフォームにしか無く、Windows と Linux はコードとフレーズの経路に残る（`Sources/Fast/SyncKey.swift:6-11`）。
- ライセンスは両立する。Apache-2.0 のコードは、Yab の告知を残したまま、GPL-3.0 のこのリポジトリへ取り込める（`LICENSE:1-2`、`TRADEMARKS.md:1-10`）。

**B. iCloud と CloudKit。** Apple 自身のストアを使い、アカウントはその人の Apple ID とする。

- 得られるもの: 自前で動かすサーバーが無い。アプリの他の部分がすでに使っているのと同じサインインである。
- 限界: Apple のプラットフォームに限られ、利用者全員に iCloud のアカウントが要る。ストアは我々のプロトコルの外にあるので、ワークスペースのモデル、マージの規則、パスワードの二重の封を、CloudKit 自身のレコードと競合のモデルへ写す必要がある。CloudKit の暗号化フィールドがそれを覆うかはここでは確認していない。CloudKit のコンテナが Apple Developer の会員資格に結び付くことも確認していない。Windows と iPhone に同じように届くという設計の前提とも合わない（`docs/architecture.md:430-435`）。

**C. 何もしない。** phase 8 に同期を置かない。

- 得られるもの: その段階にかかる費用と、サーバーの置き場所の判断が消える。サイドバー、iPhone のアプリ、エンジンの成果は単独で成り立つ。
- 失うもの: 端末をまたぐタブ、ブックマーク、パスワード、拡張、チャットが無くなる。iPhone のアプリは Mac の space を見る手段を失う。mock の Sync のペイン（`mock-decisions.md:100`）は取り下げになる。

決めるのはオーナーである。
