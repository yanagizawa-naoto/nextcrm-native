import AppKit
import Darwin

/// Retains the process host; the actual CRM controller is owned by its joined
/// registration. AppKit events and menu targets continue to use that controller.
@MainActor final class NativePersonalApplicationComposition:NSObject,NSApplicationDelegate {
    private var host:NativePersonalApplicationHost?
    private var previousRecovery:NativePersonalPreviousRecovery?
    private var recoveryPrompt:NativePersonalPreviousRecoveryPrompt?
    private var recoveryQuitTask:Task<Void,Never>?
    private var launchURLs:[URL]=[]
    private weak var application:NativeCRMApplication?
    private var launchTask:Task<Void,Never>?
    private var transitionTask:Task<Void,Never>?
    private var restoreCancellationTask:Task<Void,Never>?
    private var restoreParent:NativePersonalRestoreParent?
    private var restoreChild:NativePersonalRestoreChild?
    private var pendingLocalUse:(()throws->Void)?
    private var earlyURLs:[URL]=[]
    private var paths:NativePersonalApplicationPaths?
    private var stopping=false
    private var quitAfterTransition=false

    nonisolated static func main() {
        MainActor.assumeIsolated {
            umask(0o077)
            #if PERSONAL_APP_QA
            NativePersonalQAStartup.enter()
            #endif
            if CommandLine.arguments.dropFirst().first=="--personal-restore-helper" {
                runHelper();return
            }
            let app=NSApplication.shared,owner=NativePersonalApplicationComposition()
            app.delegate=owner;app.setActivationPolicy(.regular);app.run()
            withExtendedLifetime(owner){}
        }
    }
    private static func runHelper() {
        guard CommandLine.arguments.count==4,let resources=Bundle.main.resourceURL else {exit(64)}
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let status:Int32
            do {
                try await NativePersonalRestoreHelper.run(base:URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true),
                    controlURL:URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true),resources:resources)
                status=0
            } catch {status=1}
            RunLoop.main.perform(inModes:[.default,.common]){exit(status)}
        }
        app.run()
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        launchTask=Task { [self] in
            do {try await launch()}
            catch is CancellationError {await endFailedLaunch(nil)}
            catch {await endFailedLaunch(error)}
            launchURLs.removeAll();launchTask=nil
        }
    }
    private func launch()async throws {
        guard let resources=Bundle.main.resourceURL else {throw NativeRestoreActivationFailure("personal.resources")}
        if CommandLine.arguments.dropFirst().first=="--personal-restore-child" {
            try await launchInherited(resources:resources);return
        }
        let root:URL
        if let path=ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_DATA_DIR"] {
            root=URL(fileURLWithPath:path,isDirectory:true)
        } else {
            let support=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            root=support.appendingPathComponent("NextCRMNative",isDirectory:true)
        }
        let control=root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent+"-control",isDirectory:true)
        let paths=try NativePersonalApplicationPaths(baseRootURL:root,controlURL:control);self.paths=paths
        #if PERSONAL_APP_QA
        try NativePersonalQAStartup.markFixture(paths.baseRootURL)
        #endif
        launchURLs=earlyURLs
        let host=makeHost(paths:paths,resources:resources)
        do {try await host.start()}
        catch let failure as NativeRestoreActivationFailure where failure.code=="personal.recoveryRequired" {
            // start() has already joined its failed registration and closed the
            // old gate. Never reuse that closed Startup as cold authority.
            await host.stopAndDrain();self.host=nil
            earlyURLs=launchURLs
            try await resumePrevious(paths:paths,resources:resources)
        }
    }
    private func resumePrevious(paths:NativePersonalApplicationPaths,resources:URL)async throws {
        try Task.checkCancellation()
        let startup=try NativeRestoreApplicationStartup(baseRootURL:paths.baseRootURL,controlURL:paths.controlURL,
            runtimes:NativeRestoreRuntimeCatalog.runtimes)
        var transferred=false
        defer {if !transferred {startup.lease.close()}}
        try paths.validate(startup)
        guard startup.plan.mode == .recoveryRequired,application==nil,host==nil,
              NativeDatabase.liveConnections().isEmpty else {throw NativeRestoreActivationFailure("personal.previousRecoveryLive")}
        let prompt=NativePersonalPreviousRecoveryPrompt(root:startup.plan.root.url)
        recoveryPrompt=prompt
        let confirmed=await prompt.show()
        recoveryPrompt=nil
        try Task.checkCancellation()
        guard confirmed else {throw CancellationError()}
        let recovery=try NativePersonalPreviousRecovery(startup:startup,paths:paths,resources:resources,
            runtimes:NativeRestoreRuntimeCatalog.runtimes,writerParticipants:NativeRestoreRuntimeCatalog.writerParticipants,
            callbacks:.init(authorize:{[weak self] context in
                guard let self else {throw CancellationError()}
                try self.authorizePreviousRecovery(context,startup:startup,paths:paths)
            },verifyQuiescence:{[weak self] context,selection in
                guard let self else {throw CancellationError()}
                try self.authorizePreviousRecovery(context,startup:startup,paths:paths)
                let connections=NativeDatabase.liveConnections()
                guard selection==context.previous,self.host==nil,self.application==nil,
                      self.restoreParent==nil,self.restoreChild==nil,self.transitionTask==nil,
                      self.recoveryPrompt==nil,self.recoveryQuitTask==nil,self.pendingLocalUse==nil,
                      connections.isEmpty else {throw NativeRestoreActivationFailure("personal.previousRecoveryLive")}
                struct Evidence:Encodable {
                    let selection:NativeRestoreActivationSelection,lease:NativeRestoreHostLeaseIdentity,uid:UInt32
                    let connections:[NativeDatabase.LiveConnection],configuredHosts:Int,gatedURLs:Int
                }
                let evidence=Evidence(selection:selection,lease:startup.lease.identity,uid:geteuid(),
                    connections:connections,configuredHosts:0,gatedURLs:self.earlyURLs.count)
                return .init(root:selection.root,participants:NativeRestoreRuntimeCatalog.writerParticipants,
                    previouslyRunning:[],unfinishedTasks:0,openWritableHandles:0,unsavedEditors:0,pendingCallbacks:0,
                    evidenceSHA256:try NativeRestoreHostStartupCodec.hash(evidence,domain:"NextCRM.personal.cold-quiescence.v1"))
            },makeHost:{[weak self] current,permit in
                guard let self else {throw CancellationError()}
                try current.validatePreviousRecovery(permit)
                return self.makeHost(paths:paths,resources:resources)
            },readiness:{[weak self] context,current,host in
                guard let self,self.host === host,host.state == .running,let app=self.application else {throw CancellationError()}
                return try app.personalPreviousRecoveryReadiness(context,startup:current)
            },didRecover:{[weak self] context,current,host in
                guard let self,self.host === host,let app=self.application else {throw CancellationError()}
                try self.authorizePreviousRecovery(context,startup:current,paths:paths)
                guard try current.control.read("activation.json",as:NativeRestoreActivationJournal.self)?.phase == .previousRestored else {
                    throw NativeRestoreActivationFailure("personal.previousRecoveryIncomplete")
                }
                _ = try app.personalPreviousRecoveryReadiness(context,startup:current)
            },confirmLocalReview:{[weak self] prompt in
                guard let self,let parent=self.application?.personalMainWindow else{throw CancellationError()}
                let alert=NSAlert();alert.messageText="連携を停止したまま元データを開きますか？"
                alert.informativeText="接続設定の再確認が必要なため、自動送信・同期は開始しません。元データの閲覧と編集は利用できます。再開は『機能・連携を再開』から確認してください。\n\n保存先：\(prompt.rootPath)\n停止する処理：\(prompt.heldRuntimes.count)件"
                alert.addButton(withTitle:"連携を停止したまま開く");alert.addButton(withTitle:"キャンセル")
                try Task.checkCancellation()
                let answer=await withTaskCancellationHandler(operation:{await alert.beginSheetModal(for:parent)},onCancel:{
                    Task {@MainActor in if alert.window.sheetParent != nil {parent.endSheet(alert.window,returnCode:.cancel)}}
                })
                try Task.checkCancellation();guard answer == .alertFirstButtonReturn else{throw CancellationError()}
                return .keepWorkersHeld(subjectSHA256:prompt.subjectSHA256)
            }))
        previousRecovery=recovery;transferred=true
        do {self.host=try await recovery.run()}
        catch {await recovery.cancelAndDrain();previousRecovery=nil;self.host=nil;throw error}
    }
    private func authorizePreviousRecovery(_ context:NativeRestoreActivationContext,
                                           startup:NativeRestoreApplicationStartup,paths:NativePersonalApplicationPaths)throws {
        try Task.checkCancellation();guard !stopping else {throw CancellationError()}
        try paths.validate(startup)
        guard startup.lease.identity.uid==geteuid(),startup.plan.root==context.previous.root,
              startup.plan.selection==context.previous,startup.plan.activationID==context.activationID,
              try startup.control.read("active-root.json",as:NativeRestoreActivationSelection.self)==context.previous else {
            throw NativeRestoreActivationFailure("personal.previousRecoveryAuthority")
        }
    }
    private func makeHost(paths:NativePersonalApplicationPaths,resources:URL)->NativePersonalApplicationHost {
        let host=NativePersonalApplicationHost(paths:paths,resources:resources,runtimes:NativeRestoreRuntimeCatalog.runtimes,
            databaseOpener:{url,readOnly in
                if readOnly {return try NativeDatabase(readOnlyURL:url,schemaURL:resources.appendingPathComponent("schema.json"))}
                return try NativeDatabase(url:url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            },presentOwner:{picker in picker.start();NSApp.activate(ignoringOtherApps:true)},
            validateReadOnly:Self.validateReadOnly,
            resolvePersonalRestore:{startup,resources in try await Self.resolvePersonal(startup,resources:resources)},
            compose:{[weak self] prepared,registration in
                guard let self else {throw CancellationError()}
                try await self.compose(prepared,registration:registration,resources:resources,paths:paths)
            })
        self.host=host
        for url in earlyURLs {_ = host.receive(url)};earlyURLs.removeAll()
        return host
    }
    private func launchInherited(resources:URL)async throws {
        guard CommandLine.arguments.count==4 else {throw NativeRestoreActivationFailure("personal.launchArguments")}
        let base=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        let control=URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true)
        let child=try NativePersonalRestoreChild(ipc:NativeRestoreHostIPC(consumingConnectedSocket:20),leaseDescriptor:.init(consuming:21),
            baseRootURL:base,controlURL:control,
            makeHost:{[weak self] startup in
                guard let self else {throw CancellationError()}
                let paths=try NativePersonalApplicationPaths(adopting:startup,baseRootURL:base)
                self.paths=paths;return self.makeHost(paths:paths,resources:resources)
            },readiness:{[weak self] request,startup in
                guard let app=self?.application else {throw CancellationError()}
                return try app.personalRestoreReadiness(request,startup:startup)
            },didBecomeReady:{[weak self] _,_ in
                guard let self,let app=self.application,let use=self.pendingLocalUse else {throw CancellationError()}
                try app.enablePersonalRestoredUse(use);self.pendingLocalUse=nil
            },timeout:300)
        restoreChild=child
        switch try await child.start() {
        case .ready:break
        case .processExitRequired:throw NativeRestoreActivationFailure("personal.inheritedLaunchFailed")
        }
    }
    private static func verifier(_ resources:URL)->NativeRestoreActivationVerifier {
        .init(schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"),cancelled:{Task.isCancelled})
    }
    static func validateReadOnly(_ startup:NativeRestoreApplicationStartup,_ resources:URL)throws {
        try startup.control.validate();try startup.lease.validate()
        guard let selection=startup.plan.selection,
              let journal=try startup.control.read("activation.json",as:NativeRestoreActivationJournal.self),
              journal.candidate==selection,journal.activationID==startup.plan.activationID,
              let seal=journal.seal else {throw NativeRestoreActivationFailure("personal.sealedWorkspace")}
        let verifier=verifier(resources),candidate=try verifier.inspect(selection.root.url)
        guard candidate.root==selection.root,candidate.seal==seal else {throw NativeRestoreActivationFailure("personal.sealChanged")}
        try verifier.validate(candidate);try verifier.unchanged(candidate)
        try startup.control.validate();try startup.lease.validate()
    }
    nonisolated private static var usesQAServices:Bool {
        #if PERSONAL_APP_QA
        return true
        #else
        return ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_MAIL_TEST_MODE"] != nil
        #endif
    }
    nonisolated private static func providerStores(_ service:CRMService)throws->NativePersonalRuntimePrerequisites.Stores {
        try NativePersonalProviderStores(service:service,usesQAServices:usesQAServices).prerequisiteStores()
    }
    private static func resolvePersonal(_ startup:NativeRestoreApplicationStartup,resources:URL)async throws->NativePersonalApplicationHost.Workspace {
        try await NativePersonalRuntimeWork.workspace(startup:startup,resources:resources,stores:providerStores)
    }
    private func compose(_ prepared:NativePersonalApplicationHost.Prepared,
                         registration:NativePersonalApplicationHost.Registration,
                         resources:URL,paths:NativePersonalApplicationPaths)async throws {
        let startup=prepared.startup,service=prepared.service,plan=prepared.plan,owner=prepared.owner
        let app=try NativeCRMApplication(startupPlan:plan,workspaceOpener:{root,_ in
            guard root==plan.root else {throw NativeRestoreActivationFailure("personal.workspaceBinding")}
            return service
        })
        try registration.install(owner:app,present:{try app.presentPersonalWorkspace(resources:resources)},
            openURL:{app.receivePersonalURL($0)},stopAndDrain:{await app.discardRestoredWorkspace()})
        application=app
        let authorize={
            try NativePersonalHostAuthority.validateRunning(startup,paths:paths)
            if let record=plan.personal {try NativePersonalRestoreAdmission.validate(record,startup:startup)}
            try service.authenticated()
        }
        let review:((NativeDataMaintenanceArtifact,NSWindow)throws->Void) = {[weak self,weak app] artifact,parent in
            guard let self,let app,self.restoreParent==nil,self.transitionTask==nil else {throw NativeRestoreParentFailure.busy}
            try authorize()
            let restorer=try NativePersonalRestoreParent(startup:startup,application:app,resources:resources,paths:paths)
            self.restoreParent=restorer
            try restorer.start(artifact:artifact,parent:parent,onFinished:{[weak self] in self?.restoreParent=nil})
        }
        let use:(()throws->Void)?
        if plan.mode == .restoredHeld || plan.mode == .approvedHandoff {
            let action:()throws->Void = {[weak self] in
                guard let self,self.transitionTask==nil else {throw NativeRestoreParentFailure.busy}
                self.beginLocalUse(startup:startup,owner:owner,resources:resources)
            }
            if plan.mode == .approvedHandoff {pendingLocalUse=action;use=nil} else {use=action}
        } else {use=nil}
        let reviewJobs:(()throws->NativePersonalProviderReview)?
        if plan.mode == .personalActiveLocal {
            guard let record=plan.personal else {throw NativeRestoreActivationFailure("personal.recordMissing")}
            reviewJobs={
                try authorize()
                return try NativePersonalProviderReview(service:service,startup:startup,record:record)
            }
        }else{reviewJobs=nil}
        try app.configurePersonalHost(authorize:authorize,reviewRestore:review,useRestored:use,
            retainedRules:prepared.workspace.retainedRules,reviewRestoredJobs:reviewJobs,
            manageRuntimes:{[weak self] intent in
                guard let self else{throw CancellationError()}
                try self.beginRuntimeIntent(intent,startup:startup,resources:resources)
            },runtimeWorkflowAvailable:{[weak self] in
                guard let self else{return false}
                return self.transitionTask==nil && self.restoreParent==nil && self.launchTask==nil && !self.stopping && self.host?.state == .running
            })
        try await app.preparePersonalWorkspace(resources:resources)
    }
    private func beginLocalUse(startup:NativeRestoreApplicationStartup,owner:NativePersonalWorkspace.Selection,resources:URL) {
        // Neither this task nor its transition operation captures Prepared,
        // service, old App or the immutable read-only database.
        transitionTask=Task { [self] in
            do {
                let approval=try await NativePersonalRestoreAdmission.review(startup:startup,verifier:Self.verifier(resources),owner:owner,
                    confirm:{[weak self] prompt in
                        guard let self,let parent=self.application?.personalMainWindow else {throw CancellationError()}
                        let alert=NSAlert();alert.messageText="このデータを編集できるようにしますか？"
                        alert.informativeText="選択した利用者として、このMacでデータを編集します。メール送信・外部同期・以前の予約処理は確認待ちのままです。\n\n保存先：\(prompt.rootPath)"
                        alert.addButton(withTitle:"このMacで使う");alert.addButton(withTitle:"キャンセル")
                        try Task.checkCancellation()
                        let answer=await withTaskCancellationHandler(operation:{await alert.beginSheetModal(for:parent)},onCancel:{
                            Task {@MainActor in
                                if alert.window.sheetParent != nil {parent.endSheet(alert.window,returnCode:.cancel)}
                            }
                        })
                        try Task.checkCancellation()
                        guard answer == .alertFirstButtonReturn else {throw CancellationError()}
                        return .enableLocalEditingAndKeepExternalHeld(subjectSHA256:prompt.subjectSHA256)
                    })
                _ = try NativePersonalRestoreAdmission.begin(approval,startup:startup,verifier:Self.verifier(resources))
                guard let host else {throw CancellationError()}
                try await host.transitionWorkspace {startup,resources in try await Self.resolvePersonal(startup,resources:resources)}
            } catch is CancellationError {} catch {show(error)}
            transitionTask=nil
            if host?.state == .closed {stopping=true}
            if quitAfterTransition || stopping {
                quitAfterTransition=false
                RunLoop.main.perform(inModes:[.default,.common]){NSApp.terminate(nil)}
            }
        }
    }
    private func beginRuntimeIntent(_ intent:NativePersonalRuntimeWindow.Intent,
                                    startup:NativeRestoreApplicationStartup,resources:URL)throws {
        guard transitionTask==nil,restoreParent==nil,!stopping,host?.state == .running,
              let app=application else{throw NativeRestoreParentFailure.busy}
        _ = try app.personalRuntimeService()
        let identity=ObjectIdentifier(app)
        transitionTask=Task {[self] in
            do {try await runRuntimeIntent(intent,identity:identity,startup:startup,resources:resources)}
            catch is CancellationError {}
            catch {if !Task.isCancelled && !stopping {await runtimeError(error)}}
            transitionTask=nil
            if host?.state == .closed {stopping=true}
            if quitAfterTransition || stopping {
                quitAfterTransition=false
                RunLoop.main.perform(inModes:[.default,.common]){NSApp.terminate(nil)}
            }
        }
    }
    /// Only values survive between review and drain. A completed detached worker
    /// (including a non-cooperative cancellation) is joined before this returns.
    private func runtimeApplication(_ identity:ObjectIdentifier)throws->NativeCRMApplication {
        try Task.checkCancellation()
        guard !stopping,restoreParent==nil,host?.state == .running,
              let app=application,ObjectIdentifier(app)==identity else{throw CancellationError()}
        _ = try app.personalRuntimeService();return app
    }
    private func runtimeApproval(_ intent:NativePersonalRuntimeWindow.Intent,identity:ObjectIdentifier,
                                 startup:NativeRestoreApplicationStartup)async throws->NativePersonalRuntimeResumption.Approval? {
        let app=try runtimeApplication(identity),service=try app.personalRuntimeService()
        guard let plan=app.restoreStartupPlan,let personal=plan.personal else{throw NativeDBError.conflict}
        try NativePersonalRuntimeWork.assertCurrent(service:service,startup:startup,personal:personal,expected:plan.resumption)
        var settings=Set(plan.resumption?.settings ?? []),workers=plan.runtimeReview == nil ? Set(plan.resumption?.workers ?? []):[]
        let oldSettings=settings,oldWorkers=workers
        switch intent.action {
        case .configure:settings.insert(intent.group);workers.subtract(NativePersonalProviderStores.settingsAffectedGroups(for:intent.group))
        case .review:settings.insert(intent.group);workers.remove(intent.group)
        case .resume:settings.insert(intent.group);workers.insert(intent.group)
        case .stop:workers.remove(intent.group)
        }
        if settings==oldSettings && workers==oldWorkers && intent.action != .resume && plan.runtimeReview==nil{return nil}
        let stopped=oldWorkers.subtracting(workers).sorted()
        let confirm:(NativePersonalRuntimeResumption.Prompt)async throws->NativePersonalRuntimeResumption.Choice = {[weak self] prompt in
            guard let self else{throw CancellationError()}
            return try await self.confirmRuntimePolicy(prompt,identity:identity,stopped:stopped)
        }
        do {
            return try await NativePersonalRuntimeWork.approval(service:service,startup:startup,settings:settings,workers:workers,stores:Self.providerStores,confirm:confirm)
        } catch is NativePersonalRuntimeWork.DependencyFailure {
            guard intent.action != .resume else{throw NativeDBError.message("再開に必要な設定を確認してください。自動処理は再開していません。")}
            // No authority failure can enter this branch: Work rechecked the
            // unchanged owner/root/current record after the verifier failed.
            try NativePersonalRuntimeWork.assertCurrent(service:service,startup:startup,personal:personal,expected:plan.resumption)
            let accepted=try await runtimeQuestion(identity:identity,title:"ほかの連携設定も再確認が必要です",
                text:"設定の変更または期限切れが見つかりました。すべての自動処理を停止して、設定確認を続けますか？データの閲覧・編集は続けられます。",accept:"すべて停止して設定確認")
            guard accepted else{throw CancellationError()}
            return try await NativePersonalRuntimeWork.approval(service:service,startup:startup,settings:settings,workers:[],stores:Self.providerStores,confirm:{[weak self] prompt in
                guard let self else{throw CancellationError()}
                return try await self.confirmRuntimePolicy(prompt,identity:identity,stopped:oldWorkers.sorted())
            })
        }
    }
    private func confirmRuntimePolicy(_ prompt:NativePersonalRuntimeResumption.Prompt,
                                      identity:ObjectIdentifier,stopped:[NativePersonalRuntimeGroup])async throws->NativePersonalRuntimeResumption.Choice {
        let list=prompt.workers.map{ "・"+$0.title }.joined(separator:"\n")
        let stopText=stopped.isEmpty ? "":"停止する自動処理：\n"+stopped.map{"・"+$0.title}.joined(separator:"\n")+"\n\n"
        let text=stopText+(list.isEmpty ? "変更後はすべての自動処理を停止します。":"変更後に有効にする自動処理：\n"+list)+"\n\n復元前の処理は保留のままです。接続設定を開く許可だけでは処理を開始しません。"
        guard try await runtimeQuestion(identity:identity,title:"機能・連携の設定を変更しますか？",text:text,accept:"この内容で変更") else{throw CancellationError()}
        return .approve(subjectSHA256:prompt.subjectSHA256)
    }
    private func runtimeError(_ error:Error)async {
        guard let parent=application?.personalMainWindow,parent.attachedSheet==nil else{return}
        let alert=NSAlert();alert.messageText="機能・連携の確認を完了できませんでした"
        alert.informativeText=error.localizedDescription;alert.addButton(withTitle:"閉じる")
        _ = await withTaskCancellationHandler(operation:{await alert.beginSheetModal(for:parent)},onCancel:{
            Task {@MainActor in if alert.window.sheetParent != nil {parent.endSheet(alert.window,returnCode:.cancel)}}
        })
    }
    private func runtimeQuestion(identity:ObjectIdentifier,title:String,text:String,accept:String)async throws->Bool {
        let app=try runtimeApplication(identity)
        guard let parent=app.personalMainWindow,parent.attachedSheet==nil else{throw NativeRestoreParentFailure.busy}
        let alert=NSAlert();alert.messageText=title;alert.informativeText=text
        alert.addButton(withTitle:accept);alert.addButton(withTitle:"キャンセル")
        let answer=await withTaskCancellationHandler(operation:{await alert.beginSheetModal(for:parent)},onCancel:{
            Task {@MainActor in if alert.window.sheetParent != nil {parent.endSheet(alert.window,returnCode:.cancel)}}
        })
        _ = try runtimeApplication(identity)
        return answer == .alertFirstButtonReturn
    }
    private func runtimeIsolation(identity:ObjectIdentifier,startup:NativeRestoreApplicationStartup)async throws {
        let app=try runtimeApplication(identity),service=try app.personalRuntimeService()
        let status=try await NativePersonalRuntimeWork.isolation(service:service,startup:startup)
        guard status != .ready else{return}
        let note:String
        switch status {
        case .missing:note="復元前に登録された処理を、自動実行しない状態として保存します。"
        case .interrupted:note="途中で止まった復元前の処理の保全を続けます。"
        case .newRestoration:note="今回復元したデータについて、復元前の処理をあらためて保全します。"
        case .ready:return
        }
        guard try await runtimeQuestion(identity:identity,title:"復元前の処理を保留しますか？",
            text:note+"\n処理本文・送信結果・履歴は削除しません。この確認だけで処理は再開しません。",accept:"保留して確認を続ける") else{throw CancellationError()}
        _ = try runtimeApplication(identity)
        try await NativePersonalRuntimeWork.installIsolation(service:service,startup:startup,expected:status)
    }
    private func reviewRuntimeRequirement(_ requirement:NativePersonalRuntimeRequirement,identity:ObjectIdentifier,
                                          startup:NativeRestoreApplicationStartup)async throws {
        let app=try runtimeApplication(identity),service=try app.personalRuntimeService()
        let prompt=try await NativePersonalRuntimeWork.inspect(requirement,service:service,startup:startup,stores:Self.providerStores)
        _ = try runtimeApplication(identity)
        guard let parent=app.personalMainWindow,parent.attachedSheet==nil else{throw NativeRestoreParentFailure.busy}
        guard let choice=try await NativePersonalRuntimeRequirementWindow.choose(prompt:prompt,on:parent) else{throw CancellationError()}
        _ = try runtimeApplication(identity)
        try await NativePersonalRuntimeWork.review(prompt,choice:choice,service:service,startup:startup,stores:Self.providerStores)
    }
    private func runtimeMayDrain(_ identity:ObjectIdentifier)throws {
        guard try runtimeApplication(identity).confirmPersonalHostTermination() else{throw CancellationError()}
    }
    private func runRuntimeIntent(_ intent:NativePersonalRuntimeWindow.Intent,identity:ObjectIdentifier,
                                  startup:NativeRestoreApplicationStartup,resources:URL)async throws {
        // The helper's service/App locals have been released when the opaque
        // approval returns. The operation closure below captures neither.
        let approval=try await runtimeApproval(intent,identity:identity,startup:startup)
        if let approval {
            try runtimeMayDrain(identity)
            guard let host else{throw CancellationError()}
            try await host.transitionRuntimePolicy(approval) {startup,resources,permit in
                try await NativePersonalRuntimeWork.workspace(startup:startup,resources:resources,stores:Self.providerStores,approval:approval,permit:permit)
            }
        }
        try Task.checkCancellation()
        guard let identity=application.map(ObjectIdentifier.init),host?.state == .running else{throw CancellationError()}
        switch intent.action {
        case .configure:try runtimeApplication(identity).openPersonalSettings(intent.group)
        case .review:
            try await runtimeIsolation(identity:identity,startup:startup)
            for requirement in intent.group.requirements {
                try await reviewRuntimeRequirement(requirement,identity:identity,startup:startup)
            }
        case .resume,.stop:break
        }
    }
    private func show(_ error:Error) {
        let alert=NSAlert();alert.messageText="データを開けませんでした";alert.informativeText=error.localizedDescription
        alert.runModal()
    }
    private func endFailedLaunch(_ error:Error?)async {
        recoveryPrompt?.cancel();recoveryPrompt=nil
        await previousRecovery?.cancelAndDrain();previousRecovery=nil
        _ = await restoreChild?.cancelAndWait()
        await host?.stopAndDrain();host=nil
        if let error {show(error)}
        stopping=true
        RunLoop.main.perform(inModes:[.default,.common]){NSApp.terminate(nil)}
    }
    func application(_ application:NSApplication,open urls:[URL]) {
        for url in urls {
            if launchTask != nil,launchURLs.count<16,url.scheme?.lowercased()=="nextcrm-native",url.absoluteString.utf8.count<=8192 {launchURLs.append(url)}
            if let host {_ = host.receive(url)}
            else if earlyURLs.count<16,url.scheme?.lowercased()=="nextcrm-native",url.absoluteString.utf8.count<=8192 {earlyURLs.append(url)}
        }
    }
    func applicationDidBecomeActive(_ notification:Notification) {application?.applicationDidBecomeActive(notification)}
    func applicationWillTerminate(_ notification:Notification) {application?.applicationWillTerminate(notification)}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {host?.state == .running}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if stopping {return .terminateNow}
        if let parent=restoreParent,!parent.isExitArmed {
            if restoreCancellationTask==nil {
                restoreCancellationTask=Task {[self] in
                    await parent.cancelAndDrain();restoreCancellationTask=nil
                    RunLoop.main.perform(inModes:[.default,.common]){NSApp.terminate(nil)}
                }
            }
            return .terminateCancel
        }
        if launchTask != nil {recoveryPrompt?.cancel();previousRecovery?.cancel();restoreChild?.requestCancel();host?.cancel();launchTask?.cancel();return .terminateCancel}
        if transitionTask != nil {quitAfterTransition=true;transitionTask?.cancel();return .terminateCancel}
        if let recovery=previousRecovery {
            guard recoveryQuitTask==nil else{return .terminateCancel}
            guard application?.confirmPersonalHostTermination() != false else{return .terminateCancel}
            recoveryQuitTask=Task {[self] in
                await recovery.cancelAndDrain();previousRecovery=nil;host=nil
                recoveryQuitTask=nil;stopping=true
                RunLoop.main.perform(inModes:[.default,.common]){NSApp.terminate(nil)}
            }
            return .terminateCancel
        }
        if let application {return application.applicationShouldTerminate(sender)}
        host?.cancel();launchTask?.cancel()
        return .terminateCancel
    }
    override func responds(to selector:Selector!)->Bool {super.responds(to:selector) || application?.responds(to:selector)==true}
    override func forwardingTarget(for selector:Selector!)->Any? {
        if application?.responds(to:selector)==true {return application}
        return super.forwardingTarget(for:selector)
    }
}

