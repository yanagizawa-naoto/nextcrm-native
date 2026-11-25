# Calendly予約通知の受信窓口

Macが休止・終了している間の予約作成・取消通知を、外部サーバーへ保存するサービスです。Mac側は再開時に保存済みの位置から取得します。このプロセスをMacアプリから起動する処理はありません。

受信サーバー、署名付き通信、ネイティブの予約取り込み、キーチェーン保存、Calendlyへの通知登録・解除と中断復旧、日本語設定画面と自動実行を実装しています。外部HTTPS環境と実際のCalendlyアカウントでの通しの検証は未完了です。

## 保存と認証

公開された通知本文と `Calendly-Webhook-Signature` を、設定した署名キーで検証します。元の本文バイトと時刻を使い、受信時点から前後180秒の範囲を確認します。[Calendlyの署名仕様](https://developer.calendly.com/api-docs/overview/webhooks/webhook-signatures)

対象は `invitee.created` と `invitee.canceled` です。通知には顧客名、メールアドレス、面談日時などが含まれます。[Calendlyの通知例](https://developer.calendly.com/api-docs/calendly-api/webhooks/get-sample-webhook-data)

本文と署名キーはAES-256-GCMで暗号化して、専用のSQLiteへ保存します。暗号化キーは接続用の認証キーから用途を分けて導出します。保存フォルダは他の利用者が変更できない専用フォルダ、DBは0600です。同じ本文の再送は重複登録せず、保存の確定後に受付応答を返します。本文のハッシュ、受信時刻、履歴番号、署名ヘッダーは監査と取得のために保持します。

Macは登録済みの受信窓口ID・CRM ID・応答署名・本文ハッシュ・履歴順序を検証してから取り込みます。各ページのCRM更新と取り込み位置の保存は、同じトランザクションで確定します。Macが休止していた日数は、保存済み通知を失効させる理由にはなりません。署名を確認した受信窓口からの応答を認証して、保存済みの本文を取り込みます。

## 実行

追加パッケージは使いません。既存のNode v25.2.1と`node:sqlite`で検証しています。受信サーバーを外部環境で起動し、HTTPSのリバースプロキシから接続してください。内部待ち受けは `127.0.0.1` です。

| 環境変数 | 内容 |
| --- | --- |
| `NEXTCRM_CALENDAR_RELAY_DATABASE` | 専用SQLiteファイルの絶対パス |
| `NEXTCRM_CALENDAR_RELAY_AUTH_KEY` | 32バイトの乱数をBase64URLの43文字で表した接続キー |
| `NEXTCRM_CALENDAR_RELAY_BASE_PATH` | 公開URLのパス部分。例 `/crm`。ルートなら空文字 |
| `PORT` | 内部HTTPポート。省略時8788 |

```sh
node desktop/calendar-relay/relay.cjs
```

DBを復元するときは、同じ認証キーを使ってください。認証キーを紛失すると、保存した通知と署名キーを復号できません。異なるキーで既存DBを開く操作はエラーになります。DBとキーのバックアップ・管理が必要です。サーバーの契約・導入・公開はこの変更では行っていません。

## 公開経路

- `POST /api/crm/calendar/webhooks/calendly`：署名を検証して予約通知を保存します。
- 登録ごとの識別用に `?subscription=UUID` を付けたPOSTも受け付けます。他のクエリーは拒否します。識別子は認証情報ではなく、どちらの経路でも本文の署名検証が必要です。
- 同じ経路の `GET ?check=ready&clientId=UUID`：ネイティブ用認証付きの疎通確認です。通知の登録は行いません。

上記の前に `BASE_PATH` が付きます。無効な署名は401、保存に失敗した場合は503です。署名済みでも、無関係なイベントや必須情報の欠けた本文は200で受け付け、CRMへの取り込み対象から除きます。通知は1件ずつ処理し、元の本文を省略せず保存します。旧版にあった1 MiBの本文上限は設けていません。非常に大きい1件では一時的なメモリ使用量が増え、空き容量や実行環境の制約で処理に失敗することがあります。失敗時は受付成功として返しません。履歴の保持・削除設定は未実装で、現在は自動削除しません。

## ネイティブ通信 v1

リクエストには新しいUUIDの `X-NextCRM-Nonce`、整数秒の `X-NextCRM-Timestamp`、Base64形式の `X-NextCRM-Signature` を付けます。署名はHMAC-SHA256です。入力は次の文字列に元の本文バイトを続けたものです。`\n` は実際の改行です。

```text
nextcrm-calendar-v1-request\nMETHOD\nRAW_PATH_AND_QUERY\nTIMESTAMP\nNONCE\nRAW_BODY
```

時刻差は前後300秒までです。認証済みnonceの再使用は409です。応答の署名入力は次の通りです。

```text
nextcrm-calendar-v1-response\nREQUEST_NONCE\nHTTP_STATUS\nRAW_RESPONSE_BODY
```

認証に成功したAPI応答はエラーも署名します。APIキーなどの認証情報を含むURL、平文HTTPの外部接続、自動リダイレクトはMac側で許可しません。ローカル検証だけはループバックHTTPを明示的に有効にしています。

| API（`/api/native-calendly/v1/` の後） | 内容 |
| --- | --- |
| `GET health` | 受信窓口ID、接続済みCRM ID、履歴末尾、署名設定の世代とハッシュ |
| `POST bind` | `{clientId}`。初回のみ接続。別のCRMへの付け替えは409 |
| `POST signing-key` | `{clientId, signingKey, expectedGeneration}`。初回の世代はnull。設定の競合は409。同じキーの再送は同じ世代を返す |
| `GET events?clientId=UUID&after=N` | 番号順で最大100件、通常は2 MiB以内。1件だけでこの量を超える場合は、その1件を完全な形で返します。Base64本文、SHA256、元の署名、受信日時、次の位置を返す |

署名キーを変更すると、新たに届く通知には新しいキーを使います。変更前に受信済みの本文は保持し、そのまま取得できます。Mac側は以前の通知登録を削除できたことを確認してから、受信窓口のキーを設定し、新しい通知登録を作成します。認証情報や署名キーをログへ出力しないでください。

## Mac側の通知登録

APIトークン、通知の署名キー、受信窓口の認証キーは、データベースごとに分けたキーチェーン項目に保存します。SQLiteにはその項目ID、公開URL、通知登録のURI、進捗と確認記録だけを保存します。設定保存は新しい不変の項目を作ってからSQLiteの参照を切り替え、失敗時は新しい項目を削除します。署名キーが未設定なら32バイトの乱数から生成します。

通知登録は管理者だけが変更できます。組織単位の `invitee.created` と `invitee.canceled` を登録し、作成要求に署名キーを渡します。[Calendlyの作成API](https://developer.calendly.com/api-docs/calendly-api/webhooks/create-webhook-subscription)

作成前に、処理IDを含む通知先URLと進捗を保存します。作成結果を受け取れなかった場合、再開時は同じ通知先URLの登録を一覧から探します。一覧は100件ずつ読み込み、戻されたURLを直接たどらず、ページトークンを公式APIの固定ホストへ送ります。一致する登録が一つなら保存して復旧します。[Calendlyの一覧API](https://developer.calendly.com/api-docs/calendly-api/webhooks/list-webhook-subscriptions)

一覧に見つからないことだけでは、直前の作成要求が未処理だったと断定しません。自動再作成はせず、管理者が未作成と確認した内容を記録してから再試行します。照合で登録が見つかった場合は、未作成として扱う操作を拒否します。

以前の登録を削除する前は、公式APIから現在の内容を取得して、保存済みの通知先・組織・対象イベントとの一致を確認します。削除の応答を失った場合も、再開後に404を確認すれば次へ進めます。別のURLへのリダイレクトや、公式ホスト以外の登録URIにはAPIトークンを送りません。[取得API](https://developer.calendly.com/api-docs/calendly-api/webhooks/get-webhook-subscription)、[削除API](https://developer.calendly.com/api-docs/calendly-api/webhooks/delete-webhook-subscription)

未完了の処理がある間は通常の設定変更を止めますが、期限切れAPIトークンの更新は、通知先と署名キーを維持して行えます。別の管理者への明示的な引き継ぎ、作成前の中止、受信キー設定のやり直しは、日本語設定画面の「その他の操作」から行えます。

## 設定画面と自動取り込み

NextCRM Nativeメニューの「Calendlyの予約連携…」を開き、接続設定を保存してから「通知を登録」を押します。登録・解除・取り込みはSQLiteのジョブとして保存されます。アプリを再起動しても未完了の処理を再開します。通信エラー時は最大4回試行し、作成結果の照合で登録が見つからない場合は確認待ちにします。

登録を行った管理者を自動取り込みの担当として保存します。実行中も最新の権限・設定・処理の占有権を確認し、失効した処理が取り込み位置や通知登録を確定することを防ぎます。登録ジョブの完了と初回取り込みの予約を同じトランザクションで確定します。通知登録の保存後、ジョブ完了前に終了した場合も、次回起動時の走査で取り込みを予約します。取り込み中の追加要求は、終了後の1回の再確認にまとめます。

アプリ起動・復帰時と、設定済みの間は起動中に1分ごとに確認します。未設定・通知解除後・担当者の権限失効・確認が必要な失敗時は定期確認を止めます。Mac上に受信サーバーのプロセスを常駐させる処理はありません。

## 検証

```sh
zsh desktop/calendar-relay/test.sh
zsh desktop/native/calendly-relay-test.sh
zsh desktop/native/calendly-subscription-test.sh
zsh desktop/native/calendly-runtime-test.sh
python3 desktop/native/calendly-settings-ui-test.py
```

既存の依存パッケージだけを使います。サーバー側では署名、再送、設定競合、暗号化、再起動、ページ分割、容量制限、保存破損などを検証します。Swift側では実際のループバックHTTPを使い、205件の取り込み、途中失敗からの再開、取消、同時更新、権限失効、取り込み位置の保存失敗時のロールバックを確認します。

通知登録のテストは、実際の受信サーバーとメモリ内のCalendly API代替を組み合わせます。作成・削除応答の喪失、別DB接続からの再開、権限失効、同時処理、秘密情報の保存失敗、設定の競合を検証します。`calendly-subscription-test.sh --keychain-probe` は、ランダムな検証用DB識別子に対応する偽のキーチェーン項目だけを作成・照合・削除します。実アカウントの認証情報は使いません。

ランタイムとAppKitのテストでは、本番のジョブ処理・設定画面を使い、205件の取り込み、処理の占有権切れ、担当者の権限失効、再試行、同時要求、終了・再起動、定期取り込み、解除の確認、未作成の確認入力を検証します。隔離アプリのQA用アダプターは固定の偽認証情報だけを受け付け、Calendly APIはMac内で模擬し、受信窓口への接続先もループバックに限定します。
