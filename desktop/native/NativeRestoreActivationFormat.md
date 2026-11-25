復元候補を現在のMacアプリへ適用する独立工程です。既存の復元準備・DataMaintenanceファイルは変更しません。構成時に指定されたprivate control directoryへ、active-root pointerと中断回復journalを保存します。旧rootは名前変更・上書き・削除せず、新しいrootは公開済み復元候補の実パスを使います。最終namespaceは実際の `crm.sqlite` のcanonical pathから計算します。通常DB・Keychainをこのコンポーネントが探索したり、自動で選択したりする処理はありません。

8 obligationsの解決境界は次のとおりです。

| obligation | 必要な実証拠と責任 |
| --- | --- |
| sourceProvenance | 現在の管理者と選択したsnapshot/restore hashを結ぶ明示的な信頼判断。hash一致だけを署名・出所証明にしない。hostのauthorizeをawait後にも実行 |
| stopAndSwitch | 全writer参加者を構成時に列挙し、編集・未保存draft・遅延callback・listener・worker・cleanup・DB writable handleを停止してawait drain。実行中数/handle/未保存編集/callbackが全0である実reportを要求。control switch lockは全アプリinstanceが守る必要がある |
| candidateRevalidation | 管理フォルダinodeを固定し、restore/backup/table/file/plan hash、DB schema/revision/integrity/FK、全assetとDB参照を再検証。既存NativeRestoreの検証を実FS経由で再利用し、作成元を推定しない |
| credentials | planのcredential/設定/cleanup各行とKeychain-only設定を最終namespaceへ結び、参照鍵の存在・provider用途を確認。鍵不足はそのruntimeを明示保留し、cleanupを始めない。secret値をjournalへ保存しない |
| jobs | 全plan行に対応する個別判断をstreamで残す。lease所有者停止、delivery unknown、provider receipt、idempotency期限を実記録で確認。元queue/result/MIMEを保持し、全jobをdone/cancelledにしない。同eventに未解決jobがあればそのruntime/eventを開始しない |
| relayAndPluginState | receiver instance/client/head/cursor、IMAP UIDVALIDITY、connector ID/TTL claimをproviderと照合。未確認の連携だけを保留し、claimを一括削除しない |
| pendingAssets | inherited pendingの外部添付・原画像・metadata不足等を具体的に確認し、承認された利用範囲/保留runtimeを記録。欠落を修復済みと表示しない |
| runtimeStartup | 上記判断で許可されたruntimeだけを明示列挙し開始。participant名だけでは開始成功の証拠にせず、実際のstart結果と保留対象を返す |

切替前の失敗・取消は新しいpaused runtimeを閉じ、旧rootを選択したまま、元runtimeの再開結果を確認します。旧rootの復帰に失敗した場合はrecoveryRequiredを残し、正常に戻ったとは表示しません。durable pointer commit後は外部effectが起きうるため、取消やstart失敗で旧rootへ自動復帰しません。候補を選んだままactiveDegradedを残し、個別の再照合・再開へ引き継ぎます。

crash後はpointerを先に照合します。旧pointerなら新候補を自動開始せず旧側の復帰へ、新pointerなら旧側の再送を起こすrollbackをしません。journalのstateだけで判断せず、実pointerとrootのinodeを確認します。phaseがstartingのときはeffectが既に生じた可能性を保ち、providerによる再照合が必要です。復元候補はactivation後に更新されるため、最初のbackup hashを通常稼働DBの永続hashとは扱いません。

root接続は `NativeRestoreActivationHooks` で行います。現行CRMAppのMCP/plugin/currencyにはawait stopがある一方、invoice/order/project/task/lead/report、document、campaign、calendar、mail、AI/enrichmentなどの単なる `.stop()` は完了証拠になりません。全workerのtask集合・進行中HTTP/SMTP/SQLite/file I/Oの終了待ち、窓とeditor/draftとAPI callbackのfence、DB所有者の解放までが未接続のhost責務です。DataMaintenanceは `onClosed` のcancel/drain完了後に停止参加者として記録します。

具体的な接続順序と既存APIは次のとおりです。この表の不足APIをこのsliceが既存共有ファイルへ追加することはありません。

