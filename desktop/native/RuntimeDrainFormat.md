# 定期同期 runtime の停止待機（B）

本体の `NativeMailRuntime.swift`、`GoogleCalendarRuntime.swift`、`CalendlyRuntime.swift` へ検証済み候補を反映済み。元候補は `build/runtime-drain-candidate/` に保持する。

3 型は `@MainActor func stopAndDrain() async` と `isStopped` を提供する。Google は既存 mail/Calendly と同じ意味の `isRunning` も提供する。`isRunning` は所有 worker、`isScanning` は定期検索の実行状態を示す。停止要求時点で実行中を偽って false にしない。

停止の冒頭で同一 instance を終了状態にし、timer、coalesced scan、Calendly observer を止め、全所有 InvoiceJobRunner に先に `stop()` を送る。その後 scan Task（MainActor の終了処理を含む）、mail の 3 runner、Google の受信・送信 runner、Calendly の登録・受信 runner の実終了を待つ。複数の停止待機、待機側 Task の取消も、実処理が残ったまま正常復帰する根拠にしない。通信が取消に遅れて応じる間は復元切替を保留する。

同一 instance の `resume`、`forceSync`、通知、予約済 timer は停止を解除しない。wrapper は InvoiceJobRunner の `restartAfterDrain` を自動利用しない。rollback/再開は host が停止済み instance を解放し、許可された構成で新たに作成する。host はその前に設定画面・メニュー・MCP wake 等の新規要求を遮断する必要がある。

scan/timer の ticket と停止世代を確認し、旧 completion が別の処理を消さないようにする。外部 `onError` callback の後も再確認し、callback が同期的に stop/resume した場合の古い timer 設置を防ぐ。Calendly observer は停止時に解除し、DB 自体ではなくパス文字列だけを capture する。解除前に配信待ちとなった通知は停止世代により無効になる。

停止で job、receipt、SMTP 受付結果、Google の unknown mutation intent、Calendly の creating intent、relay cursor を一括更新・消去しない。各 worker が既存の取消・不確実な通信結果処理を完了するまで待つ。remote unsubscribe、資格情報の削除、queue の全件 done/cancelled 化は行わない。

完了後も wrapper/store/worker の `let db` は保持され得る。旧 DB の全参照を解放した証明、他の UI/同期処理や資格情報の検査、実 root 切替は host/activation の別責務であり、この API 単独では許可しない。

正規の専用試験は `python3 desktop/native/runtime-drain-test.py`。`RuntimeDrainSources.json` の明示リストと本体 3 ファイルを使用する。`--candidate` を明示した場合だけ同名の本体 3 ファイルを除外し元候補を使用する。`RUNTIME_DRAIN_TESTS` の初期化口は通常ビルドに存在せず、取消非協調の scan/worker を注入して実 SQLite/file の最終更新まで待つことを検査する。別試験で通常初期化口と実 worker を fake provider で動かす。外部 HTTP、実 Keychain、通常データへのアクセスは行わない。実サービス側で処理が取り消されたこと自体の証明ではない。