/// A nonmodal owned startup panel: cancellation/close completes the same awaited
/// choice, so Quit never leaves a nested runModal loop holding the instance gate.
@MainActor final class NativePersonalPreviousRecoveryPrompt:NSObject,NSWindowDelegate {
    let window:NSPanel
    private var continuation:CheckedContinuation<Bool,Never>?
    private var used=false,canceled=false
    init(root:URL) {
        window=NSPanel(contentRect:NSRect(x:0,y:0,width:540,height:220),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        super.init();window.title="元データで再開";window.isReleasedWhenClosed=false;window.delegate=self
        let title=NSTextField(labelWithString:"復元前のデータで再開しますか？");title.font=NSFont.boldSystemFont(ofSize:16)
        let explanation=NSTextField(wrappingLabelWithString:"復元の切り替えが完了していません。保存された記録では、元のデータが選択されています。元の利用者と権限を確認して再開します。")
        let path=NSTextField(labelWithString:root.path);path.lineBreakMode = .byTruncatingMiddle;path.textColor = .secondaryLabelColor
        let cancel=NSButton(title:"キャンセル",target:self,action:#selector(cancelChoice));cancel.keyEquivalent="\u{1b}"
        let resume=NSButton(title:"元データで再開",target:self,action:#selector(resumeChoice));resume.keyEquivalent="\r"
        let buttons=NSStackView(views:[cancel,resume]);buttons.orientation = .horizontal;buttons.alignment = .centerY;buttons.spacing=12
        let stack=NSStackView(views:[title,explanation,path,buttons]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=18;stack.translatesAutoresizingMaskIntoConstraints=false
        window.contentView!.addSubview(stack);NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-24),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:24)])
    }
    func show()async->Bool {
        guard !used,!canceled,!Task.isCancelled else{return false};used=true
        return await withTaskCancellationHandler(operation:{
            await withCheckedContinuation {continuation in
                self.continuation=continuation
                if canceled || Task.isCancelled {finish(false);return}
                window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            }
        },onCancel:{Task {@MainActor in self.cancel()}})
    }
    func cancel(){canceled=true;finish(false)}
    @objc private func cancelChoice(){cancel()}
    @objc private func resumeChoice(){finish(true)}
    func windowShouldClose(_ sender:NSWindow)->Bool{cancel();return false}
    private func finish(_ accepted:Bool){let completion=continuation;continuation=nil;window.orderOut(nil);window.close();completion?.resume(returning:accepted)}
}