| 接続順序 | 現行コードと必要な接続 |
| --- | --- |
| 起動root選択 | CRMAppの通常DB初期化より前にprivate controlの選択を読み、`recover`を実行。rootを推測したり復元先に`CRMService.bootstrap`を実行したりしない。pointerとjournalが矛盾する場合は手動修復画面へ |
| UIと新規受付停止 | CRMApp `confirmClose`は未保存確認の入口に再利用できるが、confirmだけで全windowや保存taskの完了とはしない。command/menu/deep link/wake/notification、特に`applicationDidBecomeActive`のkick/resumeをgenerationで閉じる。既存sheet/controllerはdrain完了まで保持 |
| 準備処理終了 | CRMApp `drainDataMaintenance`をawaitし、Window `onClosed`を待つ。`onReviewActivation`から直接rootを変更しない |
| MCP停止 | NativeMCPRuntime `stop() async`と起動taskのvalueをawait。NativeMCPHTTPServerはlistener終了とpeer task/parseTask消滅まで待つ既存実装を再利用 |
| plugin/通貨停止 | NativePluginsRuntime / NativeCurrencyAdministrationRuntime `stop() async`はworker/taskのvalueをawaitする。保持中のstartup taskもcancelしてawait。credential cleanup中も同じdrainへ含める |
| 業務runner停止 | InvoiceJobRunnerの現`stop()`はcancelのみ。新`stopAndDrain() async`でtask完了を待つ共有拡張が必要。invoice/order/project/task/lead/report/document/campaignはこのrunnerを保持している |
| calendar/mail/enrichment | NativeMailRuntime / GoogleCalendarRuntime / CalendlyRuntimeのscanと所有runner、NativeEmbeddingRuntime / ContactEnrichmentRuntime / TargetEnrichmentRuntime wrapperを同様にawait drain。同期C transportがcancelに応じない場合も完了まで切替を保留し、timeoutを完了に偽装しない |
| handle解放とpaused構築 | CRMService/NativeDatabaseおよびwindow/service/worker closureの旧root参照を解放。新候補をNativeDatabase初期化するのはcommit後。commit前はimmutable read-only DBで検査し、WAL/SHM/journalや新jobを作らない |
| commitと再開 | `capturePreviousRunning`の実running集合を保存し、失敗前の方針を勝手に全startへ広げない。最終認可await後に全候補hash/asset/tree/root/evidenceを再確認し、次のawaitを挟まずdurable pointerを更新。`resumeCommitted`は許可runtimeだけを起動し実結果を返す |
| cold再開 | `verifyRecoveryQuiescence(context,selection)`が現在のtask/handle/editor/callback/listener全0を検証。過去のdrainは使わない。成功済active journalもcold起動ではactiveDegradedとなり、`resumeRecovered`が現DBと外部receiptを再照合して再開。過去planに無い稼働後の新jobもproviderの全体jobs照合責務に含む |

停止/再開policyのruntime catalog（id、event集合、外部effectの有無）は構成時の登録であり、復元データから読み込みません。catalog自体もapproval subjectに結びます。cold起動でcatalogが変わった場合は自動再開せず、追加runtimeの方針を改めて承認する移行adapterが必要です。control/rootの排他は同じMacの全起動instanceが守る契約です。同OS利用者による協調しないファイル改変を、このロックで防止できるとは主張しません。

パスには二つの意味があります。安全なdescriptor走査はPOSIX `realpath` の物理パス（例えば`/private/var`）を使用します。既存credential adapterとのnamespace互換はFoundationの`resolvingSymlinksInPath().standardizedFileURL`を使用します。source/staging/final namespaceを別々に保持し、stagingがfinalと同じと推測しません。通常の復元出力に無いWAL/SHM/journal、未登録asset、共有hard linkはcommit前に拒否します。

DataMaintenanceで公開された候補のみ、追加の`.nextcrm-maintenance-owner.json`を任意の補助metadataとして受理します。最大4KiB、current uid所有、0600、regular file、nlink1で、exact keys `{version,registry,operation,role,nonce,uid}`、version1、role publication、lowercase UUIDを検査し、そのraw hashもsealへ含めます。これは削除権限や出所証明として使いません。直のNativeRestore出力にはこのmarkerが無くても構いません。回収側のprivate registryとjournal/lock/inodeの照合は別機能が所有し、activationはそれらを変更しません。

paused candidateの構築はproviderごとの起動を止めたまま行います。`CRMService.bootstrap` が復元rootに新しいlocalActorを勝手に作る接続は禁止です。復元された利用者/Sessionの選択は別の本人確認・管理判断が必要です。すべてのprovider callbackはtrusted composition境界であり、復元ファイルの文字列から実装やruntimeを選びません。通常のKeychainアクセス・移送や外部通信はこのsliceでは実装/実行せず、その責務をfake成功で埋めません。

providerがErrorの説明やcodeへ秘密を含めても、journalにはenum phaseから作った固定の失敗識別子だけを保存します。初期認可・旧running policy取得・cold quiescenceのcallback失敗も固定識別子に変換し、生のprovider errorを表示/書出しへ返しません。証拠には内容のSHA-256を使い、secret値やcredential reference自体は含めません。

検証ではsynthetic filesystem、実SQLite、停止/開始で実際に変化するwriter・provider fixtureを使います。単なるcallback呼出し履歴だけで成功としません。未確認の送信jobは元の状態で残し、許可したローカル処理だけが進むこと、各失敗/取消/中断地点で選択rootと旧データが矛盾しないことを確認します。

