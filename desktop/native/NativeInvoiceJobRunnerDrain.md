InvoiceJobRunner の停止・再開契約

既存 `stop()` は同期で新規受付を閉じ、現在のtaskへ取消を要求する終端操作です。実taskの完了前は `isRunning == true` を保ちます。`isStopped` は受付状態であり、I/O完了を意味しません。既存の非async APIと状態参照はこれまでどおりmain queueから使用します。

`@MainActor func stopAndDrain() async` はstop後に保持taskのvalueをawaitします。呼出元Taskが取消されても、そのawaitを途中放棄しません。transportが取消を無視して最後にSQLiteやファイルを書き込む場合も、その処理が返るまで待ちます。queueのstatus/lease/resultを停止だけで完了・取消へ変更しません。

`@MainActor @discardableResult func restartAfterDrain() async -> Bool` は、現在taskの完了を待ってから明示的に受付を開き、observerを再登録してkickします。後からstopまたはrestartが要求された場合、古い要求はfalseとなり停止解除できません。再開要求元が取消された場合もfalseを返し、停止を維持します。既存のkick、notification、timerが暗黙にこの再開APIを呼ぶことはありません。

lifecycle generationと実行task IDを分けています。停止後に遅れて返ったworkerは、新しい世代のtaskを消したりretry timerを作ったり、didProcess/onError callbackを出したりしません。実際に確定したjob resultはそのまま残します。既存の通常動作（通知による起動、期日timer、連続job処理、失敗時30秒retry）は維持します。

root切替ではAppが新しい明示restart要求もfenceする必要があります。stopAndDrainは「呼出し時の世代の処理が完了した」ことを保証し、その後に別の明示restartが発行されないことまでは保証しません。BのMail/Google/Calendly wrappersはterminal stoppedを維持し、同instanceのresume/forceSync/observerからrestartAfterDrainを呼ばず、hostが明示的に再構築する方針です。

検証は `python3 desktop/native/invoice-runner-drain-test.py` で実行します。実SQLite・実ファイルに遅れて結果を書き込むfake transport、2並列drain、drain callerの取消、取消/失敗で残るlease・delivery unknown、stop/restart/cancel競合、期日timer、通知再開、直列実行を確認します。証拠は `build/invoice-runner-drain-verification.json`。既存の請求/受注/プロジェクト/CRMタスク通知との互換は、`python3 desktop/native/invoice-runner-regression-test.py` が既存 `invoice-mail-test.sh` を変更せず実行し、`build/invoice-runner-regression-verification.json` に別途記録します。実Keychain probeや実送信は呼びません。

C wrappersの未追跡control TaskはこのA sliceには含めていません。AI worker自身が作るrequest Taskは既に親へjoinされていますが、NativeEmbeddingRuntime / NativeContactEnrichmentRuntime / NativeTargetEnrichmentRuntimeのaiProgress cancellationObserverが作る `Task { await worker.cancel… }` はrunner外です。次の接続条件が必要です。

- wrapper停止時は最初にstopped/generationを更新し、observer受付を解除する。後着callbackはTask作成前に拒否する。
- control operationのTask handleを保持し、同じjob IDの同時重複をまとめる。待機数を無制限に増やす設計にしない。受付できない場合を呼出元へ返すか、既存の永続cancel状態を根拠に安全な再試行を設計し、処理済みと偽らない。
- 停止時に閉じたcontrol集合と全runnerをcancelして、それぞれのvalueをawaitする。controlが遅いときに先にdrain成功を返さない。
- 完了callbackは自身のgeneration/task IDと一致する登録だけを除去し、後から登録された同じkeyのTaskを削除しない。
- `performControl(key:operation:)` をrunner共通APIに追加する案でも、上記受付fence・caller取消時のjoin・世代照合を満たす。Aと同じ既存shared ownerの調整後に別sliceで実装する。

変更済み既存productionは `desktop/native/InvoiceJobRunner.swift` のみです。B/C、CRMApp、DB、Store、build/test登録は変更していません。復元の状態機械と全体分割は `NativeRestoreActivationFormat.md` に記載されています。