検証用コピーは64KiB単位で処理し、plan/decisionはNDJSONを1行ずつ読み書きします。再検証時には候補と別にbackup再構成と検証済候補を一時作成するため、最大で概ね候補2個分と検証用SQLite索引の追加ディスク領域が必要です。通常終了・失敗・取消で回収しますが、そのコピー中にプロセスが強制終了した場合の`NextCRMActivationVerify-*`回収registryは未接続です。DataMaintenanceのTMP/publication回収とはpurposeが異なるため、相互に推測削除しません。

次の最小作業分割（共有ファイルの変更はrootによる明示的な所有権移譲後のみ）：

| 担当slice | 変更が必要な正確なファイル | 最小の受入条件 |
| --- | --- | --- |
| A 共通job drain | `desktop/native/InvoiceJobRunner.swift`、新専用tests | main queueで先に新規kick/observer/timerを閉じ、保持taskをcancelしてvalueまでawaitする`stopAndDrain() async`。停止中の二重呼出しは同じ処理の完了を待つ。cancelに遅れて応じるfake transportを使い、戻った後のDB/file更新0、元job/receipt保持、stale wakeから再開しないこと。既存stop互換は維持 |
| B 定期scan wrappers（A依存） | `desktop/native/NativeMailRuntime.swift`、`desktop/native/GoogleCalendarRuntime.swift`、`desktop/native/CalendlyRuntime.swift`、新専用tests | 各scan TaskとそのMainActor completionをawaitし、全所有InvoiceJobRunnerをdrain。GoogleはrunnerとpushRunnerの両方、mailはrunners配列全要素。timer/observer/resume(forceSync含む)は停止後に新規scanを作らない。停止後同instanceをkickで復活させず、再開は明示的な再構築とする |
| C AI wrappers（A依存、Bと並列可） | `desktop/native/NativeEmbeddingRuntime.swift`、`desktop/native/NativeContactEnrichmentRuntime.swift`、`desktop/native/NativeTargetEnrichmentRuntime.swift`、新専用tests | embeddingのrunner/documents両方、contact/target各runnerをawait drain。特にaiProgress cancellationObserverが現在生成する`Task { await worker.cancel… }`はrunnerとは別なので、登録/終了追跡と停止fenceを追加してawaitする。observer callbackの後着で旧DBを触らないこと |
| D App接続とwriter fence（root） | `desktop/native/CRMApp.swift`、新`desktop/native/NativeRestoreActivationApplication.swift`等、`desktop/native/build.sh` / `test.sh` | 既存startup/stopとA〜C、DataMaintenance.onClosed、documentRecovery Task、window保存/写真/選択panel等の非同期処理、deep linkとwakeを一つの世代fenceへ接続。window/controller/service/DBの旧root所有者を解放した事実をdrain receiptへ記録。取消で戻る際もUIとruntimeの元方針を復元。全編集画面の追加変更が必要なら個別に所有権を調整する |
| E credentialsとprovider照合（family別に並列可） | 新`NativeRestoreActivationCredentials*.swift` / `NativeRestoreActivationMail*.swift` / `NativeRestoreActivationPlugins*.swift`等 | 既存namespace付きsecret storeを注入し、各参照と用途を検査。mail/relay/calendar/connectorの現receipt/cursor/claimを照合し、未確認のeventだけ保留。候補commit前はDBを更新せず、commit後の個別CAS照合を監査。同期状態を無条件で全完了/削除にしない |
| F activation scratch回収（独立purpose） | 新`NativeRestoreActivationRecovery*.swift`と専用tests | verifier用private scratchだけをowner marker/lease/parent+root inodeで回収。DataMaintenance registryおよび公開候補/control/active rootを推測削除しない。強制終了中のコピーを実fixtureで回収検証 |

NativeMCPRuntime / NativeMCPHTTPServer / NativePluginsRuntime / NativeCurrencyAdministrationRuntimeの既存await stopはDで再利用します。source上の追加変更を今必須とはしていませんが、drainの数値は「旧rootへ書けるtask/callback/handle」の実件数を意味し、cancelを呼んだ回数や機能名で0を埋めません。OS runloopやfence後に即returnするcallbackまで存在しないと主張するものではありません。

保留を解除する経路は、稼働中runtimeを実drainしたうえで`recover`→`resumeRecovered`を呼び、現在のprovider証拠を取得し直す手順です。専用testでは、最初はdelivery unknownの1jobを保持してmailを保留し、その後fake providerの対応job receiptを照合、対象1件だけを実SQLite CASで完了、mail workerの実scanを再開し、provider再送0を確認します。旧rootの同jobは変更しません。
