import AppKit
import Darwin

#if !HELD_HOST_TESTING && !RESTORE_PARENT_TESTING && !RESTORE_APP_HOST
@main
#endif
final class NativeCRMApplication: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    private var personalHostConfigured=false
    private var personalPresented=false
    private var configuredRuntimeOwners=Set<String>()
    private var personalAuthorize:(()throws->Void)?
    private var personalRestoreReview:((NativeDataMaintenanceArtifact,NSWindow)throws->Void)?
    private var personalUseRestored:(()throws->Void)?
    private var personalRetainedRules:AnyObject?
    private var personalProviderReviewFactory:(()throws->NativePersonalProviderReview)?
    private var personalProviderReviewWindow:NativePersonalProviderReviewWindow?
    private var canReviewRestoredJobs:Bool {
        personalHostConfigured && effectPolicy?.plan.mode == .personalActiveLocal && personalProviderReviewFactory != nil
    }
    private var personalRuntimeAction:((NativePersonalRuntimeWindow.Intent)throws->Void)?
    private var personalRuntimeWindow:NativePersonalRuntimeWindow?
    private var personalRuntimeWorkflowAvailable:(()->Bool)?
    private var canPresentPersonalRuntimes:Bool {canManagePersonalRuntimes && (personalRuntimeWorkflowAvailable?() ?? true)}
    private var canManagePersonalRuntimes:Bool {
        personalHostConfigured && effectPolicy?.plan.mode == .personalActiveLocal && personalRuntimeAction != nil
    }
    private let restoreActivities=NativeRestoreParentActivities()
    private var restoreAdmissionClosed=false,restoreDrainCompleted=false
    typealias WorkspaceOpener = (NativeRestoreActivationRoot, URL) throws -> CRMService
    private let effectPolicy: NativeRestoreApplicationEffectPolicy?
    private let workspaceOpener: WorkspaceOpener?
    private var hostPreparationStarted=false,hostPresentationReady=false,hostDiscarded=false
    private var hostLaunchPending=false,hostLaunchCancelled=false
    private var hostLaunchCancellation:(()->Void)?
    private var firstWorkspaceRead:((Result<Void,Error>)->Void)?
    private var hostDiscardTask:Task<Void,Never>?
    /// The final AppHost must inject its retained Startup resolver's actual plan.
    /// Bare construction remains unresolved and cannot open a database.
    override init() { effectPolicy=nil;workspaceOpener=nil;super.init() }
    init(startupPlan: NativeRestoreApplicationStartupPlan, workspaceOpener: WorkspaceOpener? = nil,
         cancelHostLaunch:(()->Void)? = nil) throws {
        effectPolicy=try NativeRestoreApplicationEffectPolicy(startupPlan);self.workspaceOpener=workspaceOpener
        hostLaunchCancellation=cancelHostLaunch;super.init()
    }
    private var usesQAServices:Bool {
        #if PERSONAL_APP_QA
        return true
        #else
        return ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_MAIL_TEST_MODE"] != nil
        #endif
    }
    private var readOnlyWorkspace: Bool { effectPolicy?.readOnlyWorkspace ?? true }
    private func permits(_ id:String)->Bool {effectPolicy?.allows(id)==true}
    private func manual(_ ids:[String]=[])->Bool {
        guard !quitPreflight,!mcpTerminating,effectPolicy?.allowsManual(ids)==true else {status.stringValue=readOnlyWorkspace ? NativeRestoreApplicationEffectPolicy.heldMessage:NativeRestoreApplicationEffectPolicy.personalHeldMessage;return false};return true
    }
    private func manualLocal()->Bool {
        guard !restoreAdmissionClosed,!quitPreflight,!mcpTerminating,effectPolicy?.allowsMutation==true else {status.stringValue=NativeRestoreApplicationEffectPolicy.heldMessage;return false};return true
    }
    private var allowsExternalActions:Bool {effectPolicy?.allowsManual()==true}
    private func construct<T>(_ id:String,_ body:()throws->T) rethrows -> T? {
        guard permits(id) else{return nil}
        #if HELD_HOST_TESTING
        constructedForTesting.append(id)
        #endif
        guard let effectPolicy else{return nil};guard let value=try effectPolicy.construct(id,body) else{return nil};configuredRuntimeOwners.insert(id);return value
    }
    #if HELD_HOST_TESTING
    private var constructedForTesting:[String]=[]
    #endif
    #if RESTORE_APP_TESTING
    var hostReadProbeForTesting:(()throws->Void)?
    var hostPresentationReadyForTesting:Bool {hostPresentationReady}
    #endif
    #if HELD_HOST_TESTING
    @MainActor func prepareHeadlessForTesting(resources:URL) throws {
        try openPermittedWorkspace(resources:resources)
        try configurePermittedRuntimes(resources:resources)
        startPermittedWork(resources:resources);wakePermittedWork()
    }
    var effectStateForTesting:[String:Bool] {
        ["readonly":readOnlyWorkspace,"background":hasBackgroundWork,"mailFactory":mailRuntime != nil,
         "aiKeys":aiKeys != nil,"campaignFactory":campaignRuntime != nil,"pluginPresentation":pluginPresentationService != nil,
         "workspaceObserver":workspaceWakeObserver != nil,"maintenanceRecovery":maintenanceRecovery != nil,
         "maintenanceOperation":maintenanceRecoveryOperation != nil,"mcpSettings":mcpSettings != nil,
         "mcpStartup":mcpStartup != nil,"pluginsStartup":pluginsStartup != nil,"currencyStartup":currencyStartup != nil]
    }
    func buildHiddenWorkspaceForTesting() {makeWindow();displayModule();window.contentView?.layoutSubtreeIfNeeded()}
    var displayedRowsForTesting:Int {rows.count}
    var hiddenWorkspaceForTesting:Bool {window != nil && !window.isVisible}
    func selectFirstForTesting() {table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);selectionChanged()}
    var constructedIDsForTesting:[String] {constructedForTesting}
    var statusForTesting:String {status.stringValue}
    var hasChildForTesting:Bool {editor != nil || userAdministrationWindow != nil || userProfileWindow != nil || pluginsSettingsWindow != nil || mcpSettingsWindow != nil || documentsWindow != nil || invoiceWindow != nil || campaignsWindow != nil || orderWindow != nil}
    func listForTesting() throws -> Int {try service.list(module).total}
    @MainActor func wakeForTesting(resources:URL) {
        applicationDidBecomeActive(Notification(name:NSApplication.didBecomeActiveNotification))
        wakeMCPJobs();wakePlugins();resumeCampaignJobs();startPermittedWork(resources:resources)
    }
    func controlsForTesting() -> Bool {
        applyReadOnlyControls()
        return !create.isEnabled && !deleteButton.isEnabled && !importProducts.isEnabled && !moveUp.isEnabled && !moveDown.isEnabled && !orderSettings.isEnabled && !actions.isEnabled && !relations.isEnabled && !invoiceSettings.isEnabled && !pluginInfo.isEnabled && edit.title == "表示"
    }
    @MainActor func manualForTesting(_ record:NativeRecord) -> Int {
        let parent=NSPanel(contentRect:.zero,styleMask:[.titled],backing:.buffered,defer:true)
        let popup=NSPopUpButton(),button=NSButton(),item=NSMenuItem()
        showReports();openSearch(documentCandidates:true);showMCPSettings();showUserAdministration();showUserProfile()
        showCurrencyAdministration();showAdminAudit();showDataMaintenance();showCRMConfiguration();showCRMFunnelSettings();showCRMAutomationJobs();showPluginsSettings()
        showPluginInformation(.init(pluginID:"account-protection",title:"Fixture",location:.account(record["id"].string)),on:parent)
        openPluginRoute(item);navigateFromPlugin(.init(model:record.model,id:record["id"].string));showAPITokens()
        presentAISettings(on:parent);presentE2BSettings(on:parent);openEnrichment(contactID:nil);openEnrichmentHistory(contactID:nil)
        openTargetEnrichment(targetID:nil);openTargetEnrichmentHistory(targetID:nil);openTargetContacts(targetID:record["id"].string)
        showAIJobs();showGeneralMailAccounts();showRelatedMail(record);showMailSettings();showCalendarSettings();showCalendlySettings()
        showCampaignSettings();openPendingLink();openLinkPrompt();showCampaigns();showTemplates();openCRMTasks(parent:nil);openDocuments()
        newRecord();createProject();openProject(record);openProjectTasks(mine:false);openProjectDashboard();deleteRecord()
        approvalAction(popup);relationAction(popup);createInvoice(account:nil);openInvoice(nil,accountID:"");openInvoiceSettings(popup)
        createOrder(account:nil);openOrder(nil,accountID:"");openOrderSettings();moveSelected(button);openProductImport();confirmConversion(record,deal:true);openData()
        openEditor(nil)
        return 52
    }
    func readOnlyEditorForTesting(_ record:NativeRecord)throws->CRMEditor {try makeWorkspaceEditor(record,requestedReadOnly:false)}
    @MainActor func drainForTesting() async {stopBackgroundWork();await drainBackgroundWork();await drainMaintenanceRecovery()}
    #endif
    private var window: NSWindow!
    private var service: CRMService!
    private var module = CRMModule.all[0]
    private var linkedParent: NativeRecord?
    private var editor: CRMEditor?
    private var priceCheckWindow: CRMPriceCheckWindow?
    private var productImportWindow: CRMProductImportWindow?
    private var targetSpreadsheetWindow: NativeTargetSpreadsheetWindow?
    private var targetSelection = NativeTargetSpreadsheetSelection()
    private var applyingTargetSelection = false
    private let targetSelectedCount = NSTextField(labelWithString:"選択なし：現在の検索結果を書き出します")
    private let targetSelectPage = NSButton(title:"このページをすべて選択",target:nil,action:nil)
    private let targetClearSelection = NSButton(title:"選択を解除",target:nil,action:nil)
    private var targetSelectionControls = NSStackView()
    private var targetListWindow: CRMTargetListWindow?
    private var projectWindow: CRMProjectWindow?
    private var taskOverviewWindow: CRMTaskOverviewWindow?
    private var projectDashboardWindow: CRMProjectDashboardWindow?
    private var documentsWindow: CRMDocumentsWindow?
    private var crmTasksWindow: CRMAccountTasksWindow?
    private var leadJobsWindow: CRMInvoiceJobsWindow?
    private var templatesWindow: CRMTemplatesWindow?
    private var campaignsWindow: CRMCampaignsWindow?
    private var projectControls: NSStackView!
    private var invoiceWindow: CRMInvoiceWindow?
    private var invoiceRecords: CRMInvoiceRecordsWindow?
    private var mailSettingsWindow: CRMInvoiceMailSettingsWindow?
    private var mailRuntime: InvoiceMailRuntime!
    private var generalMailRuntime: NativeMailRuntime?
    private var generalMailAccountsWindow: NativeMailAccountsWindow?
    private var aiKeys: NativeAIKeys!
    private var personalProviderStores: NativePersonalProviderStores?
    // Supplied by root runtime UI integration; do not duplicate on merge.
    private var aiSettingsWindow: NativeAISettingsWindow?
    private var apiTokensWindow: NativeAPITokensWindow?
    private var mcpSettingsWindow: NativeMCPSettingsWindow?
    private var mcpSettings: NativeMCPSettingsStore?
    private var mcpRuntime: NativeMCPRuntime?
    private var mcpStartup: Task<Void, Never>?
    private var plugins: NativePluginsApplication?
    private var pluginsStartup: Task<Void, Never>?
    private var pluginsSettingsWindow: NativePluginsSettingsWindow?
    private var userAdministrationWindow: NativeUserAdministrationWindow?
    private var userProfileWindow: NativeUserAdministrationProfileWindow?
    private var crmConfigurationWindow: NativeCRMConfigurationWindow?
    private var crmFunnelSettingsWindow: NativeCRMFunnelSettingsWindow?
    private var caseStudyWindow: NativeAccountCaseStudyWindow?
    private var crmAutomationJobsWindow: NativeCRMAutomationJobsWindow?
    private var adminAuditWindow: NativeAdminAuditWindow?
    private var dataMaintenanceWindow: NativeDataMaintenanceWindow?
    private var dataMaintenanceClose: NativeSheetCloseWaiters?
    private var maintenanceRecovery: Task<Void, Never>?
    private var maintenanceRecoveryOperation: NativeDataMaintenanceOperation?
    private var quitPreflight = false, quitConfirmed = false
    private var currencyAdministrationWindow: NativeCurrencyAdministrationWindow?
    private var currencyRuntime: NativeCurrencyAdministrationRuntime?
    private var currencyStartup: Task<Void, Never>?
    private var aiCredentialCleanup: Task<Void, Never>?
    private var pluginPresentationService: NativePluginPresentationService?
    private var pluginStatusWindow: NativePluginPresentationWindow?
    private var pendingPluginTarget: NativePluginPresentation.RecordTarget?
    private var pluginPagesMenu: NSMenu?
    private let pluginInfo = NSPopUpButton(frame: .zero, pullsDown: true)
    private final class PluginMenuRoute: NSObject {
        let choice: NativePluginPresentationService.Choice
        weak var parent: NSWindow?
        init(_ choice: NativePluginPresentationService.Choice, parent: NSWindow?) { self.choice = choice; self.parent = parent }
    }
    private var mcpTerminating = false
    private var e2bSettingsWindow: NativeE2BSettingsWindow?
    private var aiRuntime: NativeEmbeddingRuntime?
    private var contactEnrichmentRuntime: NativeContactEnrichmentRuntime?
    private var targetEnrichmentRuntime: NativeTargetEnrichmentRuntime?
    private var targetEnrichmentEnvironment = NativeAIEnvironment(lookup: { _ in nil })
    private var aiJobsWindow: NativeAIJobsWindow?
    private var enrichmentRequestWindow: NativeContactEnrichmentRequestWindow?
    private var enrichmentHistoryWindow: NativeContactEnrichmentHistoryWindow?
    private var targetEnrichmentRequestWindow: NativeTargetEnrichmentRequestWindow?
    private var targetEnrichmentHistoryWindow: NativeTargetEnrichmentHistoryWindow?
    private var targetContactsWindow: NativeTargetContactsWindow?
    private var globalSearchWindow: NativeSearchWindow?
    private var reportsWindow: NativeReportsWindow?
    private var relatedMailWindow: NativeMailMailboxWindow?
    private var campaignRuntime: CampaignRuntime!
    private var campaignSettingsWindow: CRMCampaignRelaySettingsWindow?
    private var calendarSettingsWindow: GoogleCalendarSettingsWindow?
    private var calendarRuntime: GoogleCalendarRuntime?
    private var calendlyRuntime: CalendlyRuntime?
    private var calendlySettingsWindow: CalendlySettingsWindow?
    private var calendlyAPIRequest: CalendlyAPIClient.Request = CalendlyRelayClient.network
    private var calendlyRelayRequest: CalendlyRelayClient.Request = CalendlyRelayClient.network
    private var campaignDispatchRunner: InvoiceJobRunner?
    private var campaignMailRunner: InvoiceJobRunner?
    private var campaignSyncRunner: InvoiceJobRunner?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var campaignRelayRequest: CampaignRelayClient.Request = CampaignRelayClient.network
    private var invoiceRunner: InvoiceJobRunner?
    private var orderRunner: InvoiceJobRunner?
    private var projectRunner: InvoiceJobRunner?
    private var crmTaskRunner: InvoiceJobRunner?
    private var crmAutomationRuntime: NativeCRMAutomationRuntime?
    private var crmAutomationMailRunner: InvoiceJobRunner?
    private var leadRunner: InvoiceJobRunner?
    private var reportRunner: InvoiceJobRunner?
    private var reportReviewWindow:CRMJobReviewWindow?
    private var documentCleanupRunner: InvoiceJobRunner?
    private var documentProcessingRunner: InvoiceJobRunner?
    private var documentRecovery: Task<Void,Never>?
    private var orderJobsWindow: CRMInvoiceJobsWindow?
    private var linkInbox = NativeLinkInbox()
    private var projectLink: Result<NativeProjectTaskLink,Error>?
    private var crmSweepLink: Result<NativeCRMSweepLink,Error>?
    private var crmTaskLink: Result<NativeCRMTaskLink,Error>?
    private var leadLink: Result<NativeMCPLeadLink,Error>?
    private var contractLinkInbox = NativeCRMContractLinkInbox()
    private let invoiceStatus = NSPopUpButton(); private let invoiceType = NSPopUpButton()
    private var invoiceSort = InvoiceListSort()
    private let invoiceSortControl = NSPopUpButton()
    private let invoiceSettings = NSPopUpButton(frame:.zero,pullsDown:true)
    private var invoiceFilters: NSStackView!
    private var orderWindow: CRMOrderWindow?
    private var orderSettingsWindow: CRMOrderSettingsWindow?
    private var referencePicker: CRMReferencePicker?
    private let title = NSTextField(labelWithString: "取引先")
    private let subtitle = NSTextField(labelWithString: "")
    private let search = NSSearchField(); private let filter = NSPopUpButton()
    private let orderStatus = NSPopUpButton()
    private let orderOwner = NSButton(title:"担当者：すべて",target:nil,action:nil)
    private let clearOrderOwner = NSButton(title:"絞り込み解除",target:nil,action:nil)
    private let orderSettings = NSButton(title:"受注の設定…",target:nil,action:nil)
    private var orderFilters: NSStackView!
    private var orderOwnerID: SQLValue?
    private let table = NSTableView(); private let header = LightweightTableCell()
    private let count = NSTextField(labelWithString: "読み込み中…")
    private let status = NSTextField(labelWithString: "このMacに保存")
    private let create = NSButton(title:"新規登録",target:nil,action:nil)
    private let targetSpreadsheet = NSButton(title:"取り込み・書き出し…",target:nil,action:nil)
    private let importProducts = NSButton(title:"CSV取り込み…",target:nil,action:nil)
    private let moveUp = NSButton(title:"上へ",target:nil,action:nil); private let moveDown = NSButton(title:"下へ",target:nil,action:nil)
    private let edit = NSButton(title:"編集",target:nil,action:nil)
    private let historyButton = NSButton(title:"履歴",target:nil,action:nil)
    private let deleteButton = NSButton(title:"削除",target:nil,action:nil)
    private let activities = NSButton(title:"関連活動",target:nil,action:nil)
    private let actions = NSPopUpButton(frame:.zero,pullsDown:true)
    private let relations = NSPopUpButton(frame:.zero,pullsDown:true)
    private let previous = NSButton(title:"前へ",target:nil,action:nil); private let next = NSButton(title:"次へ",target:nil,action:nil)
    private var navigation: [NSButton] = []
    private var rows: [CRMListRow] = []; private var offset = 0; private var total = 0; private var version = 0
    private var pending: DispatchWorkItem?
    private let readsState = NSLock()
    private var readsStopped = false
    private let reads = MemoryBudget.queue(label:"local.nextcrm.native.crm-reads")
    private let memory = MemoryBudget()
    private var support: URL {
        if let policy=effectPolicy { return policy.plan.root.url }
        if let path = ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_DATA_DIR"] { return URL(fileURLWithPath:path,isDirectory:true) }
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NextCRMNative",isDirectory:true)
    }
    static func main() {
        #if PERSONAL_APP_HOST
        NativePersonalApplicationComposition.main()
        #else
        umask(0o077); let app = NSApplication.shared; let delegate = NativeCRMApplication()
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run(); withExtendedLifetime(delegate) {}
        #endif
    }
    /// Personal composition supplies the selected business identity separately
    /// from the macOS authority. The inherited restore ACK path remains unchanged.
    @MainActor func configurePersonalHost(authorize:@escaping ()throws->Void,
        reviewRestore:@escaping (NativeDataMaintenanceArtifact,NSWindow)throws->Void,
        useRestored:(()throws->Void)?, retainedRules:AnyObject?,
        reviewRestoredJobs:(()throws->NativePersonalProviderReview)? = nil,
        manageRuntimes:((NativePersonalRuntimeWindow.Intent)throws->Void)? = nil,
        runtimeWorkflowAvailable:(()->Bool)? = nil)throws {
        guard !personalHostConfigured,!hostPreparationStarted,workspaceOpener != nil else {
            throw NativeRestoreActivationFailure("personal.appComposition")
        }
        try authorize()
        personalAuthorize=authorize;personalRestoreReview=reviewRestore
        personalUseRestored=useRestored;personalRetainedRules=retainedRules
        personalProviderReviewFactory=effectPolicy?.plan.mode == .personalActiveLocal ? reviewRestoredJobs:nil
        personalRuntimeAction=effectPolicy?.plan.mode == .personalActiveLocal ? manageRuntimes:nil
        personalRuntimeWorkflowAvailable=runtimeWorkflowAvailable
        personalHostConfigured=true
    }
    var restoreStartupPlan:NativeRestoreApplicationStartupPlan? {effectPolicy?.plan}
    /// Borrow only while preparing a review. Callers must release this service
    /// and join its tasks before Host.transitionRuntimePolicy drains ownership.
    @MainActor func personalRuntimeService()throws->CRMService {
        guard personalHostConfigured,hostPresentationReady,personalPresented,!hostDiscarded,
              !restoreAdmissionClosed,!quitPreflight,!mcpTerminating,
              effectPolicy?.plan.mode == .personalActiveLocal,
              effectPolicy?.plan.personal?.phase == .bound,!readOnlyWorkspace,
              let authorize=personalAuthorize,let service,!service.db.isReadOnly else {
            throw NativeRestoreActivationFailure("personal.runtimeAppNotReady")
        }
        try authorize();try service.authenticated();return service
    }
    var personalMainWindow:NSWindow? {window}
    @MainActor func enablePersonalRestoredUse(_ use:@escaping ()throws->Void)throws {
        guard personalHostConfigured,hostPresentationReady,personalPresented,readOnlyWorkspace,
              !hostDiscarded,!quitPreflight,!mcpTerminating else {throw NativeRestoreActivationFailure("personal.notHeld")}
        personalUseRestored=use;installMenus()
    }
    @MainActor func personalRestoreReadiness(_ request:NativeRestoreHostStartupRequest,
                                           startup:NativeRestoreApplicationStartup)throws->NativeRestoreHostWorkspaceReadiness {
        guard personalHostConfigured,hostPresentationReady,personalPresented,!hostDiscarded,
              !quitPreflight,!mcpTerminating,readOnlyWorkspace,let policy=effectPolicy,
              policy.plan.mode == .approvedHandoff,policy.plan.selection==request.selection,
              policy.plan.permitted==["workspace.local"],policy.plan.held==request.held,
              let service,service.db.isReadOnly,let window,window.isVisible,
              table.numberOfRows==rows.count,!hasBackgroundWork,mailRuntime==nil,aiKeys==nil,
              campaignRuntime==nil,plugins==nil,mcpSettings==nil,workspaceWakeObserver==nil,
              maintenanceRecovery==nil,mcpStartup==nil,pluginsStartup==nil,currencyStartup==nil,
              !create.isEnabled,!deleteButton.isEnabled,!actions.isEnabled,!relations.isEnabled else {
            throw NativeRestoreActivationFailure("personal.heldReadiness")
        }
        try service.authenticated()
        try NativeRestoreHostStartupCodec.current(request,control:startup.control,lease:startup.lease)
        struct Evidence:Encodable {
            let selection:NativeRestoreActivationSelection,ownerID:String,model:String
            let visibleRows:Int,totalRows:Int,databaseReadOnly:Bool,windowVisible:Bool
        }
        let evidence=Evidence(selection:request.selection,ownerID:service.identity.id,model:module.model,
            visibleRows:rows.count,totalRows:total,databaseReadOnly:true,windowVisible:window.isVisible)
        return .init(selection:request.selection,workspacePrepared:true,presentationPrepared:true,
            writeAdmissionClosed:true,started:["workspace.local"],held:request.held,
            evidenceSHA256:try NativeRestoreHostStartupCodec.hash(evidence,domain:"NextCRM.personal.held-presentation.v1"))
    }
    @MainActor func personalPreviousRecoveryReadiness(_ context:NativeRestoreActivationContext,
                                                     startup:NativeRestoreApplicationStartup)throws->NativeRestoreActivationStartup {
        guard personalHostConfigured,hostPresentationReady,personalPresented,firstWorkspaceRead==nil,
              !hostDiscarded,!quitPreflight,!mcpTerminating,!restoreAdmissionClosed,!readOnlyWorkspace,
              let policy=effectPolicy,policy.plan.mode == .previousPolicy || policy.plan.mode == .personalActiveLocal,
              policy.plan.root==context.previous.root,policy.plan.selection==context.previous,
              policy.plan.activationID==context.activationID,policy.plan.mode==startup.plan.mode,
              policy.plan.permitted==startup.plan.permitted,policy.plan.held==startup.plan.held,
              policy.plan.personal==startup.plan.personal,
              configuredRuntimeOwners==Set(policy.plan.permitted),
              let service,!service.db.isReadOnly,let authorize=personalAuthorize,
              let window,window.isVisible,table.numberOfRows==rows.count else {
            throw NativeRestoreActivationFailure("personal.previousPresentationNotReady")
        }
        try authorize();try service.authenticated();try startup.control.validate();try startup.lease.validate()
        guard startup.lease.identity.uid==geteuid(),
              try startup.control.read("active-root.json",as:NativeRestoreActivationSelection.self)==context.previous,
              try NativeRestoreActivationControl.root(context.previous.root.url)==context.previous.root,
              let journal=try startup.control.read("activation.json",as:NativeRestoreActivationJournal.self),
              journal.phase == .restoringPrevious || journal.phase == .previousRestored,
              journal.previous==context.previous,journal.candidate==context.candidate,journal.activationID==context.activationID,
              journal.previousRunning==context.previousRunning,journal.runtimeCatalog==context.runtimeCatalog,
              journal.seal==context.seal else {throw NativeRestoreActivationFailure("personal.previousPresentationAuthority")}
        struct Evidence:Encodable {
            let selection:NativeRestoreActivationSelection,lease:NativeRestoreHostLeaseIdentity,uid:UInt32
            let ownerID:String,ownerRole:String,model:String,configured:[String]
            let visibleRows:Int,totalRows:Int,firstListLoaded:Bool,windowVisible:Bool,databaseReadOnly:Bool
        }
        let evidence=Evidence(selection:context.previous,lease:startup.lease.identity,uid:geteuid(),
            ownerID:service.identity.id,ownerRole:service.identity.role,model:module.model,
            configured:configuredRuntimeOwners.sorted(),visibleRows:rows.count,totalRows:total,
            firstListLoaded:hostPresentationReady,windowVisible:window.isVisible,databaseReadOnly:service.db.isReadOnly)
        let exact=configuredRuntimeOwners==Set(context.previousRunning)
        let localReview=policy.plan.mode == .personalActiveLocal && policy.plan.personal?.phase == .bound &&
            policy.plan.runtimeReview != nil && configuredRuntimeOwners==Set(["workspace.local"]) &&
            context.previousRunning.contains("workspace.local")
        guard exact || localReview else{throw NativeRestoreActivationFailure("personal.previousPresentationPolicy")}
        // The receipt reports only real configured owners. The coordinator must
        // separately obtain explicit confirmation before accepting local-only.
        return .init(started:configuredRuntimeOwners.sorted(),held:exact ? []:context.previousRunning.filter{$0 != "workspace.local"}.sorted(),
            evidenceSHA256:try NativeRestoreHostStartupCodec.hash(evidence,domain:"NextCRM.personal.previous-presentation.v1"))
    }
    @MainActor func confirmPersonalHostTermination()->Bool {
        if hostDiscarded{return true}
        guard personalHostConfigured,!mcpTerminating else{return false}
        if quitPreflight && !quitConfirmed{return false}
        if !quitConfirmed {
            quitPreflight=true
            guard confirmClose() else{quitPreflight=false;reload();return false}
        }
        quitConfirmed=false;showShutdownProgress();return true
    }
    @MainActor func preparePersonalWorkspace(resources:URL)async throws {
        guard personalHostConfigured,!hostPreparationStarted,firstWorkspaceRead==nil,
              let authorize=personalAuthorize else {throw NativeRestoreActivationFailure("personal.appComposition")}
        try authorize();try Task.checkCancellation()
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation {(continuation:CheckedContinuation<Void,Error>) in
                firstWorkspaceRead={continuation.resume(with:$0)}
                do {try prepareWorkspaceForHost(resources:resources,presentImmediately:false)}
                catch {finishFirstWorkspaceRead(.failure(error))}
            }
        },onCancel:{[weak self] in
            Task {@MainActor in self?.finishFirstWorkspaceRead(.failure(CancellationError()))}
        })
        try Task.checkCancellation();try authorize()
        guard let service,!hostDiscarded,!quitPreflight,!mcpTerminating else {throw CancellationError()}
        try service.authenticated()
        applyReadOnlyControls();window.contentView?.layoutSubtreeIfNeeded()
        hostPresentationReady=true
    }
    @MainActor func presentPersonalWorkspace(resources:URL)throws {
        guard personalHostConfigured,hostPresentationReady,!personalPresented,!hostDiscarded,
              !quitPreflight,let authorize=personalAuthorize,let service,let window else {
            throw NativeRestoreActivationFailure("personal.presentationNotReady")
        }
        try authorize();try service.authenticated()
        personalPresented=true;window.makeKeyAndOrderFront(nil);window.makeFirstResponder(table)
        if ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_DATA_DIR"] == nil {NSApp.activate(ignoringOtherApps:true)}
        memory.settle();wakePermittedWork();openPendingLink();startPermittedWork(resources:resources)
    }
    @MainActor func receivePersonalURL(_ url:URL) {receiveLink(url.absoluteString)}
    @MainActor func terminateAfterPersonalDiscard() {
        guard hostDiscarded else{return}
        quitConfirmed=true
        RunLoop.main.perform(inModes:[.default,.common]){NSApp.terminate(nil)}
    }
    @MainActor func authorizePersonalRestore()throws {
        guard personalHostConfigured,!hostDiscarded,let authorize=personalAuthorize,
              let service,service.identity.role=="admin" else {throw NativeRestoreParentFailure.authority}
        try authorize();try service.authenticated()
    }
    @MainActor func authorizeRestoreBusinessIdentity()throws {
        guard personalHostConfigured,!hostDiscarded,let service,service.identity.role=="admin" else {
            throw NativeRestoreParentFailure.authority
        }
        try service.authenticated()
    }
    @MainActor func personalRuntimeInventory()throws->[String] {
        try authorizeRestoreBusinessIdentity()
        // Catalog IDs are admitted runtime owners, including dormant/completed
        // one-shot owners. The separate drain receipt counts actual live tasks.
        guard let policy=effectPolicy,configuredRuntimeOwners==Set(policy.plan.permitted) else {
            throw NativeRestoreActivationFailure("personal.runtimeInventory")
        }
        return configuredRuntimeOwners.sorted()
    }
    @MainActor @objc private func useRestoredPersonalWorkspace() {
        guard !restoreAdmissionClosed,!quitPreflight,!mcpTerminating,let window,
              window.attachedSheet==nil,let use=personalUseRestored else{return}
        do {try personalAuthorize?();try use()} catch {showError(error)}
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let resources = Bundle.main.resourceURL!
            try prepareWorkspaceForHost(resources:resources,presentImmediately:true)
        } catch {
            let alert = NSAlert(); alert.messageText = "データを開けませんでした"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil)
        }
    }
    /// A throwing composition path shared by ordinary launch and the restore
    /// host. The host does not call the delegate's alert-and-terminate wrapper.
    @MainActor private func prepareWorkspaceForHost(resources:URL,presentImmediately:Bool)throws {
        guard !hostPreparationStarted,!hostDiscarded else{throw NativeRestoreActivationFailure("app.alreadyPrepared")}
        hostPreparationStarted=true
        try openPermittedWorkspace(resources:resources)
        try configurePermittedRuntimes(resources:resources)
        installMenus();makeWindow();if permits("ui.external-actions") {configuredRuntimeOwners.insert("ui.external-actions")};displayModule()
        if presentImmediately {
            window.makeKeyAndOrderFront(nil);window.makeFirstResponder(table)
            if ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_DATA_DIR"] == nil {NSApp.activate(ignoringOtherApps:true)}
            memory.settle();wakePermittedWork();openPendingLink();startPermittedWork(resources:resources)
        }
    }
    @MainActor private func finishFirstWorkspaceRead(_ result:Result<Void,Error>) {
        let completion=firstWorkspaceRead;firstWorkspaceRead=nil;completion?(result)
    }
    /// Only the authenticated inherited host calls this. The initial bounded
    /// query must succeed before the real window is shown or an ACK is formed.
    @MainActor func prepareRestoredWorkspace(request:NativeRestoreHostStartupRequest,
                                            startup:NativeRestoreApplicationStartup,
                                            resources:URL)async throws->NativeRestoreHostWorkspaceReadiness {
        guard !hostPreparationStarted,!hostDiscarded,firstWorkspaceRead==nil else {
            throw NativeRestoreActivationFailure("app.alreadyPrepared")
        }
        guard hostLaunchCancellation != nil else {throw NativeRestoreActivationFailure("app.launchCancellationRequired")}
        guard let policy=effectPolicy,policy.plan.mode == .approvedHandoff,
              startup.plan.mode == .approvedHandoff,policy.plan.root==startup.plan.root,
              policy.plan.selection==request.selection,startup.plan.selection==request.selection,
              policy.plan.activationID==request.activationID,
              policy.plan.permitted==["workspace.local"],
              policy.plan.held==request.held,readOnlyWorkspace,workspaceOpener != nil else {
            throw NativeRestoreActivationFailure("app.restoredComposition")
        }
        try NativeRestoreHostStartupCodec.current(request,control:startup.control,lease:startup.lease)
        try Task.checkCancellation()
        hostLaunchPending=true
        do {
            try await withTaskCancellationHandler(operation:{
                try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                    firstWorkspaceRead={continuation.resume(with:$0)}
                    do {try prepareWorkspaceForHost(resources:resources,presentImmediately:false)}
                    catch {finishFirstWorkspaceRead(.failure(error))}
                }
            },onCancel:{[weak self] in
                Task { @MainActor in self?.finishFirstWorkspaceRead(.failure(CancellationError())) }
            })
            try Task.checkCancellation()
            guard let service,service.db.isReadOnly,service.identity.role=="admin",
                  service.identity.id==request.approval.authorization.principalID,
                  !hasBackgroundWork,mailRuntime==nil,aiKeys==nil,campaignRuntime==nil,
                  pluginPresentationService==nil,mcpSettings==nil,workspaceWakeObserver==nil,
                  maintenanceRecovery==nil,maintenanceRecoveryOperation==nil,
                  mcpStartup==nil,pluginsStartup==nil,currencyStartup==nil,
                  !quitPreflight,!mcpTerminating,!restoreAdmissionClosed,!hostDiscarded else {
                throw NativeRestoreActivationFailure("app.workspaceNotHeld")
            }
            try service.authenticated()
            try NativeRestoreHostStartupCodec.current(request,control:startup.control,lease:startup.lease)
            applyReadOnlyControls();window.contentView?.layoutSubtreeIfNeeded()
            window.makeKeyAndOrderFront(nil);window.makeFirstResponder(table);window.displayIfNeeded()
            guard window.isVisible,window.contentView != nil,table.numberOfRows==rows.count,
                  !create.isEnabled,!deleteButton.isEnabled,!actions.isEnabled,!relations.isEnabled else {
                throw NativeRestoreActivationFailure("app.presentationNotReady")
            }
            hostPresentationReady=true
            struct Evidence:Encodable {
                let selection:NativeRestoreActivationSelection
                let principalID:String,model:String
                let visibleRows:Int,totalRows:Int
                let databaseReadOnly:Bool,windowVisible:Bool,firstListLoaded:Bool
            }
            let evidence=Evidence(selection:request.selection,principalID:service.identity.id,model:module.model,
                visibleRows:rows.count,totalRows:total,databaseReadOnly:service.db.isReadOnly,
                windowVisible:window.isVisible,firstListLoaded:true)
            return .init(selection:request.selection,workspacePrepared:true,presentationPrepared:hostPresentationReady,
                writeAdmissionClosed:readOnlyWorkspace && service.db.isReadOnly,started:["workspace.local"],held:request.held,
                evidenceSHA256:try NativeRestoreHostStartupCodec.hash(evidence,domain:"NextCRM.restore.app-presentation.v1"))
        } catch {
            await discardRestoredWorkspace()
            throw error
        }
    }
    /// Called after the host's final asynchronous authentication, before ACK.
    /// Cached readiness does not override a closed/cancelled presentation.
    @MainActor func revalidateRestoredWorkspace(request:NativeRestoreHostStartupRequest,
                                               startup:NativeRestoreApplicationStartup)throws {
        try NativeRestoreHostStartupCodec.current(request,control:startup.control,lease:startup.lease)
        try validateLiveRestoredPresentation(request:request)
    }
    @MainActor private func validateLiveRestoredPresentation(request:NativeRestoreHostStartupRequest)throws {
        guard hostLaunchPending,!hostLaunchCancelled,!hostDiscarded,hostPresentationReady,
              let policy=effectPolicy,policy.plan.selection==request.selection,
              policy.plan.permitted==["workspace.local"],policy.plan.held==request.held,
              let service,service.db.isReadOnly,service.identity.id==request.approval.authorization.principalID,
              service.identity.role=="admin",!hasBackgroundWork,!quitPreflight,!mcpTerminating,
              let window,window.isVisible,table.numberOfRows==rows.count,
              !create.isEnabled,!deleteButton.isEnabled,!actions.isEnabled,!relations.isEnabled else {
            throw NativeRestoreActivationFailure("app.presentationInvalidated")
        }
        try service.authenticated()
    }
    /// The caller has observed the exact helper's normal exit and durable active
    /// journal; the UI may now use its normal closing behavior.
    @MainActor func completeRestoredHostLaunch(request:NativeRestoreHostStartupRequest,
                                             startup:NativeRestoreApplicationStartup)throws {
        try startup.control.validate();try startup.lease.validate()
        guard try startup.control.read("active-root.json",as:NativeRestoreActivationSelection.self)==request.selection,
              let journal=try startup.control.read("activation.json",as:NativeRestoreActivationJournal.self),
              journal.phase == .active,journal.activationID==request.activationID,
              journal.candidate==request.selection,journal.permittedRuntimes==["workspace.local"],
              journal.heldRuntimes==request.held else {throw NativeRestoreActivationFailure("app.activationNotComplete")}
        try validateLiveRestoredPresentation(request:request)
        hostLaunchPending=false;hostLaunchCancellation=nil
    }
    private func cancelPendingRestoreLaunch() {
        guard hostLaunchPending else{return}
        hostLaunchCancelled=true;hostPresentationReady=false
        window?.orderOut(nil);hostLaunchCancellation?()
    }
    /// Joins prepared App work, but never claims that every DB alias has gone.
    /// The startup exchange's private lease remains pinned until process exit.
    @MainActor func discardRestoredWorkspace()async {
        if let task=hostDiscardTask {await task.value;return}
        if hostDiscarded{return}
        hostDiscarded=true;hostPresentationReady=false;hostLaunchPending=false;hostLaunchCancellation=nil
        quitPreflight=true;restoreAdmissionClosed=true
        finishFirstWorkspaceRead(.failure(CancellationError()))
        stopBackgroundWork();maintenanceRecoveryOperation?.cancel();maintenanceRecovery?.cancel()
        mcpStartup?.cancel();pluginsStartup?.cancel();currencyStartup?.cancel()
        let task=Task { @MainActor in
            await mcpStartup?.value;await mcpRuntime?.stop()
            await pluginsStartup?.value;await plugins?.runtime.stop()
            await currencyStartup?.value;await currencyRuntime?.stop()
            await drainPersonalProviderReview()
            await drainDataMaintenance();await drainMaintenanceRecovery();await drainBackgroundWork()
            if let observer=workspaceWakeObserver {NSWorkspace.shared.notificationCenter.removeObserver(observer);workspaceWakeObserver=nil}
            if let window {NativeSheetTermination.dismiss(in:window);window.orderOut(nil);window.delegate=nil}
            personalProviderReviewFactory=nil;personalRuntimeAction=nil;personalRuntimeWorkflowAvailable=nil
            service=nil
        }
        hostDiscardTask=task;await task.value
    }
    private func openPermittedWorkspace(resources:URL) throws {
            guard let policy=effectPolicy,policy.hasWorkspace else {throw NativeRestoreActivationFailure("app.unresolvedPolicy")}
            guard try NativeRestoreActivationControl.root(policy.plan.root.url)==policy.plan.root else {throw NativeRestoreActivationFailure("app.rootChanged")}
            if let workspaceOpener {
                let opened=try workspaceOpener(policy.plan.root,resources)
                guard !readOnlyWorkspace || opened.db.isReadOnly else {throw NativeRestoreActivationFailure("app.readOnlyDatabaseRequired")}
                guard opened.db.url.resolvingSymlinksInPath().standardizedFileURL==support.appendingPathComponent("crm.sqlite").resolvingSymlinksInPath().standardizedFileURL else {throw NativeRestoreActivationFailure("app.workspaceBinding")}
                guard try NativeRestoreActivationControl.root(policy.plan.root.url)==policy.plan.root else {throw NativeRestoreActivationFailure("app.rootChanged")}
                try opened.authenticated();service=opened;configuredRuntimeOwners.insert("workspace.local")
            } else {
                guard policy.plan.mode == .ordinary else {throw NativeRestoreActivationFailure("app.validatedWorkspaceRequired")}
                // Ordinary bootstrap is unchanged. Restore identity/authentication
                // must be supplied by AppHost, never inferred from localActor here.
                let db = try NativeDatabase(url:support.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
                let identity = try CRMService.bootstrap(db,resources:resources)
                _ = try LegacyMigration.run(source:support.appendingPathComponent("accounts.sqlite"),database:db,actor:identity)
                service = CRMService(db:db,identity:identity);configuredRuntimeOwners.insert("workspace.local")
            }
    }
    private func startPermittedWork(resources:URL) {
            if permits("plugins.scheduler"), let runtime = plugins?.runtime {
                configuredRuntimeOwners.insert("plugins.scheduler")
                pluginsStartup = Task { guard !Task.isCancelled else { return }; await runtime.start() }
            }
            if permits("currency.ecb"), let runtime = currencyRuntime {
                currencyStartup = Task { guard !Task.isCancelled else { return }; await runtime.start() }
            }
            if permits("mcp.server"), let runtime = mcpRuntime {
                mcpStartup = Task { @MainActor [weak self] in
                    do { _ = try await runtime.start() }
                    catch is CancellationError {}
                    catch { self?.status.stringValue = "MCP接続を開始できませんでした。接続設定を確認してください。" }
                    self?.mcpStartup = nil
                }
            }
            if effectPolicy?.allowsAny(NativeRestoreRuntimeCatalog.heldAutomatic)==true { workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] note in self?.applicationDidBecomeActive(note) } }
            startMaintenanceRecovery(resources:resources)
    }
    private func providerStores() -> NativePersonalProviderStores {
        if let value = personalProviderStores { return value }
        let value = NativePersonalProviderStores(service: service, usesQAServices: usesQAServices)
        personalProviderStores = value; return value
    }
    var personalSettingsGroups: Set<NativePersonalRuntimeGroup> {
        [.mailAccounts,.resendNotifications,.scheduledReports,.campaigns,.googleCalendar,.calendly,
         .aiDocumentsAndSearch,.aiContacts,.aiTargets,.aiKeyCleanup,.plugins,.crmAutomation,.currency,.mcp]
    }
    private static let aiSettingsGroups: [NativePersonalRuntimeGroup] = [.aiDocumentsAndSearch,.aiContacts,.aiTargets,.aiKeyCleanup]
    private static let resendSettingsGroups: [NativePersonalRuntimeGroup] = [.resendNotifications,.scheduledReports,.campaigns]
    private func canOpenSettings(_ groups: [NativePersonalRuntimeGroup]) -> Bool {
        !hostDiscarded && !restoreAdmissionClosed && !quitPreflight && !mcpTerminating &&
            groups.contains { effectPolicy?.allowsSettings($0) == true }
    }
    private func settings(_ groups: [NativePersonalRuntimeGroup]) -> Bool {
        guard canOpenSettings(groups),let group=groups.first(where:{effectPolicy?.allowsSettings($0)==true}) else { status.stringValue = "この連携の設定は、復元後の利用設定から確認してください。"; return false }
        if effectPolicy?.plan.mode == .personalActiveLocal,
           effectPolicy?.allowsAny(NativePersonalProviderStores.settingsAffectedGroups(for:group).flatMap(\.runtimeIDs)) == true {
            guard let personalRuntimeAction else { status.stringValue="この設定を変更するには、関連する処理を停止して確認する必要があります。";return false }
            do { try personalRuntimeAction(.init(group:group,action:.configure)) } catch { showError(error) }
            return false
        }
        return true
    }
    /// Called only after the host has recomposed this App with a validated
    /// settings grant. This entry never grants a worker or a provider capability.
    func openPersonalSettings(_ group: NativePersonalRuntimeGroup) throws {
        guard personalSettingsGroups.contains(group),canOpenSettings([group]),let window,window.attachedSheet == nil else {
            throw NativeDBError.message("この連携の設定を開けません。開いている画面を閉じ、復元後の利用設定を確認してください。")
        }
        try service.authenticated()
        switch group {
        case .mailAccounts: showGeneralMailAccounts()
        case .resendNotifications,.scheduledReports: showMailSettings()
        case .campaigns: showCampaignSettings()
        case .googleCalendar: showCalendarSettings()
        case .calendly: showCalendlySettings()
        case .aiDocumentsAndSearch,.aiContacts,.aiTargets,.aiKeyCleanup: presentAISettings(on:window)
        case .plugins: showPluginsSettings()
        case .crmAutomation: showCRMFunnelSettings()
        case .currency: showCurrencyAdministration()
        case .mcp: showMCPSettings()
        case .documents,.maintenance: throw NativeDBError.conflict
        }
    }
    private func wakeSettingsWorker(_ id: String, _ action: () -> Void) {
        guard !hostDiscarded,!restoreAdmissionClosed,!quitPreflight,!mcpTerminating else { return }
        effectPolicy?.wake(id,action)
    }
    @MainActor private func configurePermittedRuntimes(resources: URL) throws {
        guard let policy = effectPolicy, policy.hasWorkspace, let service else { throw NativeRestoreActivationFailure("app.unresolvedPolicy") }
        let db = service.db, stores = providerStores()
        let mailDependencies = ["mail.invoice","mail.orders","mail.projects","mail.crm-tasks","mail.crm-automation","mail.leads","mail.reports","mail.general","campaign.dispatch","campaign.delivery","campaign.relay","plugins.host","plugins.scheduler","ui.external-actions"]
        if policy.allowsAny(mailDependencies) { mailRuntime = try InvoiceMailRuntime(db: db, service: service, settingsStore: try stores.invoiceMail()) }
        let qa = usesQAServices
        if let mailRuntime {
            plugins = try construct("plugins.host") { try NativePluginsApplication(service: service, mail: mailRuntime) }
            if let plugins { pluginPresentationService = NativePluginPresentationService(service: service, host: plugins.host) }
        }
        currencyRuntime = construct("currency.ecb") { NativeCurrencyAdministrationRuntime(db: db, transport: qa ? NativeCurrencyAdministrationQA.fetch : NativeCurrencyAdministrationECBTransport.fetch) }
        if policy.allowsAny(["ai.embedding","ai.contacts","ai.targets","credentials.ai-cleanup","mcp.server","ui.external-actions"]) {
            aiKeys = try stores.aiKeys()
        }
        if let aiKeys {
            aiCredentialCleanup = construct("credentials.ai-cleanup") {
                Task.detached(priority:.utility) { guard !Task.isCancelled else { return }; _ = try? aiKeys.cleanup() }
            }
            let generateAI: NativeEmbeddingWorker.Generate = qa ? NativeAIQAServices.generate : { try await NativeEmbeddingClient(apiKey: $1).generate($0, allowWhitespace: true) }
            let summarizeAI: NativeDocumentAIWorker.Summary = qa ? NativeAIQAServices.summarize : { try await NativeOpenAIChatClient(apiKey: $1).summary(excerpt: $0) }
            let classifyAI: NativeDocumentAIWorker.Classify = qa ? NativeAIQAServices.classify : { try await NativeOpenAIChatClient(apiKey: $3).classification(name: $0, summary: $1, excerpt: $2) }
            aiRuntime = construct("ai.embedding") { NativeEmbeddingRuntime(db: db, store: aiKeys.store, environment: aiKeys.environment, generate: generateAI, summarize: summarizeAI, classify: classifyAI) }
            let enrichContact: NativeContactEnrichmentWorker.Enrich = qa ? NativeAIQAServices.enrich : NativeEnrichmentOrchestrator.contactProvider
            contactEnrichmentRuntime = construct("ai.contacts") { NativeContactEnrichmentRuntime(db: db, store: aiKeys.store, environment: aiKeys.environment, enrich: enrichContact) }
            targetEnrichmentEnvironment = qa ? NativeAIQAServices.targetEnvironment(aiKeys.environment) : aiKeys.environment
            targetEnrichmentRuntime = construct("ai.targets") { NativeTargetEnrichmentRuntime(db: db, store: aiKeys.store, environment: targetEnrichmentEnvironment,
                review: qa ? NativeAIQAServices.targetReview : NativeTargetEnrichmentProvider.review,
                agent: qa ? NativeAIQAServices.targetAgent : NativeTargetEnrichmentProvider.agent) }
        }
        aiRuntime?.onError = { [weak self] in self?.status.stringValue = NativeEmbeddingJobs.message($0) }
        contactEnrichmentRuntime?.onError = { [weak self] in self?.status.stringValue = NativeEmbeddingJobs.message($0) }
        targetEnrichmentRuntime?.onError = { [weak self] in self?.status.stringValue = NativeEmbeddingJobs.message($0) }
        generalMailRuntime = try construct("mail.general") {
            qa ? NativeMailRuntime(db:db,store:try stores.mailAccounts(),makeClient:{ _,_ in throw NativeMailQAServices.disabled },send:{ _ in throw NativeMailQAServices.disabled },recoverTemporary:{}) : NativeMailRuntime(db:db,store:try stores.mailAccounts())
        }
        generalMailRuntime?.onError = { [weak self] in self?.status.stringValue = NativeMailJobs.message($0) }
        if policy.allowsAny(["campaign.dispatch","campaign.delivery","campaign.relay","ui.external-actions"]), let mailRuntime {
            let relayStore = try stores.campaignRelay()
            if qa { campaignRelayRequest = CampaignRelayQACredentials.request }
            campaignRuntime = CampaignRuntime(db:db,mailStore:mailRuntime.store,mailRequest:mailRuntime.request,relayStore:relayStore,allowLoopbackHTTP:qa,relayRequest:campaignRelayRequest)
            let dispatch = campaignRuntime.dispatch, campaignMail = campaignRuntime.mail, campaignSync = campaignRuntime.sync
            campaignDispatchRunner = construct("campaign.dispatch") { InvoiceJobRunner(db:db,events:CampaignWorkflow.dispatchEvents,runNext:{try await dispatch.runNext()}) }
            campaignMailRunner = construct("campaign.delivery") { InvoiceJobRunner(db:db,events:[CampaignWorkflow.sendStepEvent],runNext:{try await campaignMail.runNext()}) }
            campaignSyncRunner = construct("campaign.relay") { InvoiceJobRunner(db:db,events:[CampaignRelayJobs.event],runNext:{try await campaignSync.runNext()}) }
        }
        let calendarRequest: GoogleCalendarOAuth.Request = qa ? { _ in throw NativeDBError.message("検証モードでは実際のGoogleに接続しません。") } : GoogleCalendarSyncWorker.network
        calendarRuntime = try construct("calendar.google") { GoogleCalendarRuntime(db:db,store:try stores.googleCalendar(),request:qa ? calendarRequest : nil) }
        calendarRuntime?.onError = { [weak self] error in self?.status.stringValue = GoogleCalendarSyncWorker.message(error) }
        calendlyRuntime = try construct("calendar.calendly") {
            let store = try stores.calendly()
            if let test = store as? CalendlyQAServices { calendlyAPIRequest = test.provider; calendlyRelayRequest = CalendlyQAServices.relay }
            return CalendlyRuntime(db:db,store:store,allowLoopbackHTTP:qa,apiRequest:calendlyAPIRequest,relayRequest:qa ? calendlyRelayRequest : nil)
        }
        calendlyRuntime?.onError = { [weak self] in self?.status.stringValue = CalendlyJobWorker.message($0) }
        if let mailRuntime {
            invoiceRunner = construct("mail.invoice") { InvoiceJobRunner(db:db,worker:mailRuntime.worker) }
            let orderWorker=mailRuntime.orderWorker, crmTaskWorker=mailRuntime.crmTaskWorker, leadWorker=mailRuntime.leadWorker, projectWorker=mailRuntime.projectWorker
            orderRunner = construct("mail.orders") { InvoiceJobRunner(db:db,events:CRMService.orderJobEvents,runNext:{try await orderWorker.runNext()}) }
            crmTaskRunner = construct("mail.crm-tasks") { InvoiceJobRunner(db:db,events:CRMService.crmTaskJobEvents,runNext:{try await crmTaskWorker.runNext()}) }
            leadRunner = construct("mail.leads") { InvoiceJobRunner(db:db,events:[NativeMCPLeads.assignedEvent],runNext:{try await leadWorker.runNext()}) }
            projectRunner = construct("mail.projects") { InvoiceJobRunner(db:db,events:CRMService.projectJobEvents,runNext:{try await projectWorker.runNext()}) }
            crmAutomationMailRunner = construct("mail.crm-automation") { makeAutomationMailRunner(db: db, mailRuntime: mailRuntime) }
            reportRunner = construct("mail.reports") {
                let reportStore=mailRuntime.store
                let worker=ReportMailWorker(db:db,account:{
                    guard let account=try reportStore.load(interactive:false) else {throw NativeDBError.message("メール送信の設定がありません。管理者が差出人とAPIキーを設定してください。")};return account
                },request:mailRuntime.request)
                return InvoiceJobRunner(db:db,events:[NativeReportQueue.event],nextDate:{try db.nextReportJobDate()},runNext:{try await worker.runNext()})
            }
        }
        crmAutomationRuntime = construct("crm.automation") { NativeCRMAutomationRuntime(db: db, environment: .init(appURL: nil)) }
        crmAutomationRuntime?.onError = { [weak self] error in self?.status.stringValue = error.localizedDescription }
        documentCleanupRunner = construct("documents.cleanup") { let worker=DocumentFileCleanupWorker(db:db);return InvoiceJobRunner(db:db,events:DocumentFileCleanupWorker.events,runNext:{try await worker.runNext()}) }
        documentProcessingRunner = construct("documents.processing") { let worker=DocumentProcessingWorker(db:db);return InvoiceJobRunner(db:db,events:DocumentProcessingWorker.events,runNext:{try await worker.runNext()}) }
        for runner in backgroundJobRunners { runner.onError = { [weak self] error in self?.status.stringValue=error.localizedDescription } }
        documentRecovery = construct("documents.recovery") {
            let worker=DocumentFileCleanupWorker(db:db)
            let exportRecovery=NativeDocumentExportRecoveryWorker(service:service)
            return Task { @MainActor [weak self] in
                do { _ = try await worker.recoverAbandonedFiles() }
                catch { if !Task.isCancelled { self?.status.stringValue=error.localizedDescription } }
                guard !Task.isCancelled else { return }
                do { try await exportRecovery.recover() }
                catch { if !Task.isCancelled { self?.status.stringValue=error.localizedDescription } }
            }
        }
        if policy.allows("mcp.server"), let aiKeys {
            let mcpSecrets = try stores.mcpSecretStore()
            mcpSettings=NativeMCPSettingsStore(service:service,secretStore:mcpSecrets)
            let enrichmentSecrets=aiKeys.store
            mcpRuntime = construct("mcp.server") { NativeMCPRuntime(db:db,catalogURL:resources.appendingPathComponent("MCPToolCatalog.json"),secretStore:mcpSecrets,
                enrichmentStore:{_ in enrichmentSecrets},enrichmentEnvironment:targetEnrichmentEnvironment,
                authorizeUserDirectory:{secret in {session in
                    let configuration=try NativeMCPSessionAuth.Configuration(secret:Data(secret.utf8),secureCookies:false)
                    let decision=try session.withAccess{try NativeMCPSessionAuth.userDirectoryDecision(cookie:NativeMCPRequestContext.cookie,db:$0.db,configuration:configuration)};_ = try decision.get()
                }},wakeJobs:{[weak self] in await MainActor.run{self?.wakeMCPJobs()}}) }
        }
    }
    func applicationDidBecomeActive(_ notification:Notification) {guard !quitPreflight,!mcpTerminating else{return};wakePlugins();wakePermittedWork()}

    func applicationWillTerminate(_ notification: Notification) { stopBackgroundWork(); if let workspaceWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    @MainActor private func confirmClose() -> Bool { personalRuntimeWindow?.confirmDiscard() != false && personalProviderReviewWindow?.confirmDiscard() != false && targetSpreadsheetWindow?.confirmDiscard() != false && caseStudyWindow?.confirmDiscard() != false && productImportWindow?.confirmDiscard() != false && targetListWindow?.confirmDiscard() != false && apiTokensWindow?.confirmDiscard() != false && adminAuditWindow?.confirmDiscard() != false && currencyAdministrationWindow?.confirmDiscard() != false && userAdministrationWindow?.confirmDiscard() != false && userProfileWindow?.confirmDiscard() != false && crmConfigurationWindow?.confirmDiscard() != false && crmFunnelSettingsWindow?.confirmDiscard() != false && crmAutomationJobsWindow?.confirmDiscard() != false && pluginsSettingsWindow?.confirmDiscard() != false && mcpSettingsWindow?.confirmDiscard() != false && leadJobsWindow?.confirmDiscard() != false && reportsWindow?.confirmDiscard() != false && reportReviewWindow?.confirmDiscard() != false && e2bSettingsWindow?.confirmDiscard() != false && targetContactsWindow?.confirmDiscard() != false && aiSettingsWindow?.confirmDiscard() != false && relatedMailWindow?.confirmDiscard() != false && generalMailAccountsWindow?.confirmDiscard() != false && editor?.confirmDiscard() != false && calendlySettingsWindow?.confirmDiscard() != false && calendarSettingsWindow?.confirmDiscard() != false && campaignSettingsWindow?.confirmDiscard() != false && campaignsWindow?.confirmDiscard() != false && templatesWindow?.confirmDiscard() != false && crmTasksWindow?.confirmDiscard() != false && documentsWindow?.confirmDiscard() != false && projectWindow?.confirmDiscard() != false && taskOverviewWindow?.confirmDiscard() != false && projectDashboardWindow?.confirmDiscard() != false && mailSettingsWindow?.confirmDiscard() != false && invoiceWindow?.confirmDiscard() != false && invoiceRecords?.confirmDiscard() != false && orderWindow?.confirmDiscard() != false && orderSettingsWindow?.confirmDiscard() != false && orderJobsWindow?.confirmDiscard() != false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if hostLaunchPending {cancelPendingRestoreLaunch();return .terminateCancel}
        if mcpTerminating { return .terminateLater }
        // A reentrant OS request while a confirmation alert is running must
        // not open a second alert or override that pending user decision.
        if quitPreflight && !quitConfirmed { return .terminateCancel }
        if !quitConfirmed {
            quitPreflight = true
            guard confirmClose() else { quitPreflight = false; reload(); return .terminateCancel }
        }
        quitConfirmed = false
        guard hasBackgroundWork || restoreActivities.pendingCount>0 || personalRuntimeWindow != nil || personalProviderReviewWindow != nil || dataMaintenanceWindow != nil || targetSpreadsheetWindow != nil || maintenanceRecovery != nil else { return .terminateNow }
        mcpTerminating = true
        stopBackgroundWork()
        showShutdownProgress()
        let startup = mcpStartup; startup?.cancel()
        let pluginStartup = pluginsStartup; pluginStartup?.cancel()
        let currencyStartup = currencyStartup; currencyStartup?.cancel()
        maintenanceRecoveryOperation?.cancel(); maintenanceRecovery?.cancel()
        let runtime = mcpRuntime, pluginRuntime = plugins?.runtime
        let currencyRuntime = currencyRuntime
        Task { @MainActor in
            await drainPersonalProviderReview()
            await drainDataMaintenance()
            await drainMaintenanceRecovery()
            if let window { NativeSheetTermination.dismiss(in:window) }
            await startup?.value
            await runtime?.stop()
            await pluginStartup?.value
            await pluginRuntime?.stop()
            await currencyStartup?.value
            await currencyRuntime?.stop()
            await drainBackgroundWork()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    private func makeAutomationMailRunner(db: NativeDatabase, mailRuntime: InvoiceMailRuntime) -> InvoiceJobRunner {
        let store = mailRuntime.store
        let worker = NativeCRMSweepMailWorker(db: db, account: {
            guard let account = try store.load(interactive: false) else {
                throw NativeDBError.message("メール送信の設定がありません。管理者が差出人とAPIキーを設定してください。")
            }
            return account
        }, request: mailRuntime.request)
        return InvoiceJobRunner(db: db, events: NativeCRMSweepJobs.mailEvents, runNext: { try await worker.runNext() })
    }
    @MainActor private func wakeMCPJobs() {
        guard permits("mcp.server"),!quitPreflight,!mcpTerminating,let policy=effectPolicy else{return}
        wakePlugins()
        policy.wake("mail.leads"){leadRunner?.kick()};policy.wake("mail.orders"){orderRunner?.kick()}
        policy.wake("mail.projects"){projectRunner?.kick()};policy.wake("mail.crm-tasks"){crmTaskRunner?.kick()}
        policy.wake("crm.automation"){crmAutomationRuntime?.resume()};policy.wake("mail.crm-automation"){crmAutomationMailRunner?.kick()}
        policy.wake("mail.reports"){reportRunner?.kick()};policy.wake("documents.cleanup"){documentCleanupRunner?.kick()}
        policy.wake("documents.processing"){documentProcessingRunner?.kick()};resumeCampaignJobs()
        policy.wake("calendar.google"){calendarRuntime?.resume()};policy.wake("ai.embedding"){aiRuntime?.resume()}
        policy.wake("ai.contacts"){contactEnrichmentRuntime?.resume()};policy.wake("ai.targets"){targetEnrichmentRuntime?.resume()}
    }
    private func wakePlugins() {
        guard !quitPreflight, !mcpTerminating else { return }
        if permits("plugins.scheduler"), let runtime = plugins?.runtime { Task { await runtime.wake() } }
        if permits("currency.ecb"), let runtime = currencyRuntime { Task { await runtime.wake() } }
    }
    private var hasBackgroundWork: Bool {
        !backgroundJobRunners.isEmpty || mcpRuntime != nil || plugins != nil || currencyRuntime != nil ||
        calendarRuntime != nil || calendlyRuntime != nil || generalMailRuntime != nil || aiRuntime != nil ||
        contactEnrichmentRuntime != nil || targetEnrichmentRuntime != nil || crmAutomationRuntime != nil || documentRecovery != nil || aiCredentialCleanup != nil
    }
    private var backgroundJobRunners:[InvoiceJobRunner] {
        [invoiceRunner,orderRunner,projectRunner,crmTaskRunner,crmAutomationMailRunner,leadRunner,reportRunner,
         documentCleanupRunner,documentProcessingRunner,campaignDispatchRunner,
         campaignMailRunner,campaignSyncRunner].compactMap{$0}
    }
    @MainActor private func stopBackgroundWork() {
        restoreActivities.sealForShutdown()
        readsState.lock(); readsStopped = true; readsState.unlock()
        pending?.cancel(); pending = nil; version += 1
        targetSpreadsheetWindow?.stop()
        for runner in backgroundJobRunners { runner.stop() }
        crmAutomationRuntime?.stop()
        calendarRuntime?.stop(); calendlyRuntime?.stop(); generalMailRuntime?.stop()
        aiRuntime?.stop(); contactEnrichmentRuntime?.stop(); targetEnrichmentRuntime?.stop()
        documentRecovery?.cancel(); aiCredentialCleanup?.cancel()
    }
    @MainActor private func drainBackgroundWork() async {
        // All queues were fenced before the first await. Cancellation requests
        // alone do not prove that a transport's final receipt/file write ended.
        for runner in backgroundJobRunners { await runner.stopAndDrain() }
        await crmAutomationRuntime?.stopAndDrain()
        await calendarRuntime?.stopAndDrain(); await calendlyRuntime?.stopAndDrain()
        await generalMailRuntime?.stopAndDrain(); await aiRuntime?.stopAndDrain()
        await contactEnrichmentRuntime?.stopAndDrain(); await targetEnrichmentRuntime?.stopAndDrain()
        await documentRecovery?.value; await aiCredentialCleanup?.value
        await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
            reads.async(flags:.barrier) { continuation.resume() }
        }
        await restoreActivities.drainForShutdown()
    }
    @MainActor private func wakePermittedWork() {
        guard !quitPreflight,!mcpTerminating,let policy=effectPolicy else{return}
        policy.wake("mail.invoice"){invoiceRunner?.kick()};policy.wake("mail.orders"){orderRunner?.kick()}
        policy.wake("mail.projects"){projectRunner?.kick()};policy.wake("mail.crm-tasks"){crmTaskRunner?.kick()}
        policy.wake("crm.automation"){crmAutomationRuntime?.resume()};policy.wake("mail.crm-automation"){crmAutomationMailRunner?.kick()}
        policy.wake("mail.leads"){leadRunner?.kick()};policy.wake("mail.reports"){reportRunner?.kick()}
        policy.wake("documents.cleanup"){documentCleanupRunner?.kick()};policy.wake("documents.processing"){documentProcessingRunner?.kick()}
        resumeCampaignJobs()
        policy.wake("calendar.google"){calendarRuntime?.resume()};policy.wake("calendar.calendly"){calendlyRuntime?.resume()}
        policy.wake("mail.general"){generalMailRuntime?.resume()};policy.wake("ai.embedding"){aiRuntime?.resume()}
        policy.wake("ai.contacts"){contactEnrichmentRuntime?.resume()};policy.wake("ai.targets"){targetEnrichmentRuntime?.resume()}
    }
    private func applyReadOnlyControls() {
        guard readOnlyWorkspace else{return}
        for button in [create,deleteButton,importProducts,targetSpreadsheet,moveUp,moveDown,orderSettings] {button.isEnabled=false}
        actions.isEnabled=false;relations.isEnabled=false;invoiceSettings.isEnabled=false;pluginInfo.isEnabled=false
        edit.title="表示";edit.isEnabled=rows.indices.contains(table.selectedRow)
        projectControls?.subviews.compactMap{$0 as? NSControl}.forEach{$0.isEnabled=false}
        status.stringValue=NativeRestoreApplicationEffectPolicy.heldMessage
    }
    func validateMenuItem(_ item:NSMenuItem)->Bool {
        let groups: [NativePersonalRuntimeGroup]?
        switch item.action {
        case #selector(showGeneralMailAccounts): groups = [.mailAccounts]
        case #selector(showMailSettings): groups = Self.resendSettingsGroups
        case #selector(showCampaignSettings): groups = [.campaigns]
        case #selector(showCalendarSettings): groups = [.googleCalendar]
        case #selector(showCalendlySettings): groups = [.calendly]
        case #selector(showAISettings): groups = Self.aiSettingsGroups
        case #selector(showMCPSettings),#selector(showAPITokens): groups = [.mcp]
        case #selector(showPluginsSettings): groups = [.plugins]
        default: groups = nil
        }
        if let groups { return canOpenSettings(groups) }
        let manualGroup:NativePersonalRuntimeGroup?
        switch item.action {
        case #selector(showAIJobs):manualGroup = .aiDocumentsAndSearch
        case #selector(showBulkEnrichment),#selector(showEnrichmentHistory):manualGroup = .aiContacts
        case #selector(showBulkTargetEnrichment),#selector(showTargetEnrichmentHistory):manualGroup = .aiTargets
        case #selector(showCRMAutomationJobs):manualGroup = .crmAutomation
        default:manualGroup=nil
        }
        if let group=manualGroup {
            return !hostDiscarded && !restoreAdmissionClosed && !quitPreflight && !mcpTerminating && effectPolicy?.allowsManualGroup(group)==true
        }
        if [#selector(showGlobalSearch),#selector(showDocumentSearch)].contains(item.action) {
            return !hostDiscarded && !restoreAdmissionClosed && !quitPreflight && !mcpTerminating && effectPolicy?.allowsMutation==true
        }
        if item.action == #selector(showUserAdministration),personalHostConfigured {return false}
        if item.action == #selector(showPersonalRuntimes) {
            return canPresentPersonalRuntimes && !hostDiscarded && !restoreAdmissionClosed && !quitPreflight && !mcpTerminating
        }
        if item.action == #selector(showPersonalProviderReview) {
            return canReviewRestoredJobs && !hostDiscarded && !restoreAdmissionClosed && !quitPreflight && !mcpTerminating
        }
        if item.action == #selector(useRestoredPersonalWorkspace) {
            return personalUseRestored != nil && !restoreAdmissionClosed && !quitPreflight && !mcpTerminating
        }
        if !readOnlyWorkspace,!allowsExternalActions, [#selector(showMCPSettings),#selector(showPluginsSettings),#selector(showAPITokens),#selector(showAISettings),#selector(showAIJobs),#selector(showGeneralMailAccounts),#selector(showMailSettings),#selector(showCampaignSettings),#selector(showCalendarSettings),#selector(showCalendlySettings),#selector(showBulkEnrichment),#selector(showEnrichmentHistory),#selector(showBulkTargetEnrichment),#selector(showTargetEnrichmentHistory),#selector(showGlobalSearch),#selector(showDocumentSearch),#selector(showCRMAutomationJobs)].contains(item.action) {return false}
        guard readOnlyWorkspace else{return true}
        return [#selector(about),#selector(requestQuit),#selector(editRecord),#selector(refresh),#selector(focusSearch),#selector(openGuide)].contains(item.action)
    }
    private func showShutdownProgress() {
        func disable(_ view:NSView) {
            (view as? NSControl)?.isEnabled = false
            for child in view.subviews { disable(child) }
        }
        func disableWindow(_ target:NSWindow) {
            target.makeFirstResponder(nil); target.ignoresMouseEvents = true
            if let content = target.contentView { disable(content) }
            if let sheet = target.attachedSheet { disableWindow(sheet) }
        }
        if let window { disableWindow(window) }
        func disableMenu(_ menu:NSMenu) {
            menu.autoenablesItems = false
            for item in menu.items { item.isEnabled = false; if let child = item.submenu { disableMenu(child) } }
        }
        if let menu = NSApp.mainMenu { disableMenu(menu) }
        status.stringValue = "実行中の処理が終わるのを待っています…"
    }
    @MainActor private func drainDataMaintenance() async {
        await targetSpreadsheetWindow?.stopAndDrain()
        guard let controller = dataMaintenanceWindow, let closeWaiters = dataMaintenanceClose else { return }
        await closeWaiters.wait { controller.dismissForNavigation() }
    }
    private func startMaintenanceRecovery(resources:URL) {
        guard permits("maintenance.recovery") else{return}
        guard maintenanceRecovery == nil, !quitPreflight, !mcpTerminating,
              let service, service.identity.role == "admin" else { return }
        let controller = NativeDataMaintenanceController(service:service,resources:resources)
        let operation = NativeDataMaintenanceOperation()
        configuredRuntimeOwners.insert("maintenance.recovery")
        maintenanceRecoveryOperation = operation
        // File traversal and removal stay off the main actor. Only one bounded
        // result page is retained; every page revalidates the current authority.
        let worker = Task.detached(priority:.utility) { () -> String? in
            do {
                var cursor:String?, pending = 0, failed = 0
                repeat {
                    try Task.checkCancellation()
                    let page = try controller.recoverStaging(after:cursor,limit:100,operation:operation)
                    for item in page.items {
                        if item.status == .pending { pending += 1 }
                        if item.status == .failed { failed += 1 }
                    }
                    if !page.hasMore { break }
                    guard let next = page.nextCursor, next != cursor else {
                        throw NativeDBError.message("以前の作業用ファイルの確認を続行できませんでした。")
                    }
                    cursor = next
                    await Task.yield()
                } while true
                try Task.checkCancellation()
                guard pending + failed > 0 else { return nil }
                return "以前の作業用ファイルで確認が必要な記録が\(pending + failed)件あります。確認できないファイルは残しています。"
            } catch is CancellationError { return nil }
            catch {
                if operation.cancelled || Task.isCancelled { return nil }
                return "以前の作業用ファイルの確認を完了できませんでした。確認できないファイルは残しています。"
            }
        }
        maintenanceRecovery = Task { @MainActor [weak self] in
            let message = await withTaskCancellationHandler(operation:{ await worker.value },onCancel:{
                operation.cancel(); worker.cancel()
            })
            guard let self else { return }
            self.maintenanceRecovery = nil; self.maintenanceRecoveryOperation = nil
            if let message, !Task.isCancelled, !self.quitPreflight, !self.mcpTerminating {
                self.status.stringValue = message
            }
        }
    }
    private func drainMaintenanceRecovery() async {
        maintenanceRecoveryOperation?.cancel()
        let task = maintenanceRecovery; task?.cancel()
        await task?.value
    }
    @MainActor @objc private func requestQuit() {
        if hostLaunchPending {cancelPendingRestoreLaunch();return}
        guard !quitPreflight, !mcpTerminating else { return }
        quitPreflight = true
        guard confirmClose() else { quitPreflight = false; reload(); return }
        quitConfirmed = true
        Task { @MainActor in
            await drainPersonalProviderReview()
            await drainDataMaintenance()
            // An OS termination request may have joined the same drain. It
            // owns the remaining shutdown and application reply in that case.
            guard !mcpTerminating else { return }
            if let window { NativeSheetTermination.dismiss(in:window) }
            NativeSheetTermination.scheduleApplicationQuit { [weak self] in
                guard let self, !self.mcpTerminating else { return }
                NSApp.terminate(nil)
                // If AppKit declines the request, never reuse an earlier
                // approval after the user has returned to editing.
                if !self.mcpTerminating { self.quitConfirmed = false; self.quitPreflight = false }
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if hostLaunchPending {cancelPendingRestoreLaunch();return false}
        guard !restoreAdmissionClosed else{return false}
        // Use the asynchronous termination path so an in-progress backup or
        // restore preparation can finish cancellation and release its files.
        if dataMaintenanceWindow != nil || targetSpreadsheetWindow != nil { requestQuit(); return false }
        return confirmClose()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        // Multiple incoming URLs coalesce to the last navigation, keeping the
        // backlog bounded and leaving any current editing sheet untouched.
        if let url = urls.last { receiveLink(url.absoluteString) }
    }
    func windowDidEndSheet(_ notification: Notification) {
        // Let the sheet completion release its controller before opening another.
        DispatchQueue.main.async { [weak self] in self?.openPendingLink() }
    }
    private func receiveLink(_ text: String) { guard !restoreAdmissionClosed else{return};
        guard !readOnlyWorkspace else {status.stringValue=NativeRestoreApplicationEffectPolicy.heldMessage;return}
        let host = URLComponents(string:text.trimmingCharacters(in:.whitespacesAndNewlines))?.host?.lowercased()
        crmTaskLink = nil; leadLink = nil; crmSweepLink = nil; contractLinkInbox = NativeCRMContractLinkInbox()
        if host == "contracts" { linkInbox = NativeLinkInbox(); projectLink = nil; contractLinkInbox.receive(text) }
        else if host == "opportunities" || host == "target-lists" { linkInbox = NativeLinkInbox(); projectLink = nil; crmSweepLink = Result { try NativeCRMSweepLink(text:text) } }
        else if host == "leads" { linkInbox = NativeLinkInbox(); projectLink = nil; leadLink = Result { try NativeMCPLeadLink(text:text) } }
        else if host == "crm-tasks" { linkInbox = NativeLinkInbox(); projectLink = nil; crmTaskLink = Result { try NativeCRMTaskLink(text:text) } }
        else if host == "tasks" {
            linkInbox = NativeLinkInbox(); projectLink = Result { try NativeProjectTaskLink(text:text) }
        } else { projectLink = nil; linkInbox.receive(text) }
        if let window {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
            if window.attachedSheet != nil { status.stringValue = "NextCRMのリンクを受け取りました。現在の画面を閉じると開きます。" }
        }
        openPendingLink()
    }
    private func openPendingLink() { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard !quitPreflight, !mcpTerminating else { return }
        let ready = service != nil && window != nil && window.attachedSheet == nil && editor == nil && orderWindow == nil && invoiceWindow == nil && projectWindow == nil && taskOverviewWindow == nil && projectDashboardWindow == nil
        do {
            if let link=try contractLinkInbox.take(ready:ready) {
                let record=try service.contractFromLink(link)
                guard let target=CRMModule.find("crm_Contracts") else {throw NativeDBError.conflict}
                module=target;linkedParent=nil;search.stringValue="";filter.selectItem(at:0);offset=0;displayModule()
                openEditor(record,readOnly:(try? service.assertAccess("crm_Contracts",id:link.contractID,write:true)) == nil)
                return
            }
            if ready, let pending = crmSweepLink {
                crmSweepLink = nil; let link = try pending.get(); let record = try service.crmSweepRecord(from:link)
                guard let target = CRMModule.find(record.model) else { throw NativeDBError.conflict }
                module = target; linkedParent = nil; search.stringValue = ""; filter.selectItem(at:0); offset = 0; displayModule()
                if link.destination == .targetList {
                    let controller = CRMTargetListWindow(list:record,service:service); targetListWindow = controller
                    window.beginSheet(controller.window) { [weak self] _ in guard let self else { return }; self.targetListWindow = nil; self.reload(selected:record["id"]); self.memory.settle() }
                } else { openEditor(record,readOnly:(try? service.assertAccess(record.model,id:link.id,write:true)) == nil) }
                return
            }
            if ready, let pending = leadLink {
                leadLink = nil; let link = try pending.get(); let record = try service.leadFromLink(link)
                guard let target = CRMModule.find("crm_Leads") else { throw NativeDBError.conflict }
                module = target; linkedParent = nil; search.stringValue = ""; filter.selectItem(at:0); offset = 0; displayModule()
                openEditor(record,readOnly:(try? service.assertAccess("crm_Leads",id:link.leadID,write:true)) == nil)
                return
            }
            if ready, let pending = crmTaskLink {
                crmTaskLink = nil; let link = try pending.get(); _ = try service.crmTaskFromLink(link)
                let controller = try CRMAccountTasksWindow(service:service); crmTasksWindow = controller
                window.beginSheet(controller.window) { [weak self] _ in self?.crmTasksWindow = nil; self?.reload(); self?.memory.settle() }
                DispatchQueue.main.async { [weak controller] in controller?.openTask(link.taskID) }
                return
            }
            if ready, let pending = projectLink {
                projectLink = nil; let link = try pending.get(); let access = try service.projectTaskFromLink(link)
                module = .projects; linkedParent = nil; search.stringValue = ""; filter.selectItem(at:0); offset = 0; displayModule()
                let controller = CRMTaskOverviewWindow(service:service,mine:access.board == nil); taskOverviewWindow = controller
                window.beginSheet(controller.window) { [weak self] _ in guard let self else { return }; self.taskOverviewWindow = nil; self.reload(); self.memory.settle() }
                DispatchQueue.main.async { [weak controller] in controller?.openTask(link.taskID) }
                return
            }
            guard let link = try linkInbox.take(ready:ready) else { return }
            let record = try service.orderFromLink(link)
            module = .orders; linkedParent = nil; search.stringValue = ""; filter.selectItem(at:0); offset = 0
            orderOwnerID = nil; orderOwner.title = "担当者：すべて"; orderStatus.selectItem(at:0)
            displayModule(); openOrder(record,accountID:record["accountId"].string)
        } catch { showError(error) }
    }
    private func campaignAIService() -> CampaignAIService? {
        guard effectPolicy?.allowsManual(["ai.embedding"])==true,let aiKeys else {return nil}
        var ai = CampaignAIService(keys: aiKeys)
        if (usesQAServices) {
            ai.generate = { prompt, key in
                try await Task.sleep(nanoseconds: 600_000_000)
                if key.hasPrefix("qa-reject") { throw NativeAIError(message: "検証用APIキーの拒否を再現しました。") }
                return CampaignAIDraft(subject: "新サービスのご案内", html: "<p style=\"color:#225588\">{{company}} {{last_name}}様</p><p>検証用のご案内です。サービスの詳細をご確認ください。</p>")
            }
        }
        return ai
    }
    @objc private func openLinkPrompt() { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "NextCRMのリンクから開く"
        alert.informativeText = "通知メールのNextCRMリンクを貼り付けてください。"
        let field = NSTextField(frame:NSRect(x:0,y:0,width:560,height:26)); field.placeholderString = "nextcrm-native://crm-tasks/…"; field.setAccessibilityLabel("NextCRMのリンク")
        alert.accessoryView = field; alert.addButton(withTitle:"開く"); alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            DispatchQueue.main.async { [weak self] in self?.receiveLink(field.stringValue) }
        }
        alert.window.makeFirstResponder(field)
    }
    private func installMenus() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [(String,Selector?,String)]) {
            let top = NSMenuItem(); top.submenu = NSMenu(title:title); main.addItem(top)
            for (label,selector,key) in items { if personalHostConfigured && selector == #selector(showUserAdministration) {continue}; if label.isEmpty { top.submenu!.addItem(.separator()) } else { let item = NSMenuItem(title:label,action:selector,keyEquivalent:key); if selector == #selector(requestQuit) { item.target = self }; top.submenu!.addItem(item) } }
        }
        menu("NextCRM Native",[("NextCRM Nativeについて",#selector(about),""),("自分のプロフィール…",#selector(showUserProfile),""),("AI連携の設定…",#selector(showAISettings),""),("APIトークン…",#selector(showAPITokens),""),("MCP接続の設定…",#selector(showMCPSettings),""),("連携・プラグインの設定…",#selector(showPluginsSettings),""),("AI検索の処理…",#selector(showAIJobs),""),("メールアカウント…",#selector(showGeneralMailAccounts),""),("通知メール送信の設定…",#selector(showMailSettings),","),("キャンペーンの受信窓口…",#selector(showCampaignSettings),""),("Googleカレンダーの接続…",#selector(showCalendarSettings),""),("Calendlyの予約連携…",#selector(showCalendlySettings),""),("",nil,""),("NextCRM Nativeを隠す",#selector(NSApplication.hide(_:)),"h"),("NextCRM Nativeを終了",#selector(requestQuit),"q")])
        menu("ファイル",[("新規登録",#selector(newRecord),"n"),("編集",#selector(editRecord),"e"),("リンクから開く…",#selector(openLinkPrompt),"l"),("",nil,""),("データフォルダを開く",#selector(openData),""),("閉じる",#selector(NSWindow.performClose(_:)),"w")])
        if personalUseRestored != nil || canReviewRestoredJobs || canManagePersonalRuntimes {
            var items:[(String,Selector?,String)]=[]
            if personalUseRestored != nil {items.append(("復元したデータを使う…",#selector(useRestoredPersonalWorkspace),""))}
            if canReviewRestoredJobs {items.append(("復元後の処理を確認…",#selector(showPersonalProviderReview),""))}
            if canManagePersonalRuntimes {items.append(("機能・連携を再開…",#selector(showPersonalRuntimes),""))}
            menu("復元の確認",items)
        }
        menu("編集",[("元に戻す",Selector(("undo:")),"z"),("やり直す",Selector(("redo:")),"Z"),("切り取り",#selector(NSText.cut(_:)),"x"),("コピー",#selector(NSText.copy(_:)),"c"),("貼り付け",#selector(NSText.paste(_:)),"v"),("すべて選択",#selector(NSText.selectAll(_:)),"a"),("検索",#selector(focusSearch),"f")])
        if service.identity.role == "admin" {
            menu("管理",[("利用者の管理…",#selector(showUserAdministration),""),("CRMの選択肢設定…",#selector(showCRMConfiguration),""),("営業フローの実行タイミング…",#selector(showCRMFunnelSettings),""),("営業の自動処理と通知…",#selector(showCRMAutomationJobs),""),("通貨と為替レート…",#selector(showCurrencyAdministration),""),("全体の変更履歴…",#selector(showAdminAudit),""),(personalHostConfigured ? "バックアップと復元…" : "バックアップと復元準備…",#selector(showDataMaintenance),"")])
        }
        menu("連絡先",[("一括で情報補完…",#selector(showBulkEnrichment),""),("情報補完の履歴…",#selector(showEnrichmentHistory),"")])
        menu("営業先",[("一括で情報補完…",#selector(showBulkTargetEnrichment),""),("情報補完の履歴…",#selector(showTargetEnrichmentHistory),"")])
        menu("連携", []); pluginPagesMenu = main.items.last?.submenu; refreshPluginPages()
        menu("表示",[("横断検索…",#selector(showGlobalSearch),"k"),("文書を検索…",#selector(showDocumentSearch),"K"),("レポート…",#selector(showReports),"R"),("再読み込み",#selector(refresh),"r")]); menu("ヘルプ",[("使い方",#selector(openGuide),"")]); NSApp.mainMenu = main
    }
    @MainActor @objc private func showPersonalRuntimes() {
        guard canPresentPersonalRuntimes,!hostDiscarded,manualLocal(),let parent=window,
              parent.attachedSheet==nil,personalRuntimeWindow==nil,let plan=effectPolicy?.plan else{return}
        do {
            try personalAuthorize?()
            let enabled:Set<NativePersonalRuntimeGroup>=plan.runtimeReview == nil ? Set(plan.resumption?.workers ?? []):[]
            let controller=NativePersonalRuntimeWindow(enabled:enabled,settingsAvailable:personalSettingsGroups,
                reviewReason:plan.runtimeReview?.reason.message)
            personalRuntimeWindow=controller
            parent.beginSheet(controller.window){[weak self,weak controller] _ in
                guard let self,self.personalRuntimeWindow === controller else{return}
                let intent=controller?.intent
                self.personalRuntimeWindow=nil
                guard self.canPresentPersonalRuntimes,!self.hostDiscarded,!self.restoreAdmissionClosed,!self.quitPreflight,!self.mcpTerminating,
                      let intent,let action=self.personalRuntimeAction else{return}
                do {try self.personalAuthorize?();try action(intent)}catch{self.showError(error)}
            }
        }catch{showError(error)}
    }
    @MainActor private func closePersonalRuntimeWindow() {
        guard let controller=personalRuntimeWindow else{return}
        controller.closeAfterConfirmation()
        if personalRuntimeWindow === controller {personalRuntimeWindow=nil}
    }
    @MainActor @objc private func showPersonalProviderReview() {
        guard canReviewRestoredJobs,!hostDiscarded,manualLocal(),let parent=window,
              parent.attachedSheet==nil,personalProviderReviewWindow==nil,
              let factory=personalProviderReviewFactory else{return}
        do {
            try personalAuthorize?()
            let controller=NativePersonalProviderReviewWindow(api:try factory(),activities:restoreActivities)
            personalProviderReviewWindow=controller
            parent.beginSheet(controller.window){[weak self,weak controller] _ in
                guard let self,self.personalProviderReviewWindow === controller else{return}
                self.personalProviderReviewWindow=nil
                if !self.hostDiscarded && !self.restoreAdmissionClosed {self.reload()}
            }
            controller.start()
        }catch{showError(error)}
    }
    /// Called only after the normal discard confirmation, or failed-host teardown.
    /// The child index task is joined before the controller/DB alias is released.
    @MainActor private func drainPersonalProviderReview()async {
        closePersonalRuntimeWindow()
        guard let controller=personalProviderReviewWindow else{return}
        await controller.closeAfterConfirmationAndDrain()
        if personalProviderReviewWindow === controller {personalProviderReviewWindow=nil}
    }
    @objc private func showReports() { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard window?.attachedSheet == nil, let service else { return }
        do {
            let controller = try NativeReportsWindow(service:service,activities:restoreActivities,allowsDelivery:effectPolicy?.allowsManual(["mail.reports"])==true); reportsWindow = controller
            controller.onReviewReport = { [weak self] job,parent,completion in
                guard let self else{return};let review=CRMJobReviewWindow(service:service,job:job);self.reportReviewWindow=review
                parent.beginSheet(review.window){[weak self] _ in self?.reportReviewWindow=nil;completion()}
            }
            window.beginSheet(controller.window) { [weak self] _ in self?.reportsWindow = nil; self?.memory.settle() }
            controller.start()
        } catch { showError(error) }
    }
    @objc private func showGlobalSearch() { openSearch(documentCandidates: false) }
    @objc private func showDocumentSearch() { openSearch(documentCandidates: true) }
    private func openSearch(documentCandidates: Bool) { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard window?.attachedSheet == nil,let service else { return }
        do {
            let engine:NativeSearchEngine
            if effectPolicy?.allowsManual(["ai.embedding"])==true,let aiKeys {
                let generate:NativeEmbeddingWorker.Generate=usesQAServices ? NativeAIQAServices.generate : {try await NativeEmbeddingClient(apiKey:$1).generate($0)}
                engine=NativeSearchEngine(keys:aiKeys,generate:generate,documentCandidates:documentCandidates)
            }else{engine=NativeSearchEngine(service:service,documentCandidates:documentCandidates)}
            let controller = try NativeSearchWindow(engine:engine,activities:restoreActivities); globalSearchWindow = controller
            window.beginSheet(controller.window) { [weak self, weak controller] response in
                guard let self else { return }; let result = controller?.selectedResult; self.globalSearchWindow = nil; self.memory.settle()
                if response == .OK, let result { DispatchQueue.main.async { [weak self] in self?.openSearchResult(result) } }
            }; controller.start()
        } catch { showError(error) }
    }
    private func openSearchResult(_ hit: NativeSearchHit) { guard !restoreAdmissionClosed else{return};
        guard window.attachedSheet == nil else { return }
        do {
            let row = try service.searchDestination(hit)
            switch hit.kind {
            case .documents: openDocuments(focusedDocumentID: hit.id)
            case .tasks:
                let access = try service.projectTaskOverview(hit.id)
                let controller = CRMTaskOverviewWindow(service: service, mine: access.board == nil); taskOverviewWindow = controller
                window.beginSheet(controller.window) { [weak self] _ in self?.taskOverviewWindow = nil; self?.reload(); self?.memory.settle() }
                DispatchQueue.main.async { [weak controller] in controller?.openTask(hit.id) }
            case .users:
                let controller = try CRMEditor(module: .searchUser, record: row, linkedTo: nil, service: service, readOnly: true); editor = controller
                window.beginSheet(controller.window) { [weak self] _ in self?.editor = nil; self?.memory.settle() }
            default:
                guard let target = CRMModule.find(hit.kind.model) else { throw NativeDBError.conflict }
                let full = try service.fullRecord(row)
                module = target; linkedParent = nil; search.stringValue = ""; filter.selectItem(at: 0); offset = 0; displayModule()
                openEditor(full, readOnly: (try? service.assertAccess(hit.kind.model, id: hit.id, write: true)) == nil)
            }
        } catch { showError(error) }
    }
    @objc private func showMCPSettings() { guard !restoreAdmissionClosed else{return}; guard settings([.mcp]) else{return};
        guard let window, window.attachedSheet == nil else { return }
        do {
            let settings = try mcpSettings ?? providerStores().mcpSettings()
            let controller = NativeMCPSettingsWindow(settings: settings, runtime: mcpRuntime, allowsWorkerStart: effectPolicy?.allowsManualGroup(.mcp) == true); mcpSettingsWindow = controller
        window.beginSheet(controller.window) { [weak self] _ in self?.mcpSettingsWindow = nil; self?.memory.settle() }
        controller.start()
        } catch { showError(error) }
    }
    @objc private func showUserAdministration() { guard !personalHostConfigured,!restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard let window, window.attachedSheet == nil, let service else { return }
        do {
            let controller = try NativeUserAdministrationWindow(service: service); userAdministrationWindow = controller
            controller.onChanged = { [weak self] in self?.reload() }
            window.beginSheet(controller.window) { [weak self] _ in self?.userAdministrationWindow = nil; self?.reload(); self?.memory.settle() }
            controller.start()
        } catch { showError(error) }
    }
    @objc private func showUserProfile() { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard let window, window.attachedSheet == nil, let service else { return }
        do {
            let controller = try NativeUserAdministrationProfileWindow(service: service); userProfileWindow = controller
            controller.onChanged = { [weak self] in self?.reload() }
            window.beginSheet(controller.window) { [weak self] _ in self?.userProfileWindow = nil; self?.reload(); self?.memory.settle() }
        } catch { showError(error) }
    }
    /// Local currency/CRM data remains available while automation is held.
    /// An active worker must be stopped by the Host before its settings change.
    private func localSettings(_ group:NativePersonalRuntimeGroup)->Bool {
        guard manualLocal() else{return false}
        if effectPolicy?.plan.mode == .personalActiveLocal,
           effectPolicy?.allowsAny(NativePersonalProviderStores.settingsAffectedGroups(for:group).flatMap(\.runtimeIDs)) == true {
            return settings([group])
        }
        return true
    }
    @objc private func showCurrencyAdministration() { guard !restoreAdmissionClosed else{return}; guard localSettings(.currency) else{return};
        guard let window, window.attachedSheet == nil, let service else { return }
        do {
            let controller = try NativeCurrencyAdministrationWindow(service: service, allowsECB:effectPolicy?.allowsManual(["currency.ecb"]) == true, allowsECBSettings:effectPolicy?.allowsSettings(.currency) == true); currencyAdministrationWindow = controller
            controller.onChanged = { [weak self] in self?.reload() }
            window.beginSheet(controller.window) { [weak self] _ in self?.currencyAdministrationWindow = nil; self?.reload(); self?.memory.settle() }
            controller.start()
        } catch { showError(error) }
    }
    @objc private func showAdminAudit() { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard let window, window.attachedSheet == nil, let service else { return }
        do {
            let controller = try NativeAdminAuditWindow(service: service); adminAuditWindow = controller
            controller.onChanged = { [weak self] in self?.reload() }
            window.beginSheet(controller.window) { [weak self] _ in self?.adminAuditWindow = nil; self?.reload(); self?.memory.settle() }
            controller.start()
        } catch { showError(error) }
    }
    @MainActor @objc private func showDataMaintenance() { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard !mcpTerminating, let window, window.attachedSheet == nil,
              dataMaintenanceWindow == nil, let service, let resources = Bundle.main.resourceURL else { return }
        let operation = NativeDataMaintenanceController(service:service,resources:resources)
        do { try operation.authorize() } catch { showError(error); return }
        let controller = NativeDataMaintenanceWindow(controller:operation)
        if let review=personalRestoreReview {
            controller.onReviewActivation = {[weak self,weak controller] artifact in
                guard let self,let controller else {throw CancellationError()}
                try self.authorizePersonalRestore()
                try self.checkRestoreParentAdmission(ownedWindows:[controller.window])
                try review(artifact,controller.window)
            }
        }
        let closeWaiters = NativeSheetCloseWaiters(); dataMaintenanceClose = closeWaiters
        dataMaintenanceWindow = controller
        controller.onClosed = { [weak self] in
            guard let self else { return }
            self.dataMaintenanceWindow = nil
            closeWaiters.didClose(); self.memory.settle()
        }
        window.beginSheet(controller.window)
        controller.start()
    }
    @objc private func showCRMConfiguration() { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard let window, window.attachedSheet == nil, let service else { return }
        do {
            let controller = try NativeCRMConfigurationWindow(service: service); crmConfigurationWindow = controller
            controller.onChanged = { [weak self] in self?.reload() }
            window.beginSheet(controller.window) { [weak self] _ in self?.crmConfigurationWindow = nil; self?.reload(); self?.memory.settle() }
            controller.start()
        } catch { showError(error) }
    }
    @objc private func showCRMAutomationJobs() { guard !restoreAdmissionClosed else{return}; guard manual(["crm.automation"]) else{return};
        guard let window, window.attachedSheet == nil, let service else { return }
        do {
            let controller = try NativeCRMAutomationJobsWindow(service: service, allowsMailRetry:effectPolicy?.allowsManual(["mail.crm-automation"]) == true); crmAutomationJobsWindow = controller
            window.beginSheet(controller.window) { [weak self] _ in self?.crmAutomationJobsWindow = nil; self?.reload(); self?.memory.settle() }
        } catch { showError(error) }
    }
    @objc private func showCRMFunnelSettings() { guard !restoreAdmissionClosed else{return}; guard localSettings(.crmAutomation) else{return};
        guard let window, window.attachedSheet == nil, let service else { return }
        do {
            let controller = try NativeCRMFunnelSettingsWindow(service: service); crmFunnelSettingsWindow = controller
            controller.onChanged = { [weak self] in self?.reload() }
            window.beginSheet(controller.window) { [weak self] _ in self?.crmFunnelSettingsWindow = nil; self?.reload(); self?.memory.settle() }
            controller.start()
        } catch { showError(error) }
    }
    @objc private func showPluginsSettings() { guard !restoreAdmissionClosed else{return}; guard settings([.plugins]) else{return};
        guard let window, window.attachedSheet == nil else { return }
        do {
            let admin = try plugins?.admin ?? providerStores().settingsOnlyPluginAdmin()
            try admin.requireAdmin()
            let controller = NativePluginsSettingsWindow(admin: admin); pluginsSettingsWindow = controller
            if effectPolicy?.allowsManualGroup(.plugins) == true { controller.onOpenDetails = { [weak self] detail, parent in
                let choice = NativePluginPresentationService.Choice(pluginID: detail.item.id, title: detail.item.name, location: .admin)
                self?.showPluginInformation(choice, on: parent)
            } }
            window.beginSheet(controller.window) { [weak self] _ in self?.pluginsSettingsWindow = nil; self?.refreshPluginPages(); self?.reload(); self?.memory.settle() }
            controller.start()
        } catch { showError(error) }
    }
    private func pluginItem(_ choice: NativePluginPresentationService.Choice, on parent: NSWindow?) -> NSMenuItem {
        let item = NSMenuItem(title: choice.title, action: #selector(openPluginRoute(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = PluginMenuRoute(choice, parent: parent); return item
    }
    private func refreshPluginPages() {
        guard let menu = pluginPagesMenu else { return }; menu.removeAllItems(); menu.autoenablesItems = false
        if service.identity.role == "admin" {
            let settings = NSMenuItem(title: "連携・プラグインの設定…", action: #selector(showPluginsSettings), keyEquivalent: ""); settings.target = self; settings.isEnabled = canOpenSettings([.plugins]); menu.addItem(settings)
        }
        let pages = (try? pluginPresentationService?.pages()) ?? []
        if !pages.isEmpty && menu.numberOfItems > 0 { menu.addItem(.separator()) }
        for choice in pages { menu.addItem(pluginItem(choice, on: window)) }
        if pages.isEmpty { let empty = NSMenuItem(title: "利用できる連携一覧はありません", action: nil, keyEquivalent: ""); empty.isEnabled = false; menu.addItem(empty) }
    }
    private func pluginMenu(for record: NativeRecord, on parent: NSWindow) -> NSMenu? {
        guard !readOnlyWorkspace,permits("plugins.host") else{return nil}
        guard let api = pluginPresentationService, let location = NativePluginPresentationService.location(model: record.model, id: record["id"].string),
              let choices = try? api.choices(location), !choices.isEmpty else { return nil }
        let menu = NSMenu(); menu.autoenablesItems = false; menu.addItem(NSMenuItem(title: "連携情報", action: nil, keyEquivalent: ""))
        for choice in choices { menu.addItem(pluginItem(choice, on: parent)) }; return menu
    }
    private func updatePluginRecordMenu() {
        let menu: NSMenu?
        if rows.indices.contains(table.selectedRow), filter.indexOfSelectedItem == 0, rows[table.selectedRow].record.model == module.model {
            menu = pluginMenu(for: rows[table.selectedRow].record, on: window)
        } else { menu = nil }
        pluginInfo.menu = menu; pluginInfo.isHidden = menu == nil; pluginInfo.isEnabled = menu != nil
    }
    @objc private func openPluginRoute(_ sender: NSMenuItem) { guard !restoreAdmissionClosed else{return}; guard manual(["plugins.host"]) else{return};
        guard let route = sender.representedObject as? PluginMenuRoute, let parent = route.parent ?? window else { return }
        showPluginInformation(route.choice, on: parent)
    }
    private func showPluginInformation(_ choice: NativePluginPresentationService.Choice, on parent: NSWindow) { guard !restoreAdmissionClosed else{return}; guard manual(["plugins.host"]) else{return};
        guard parent.attachedSheet == nil, pluginStatusWindow == nil, let api = pluginPresentationService else { return }
        do {
            try api.authorize(choice)
            let controller = NativePluginPresentationWindow(title: choice.title, authorize: { try api.authorize(choice) }, load: { try api.build(choice) })
            pluginStatusWindow = controller
            controller.onOpenRecord = { [weak self, weak controller] target in
                guard let self else { return }
                _ = try api.record(target); self.pendingPluginTarget = target; controller?.dismissForNavigation()
            }
            parent.beginSheet(controller.window) { [weak self] _ in
                guard let self else { return }; self.pluginStatusWindow = nil; self.memory.settle()
                if let target = self.pendingPluginTarget {
                    self.pendingPluginTarget = nil
                    DispatchQueue.main.async { [weak self] in self?.navigateFromPlugin(target) }
                }
            }
            controller.start()
        } catch {
            let alert = NSAlert(); alert.messageText = "連携情報を開けませんでした"; alert.informativeText = NativePluginsAdmin.errorMessage(error)
            alert.beginSheetModal(for: parent)
        }
    }
    @MainActor private func navigateFromPlugin(_ target: NativePluginPresentation.RecordTarget) { guard !restoreAdmissionClosed else{return}; guard manual(["plugins.host"]) else{return};
        guard !quitPreflight, !mcpTerminating else { return }
        guard confirmClose() else { return }
        let show = { [weak self] in
            guard let self, !self.quitPreflight, !self.mcpTerminating, let api = self.pluginPresentationService else { return }
            do {
                let record = try api.record(target)
                guard let module = CRMModule.find(record.model) else { throw NativeDBError.message("この情報は開けません。") }
                self.module = module; self.linkedParent = nil; self.search.stringValue = ""; self.filter.selectItem(at: 0); self.offset = 0; self.displayModule()
                self.openEditor(record, readOnly: (try? self.service.assertAccess(target.model, id: target.id, write: true)) == nil)
            } catch { self.showError(error) }
        }
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel); DispatchQueue.main.async(execute: show) }
        else { show() }
    }
    @objc private func showAPITokens() { guard !restoreAdmissionClosed else{return}; guard settings([.mcp]) else{return};
        guard let window, window.attachedSheet == nil else { return }
        do {
            let controller = try NativeAPITokensWindow(store: NativeAPITokens(service: service)); apiTokensWindow = controller
            window.beginSheet(controller.window) { [weak self] _ in self?.apiTokensWindow = nil; self?.memory.settle() }
            controller.start()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func showAISettings() {
        guard let window else { return }; presentAISettings(on: window)
    }
    private func presentAISettings(on parent: NSWindow) { guard !restoreAdmissionClosed else{return}; guard settings(Self.aiSettingsGroups) else{return};
        guard parent.attachedSheet == nil else { return }
        do {
            let aiKeys = try self.aiKeys ?? providerStores().aiKeys()
            let controller = try NativeAISettingsWindow(keys: aiKeys); aiSettingsWindow = controller
            controller.onE2BSettings = { [weak self] parent in self?.presentE2BSettings(on: parent) }
            parent.beginSheet(controller.window) { [weak self] _ in self?.aiSettingsWindow = nil; self?.memory.settle() }
        } catch { status.stringValue = error.localizedDescription }
    }
    private var enrichmentAPI: NativeContactEnrichmentService {
        .init(service: service, store: aiKeys.store, environment: aiKeys.environment, clock: aiKeys.clock)
    }
    private func presentE2BSettings(on parent: NSWindow) { guard !restoreAdmissionClosed else{return}; guard settings(Self.aiSettingsGroups) else{return};
        guard parent.attachedSheet == nil else { return }
        do {
            let aiKeys = try self.aiKeys ?? providerStores().aiKeys()
            let api = NativeE2BSettings(service: service, store: aiKeys.store, environment: aiKeys.environment, clock: aiKeys.clock)
            let controller = try NativeE2BSettingsWindow(api: api); e2bSettingsWindow = controller
            parent.beginSheet(controller.window) { [weak self] _ in self?.e2bSettingsWindow = nil; self?.memory.settle() }
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func showBulkEnrichment() { openEnrichment(contactID: nil) }
    private func openEnrichment(contactID: String?) { guard !restoreAdmissionClosed else{return}; guard manual(["ai.contacts"]) else{return};
        guard window?.attachedSheet == nil, aiKeys != nil else { return }
        do {
            let controller = try NativeContactEnrichmentRequestWindow(api: enrichmentAPI, contactID: contactID); enrichmentRequestWindow = controller
            controller.onSettings = { [weak self] parent in self?.presentAISettings(on: parent) }
            window.beginSheet(controller.window) { [weak self] _ in
                guard let self else { return }; let id = self.enrichmentRequestWindow?.requestedIDs.first
                self.enrichmentRequestWindow = nil; self.memory.settle()
                // AppKit can still report the closing sheet inside its completion.
                // Present the history after that completion has unwound.
                if let id { DispatchQueue.main.async { [weak self] in self?.openEnrichmentHistory(contactID: contactID, focusedID: id) } }
            }
        } catch { showError(error) }
    }
    @objc private func showEnrichmentHistory() { openEnrichmentHistory(contactID: nil) }
    private func openEnrichmentHistory(contactID: String?, focusedID: String? = nil) { guard !restoreAdmissionClosed else{return}; guard manual(["ai.contacts"]) else{return};
        guard !quitPreflight, !mcpTerminating, window?.attachedSheet == nil, aiKeys != nil else { return }
        do {
            let controller = try NativeContactEnrichmentHistoryWindow(api: enrichmentAPI, contactID: contactID, focusedID: focusedID); enrichmentHistoryWindow = controller
            controller.onChanged = { [weak self] in self?.reload() }
            window.beginSheet(controller.window) { [weak self] _ in self?.enrichmentHistoryWindow = nil; self?.reload(); self?.memory.settle() }
        } catch { showError(error) }
    }
    private var targetEnrichmentAPI: NativeTargetEnrichmentService {
        .init(service: service, store: aiKeys.store, environment: targetEnrichmentEnvironment, clock: aiKeys.clock)
    }
    @objc private func showBulkTargetEnrichment() { openTargetEnrichment(targetID: nil) }
    private func openTargetEnrichment(targetID: String?) { guard !restoreAdmissionClosed else{return}; guard manual(["ai.targets"]) else{return};
        guard window?.attachedSheet == nil, aiKeys != nil else { return }
        do {
            let controller = try NativeTargetEnrichmentRequestWindow(api: targetEnrichmentAPI, targetID: targetID); targetEnrichmentRequestWindow = controller
            controller.onSettings = { [weak self] parent in self?.presentAISettings(on: parent) }
            window.beginSheet(controller.window) { [weak self] _ in
                guard let self else { return }; let id = self.targetEnrichmentRequestWindow?.requestedIDs.first
                self.targetEnrichmentRequestWindow = nil; self.memory.settle()
                if let id { DispatchQueue.main.async { [weak self] in self?.openTargetEnrichmentHistory(targetID: targetID, focusedID: id) } }
            }
        } catch { showError(error) }
    }
    @objc private func showTargetEnrichmentHistory() { openTargetEnrichmentHistory(targetID: nil) }
    private func openTargetEnrichmentHistory(targetID: String?, focusedID: String? = nil) { guard !restoreAdmissionClosed else{return}; guard manual(["ai.targets"]) else{return};
        guard !quitPreflight, !mcpTerminating, window?.attachedSheet == nil, aiKeys != nil else { return }
        do {
            let controller = try NativeTargetEnrichmentHistoryWindow(api: targetEnrichmentAPI, targetID: targetID, focusedID: focusedID); targetEnrichmentHistoryWindow = controller
            controller.onChanged = { [weak self] in self?.reload() }
            window.beginSheet(controller.window) { [weak self] _ in self?.targetEnrichmentHistoryWindow = nil; self?.reload(); self?.memory.settle() }
        } catch { showError(error) }
    }
    private func openTargetContacts(targetID: String) { guard !restoreAdmissionClosed else{return}; guard manual(["ai.targets"]) else{return};
        guard window?.attachedSheet == nil, aiKeys != nil else { return }
        do {
            let controller = try NativeTargetContactsWindow(api: targetEnrichmentAPI, targetID: targetID); targetContactsWindow = controller
            controller.onChanged = { [weak self] in self?.reload() }
            window.beginSheet(controller.window) { [weak self] _ in self?.targetContactsWindow = nil; self?.reload(); self?.memory.settle() }
        } catch { showError(error) }
    }
    @objc private func showAIJobs() { guard !restoreAdmissionClosed else{return}; guard manual(["ai.embedding"]) else{return};
        guard window?.attachedSheet == nil, let aiKeys else { return }
        do {
            let controller = try NativeAIJobsWindow(keys: aiKeys); aiJobsWindow = controller
            window.beginSheet(controller.window) { [weak self] _ in self?.aiJobsWindow = nil; self?.memory.settle() }
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func showGeneralMailAccounts() { guard !restoreAdmissionClosed else{return}; guard settings([.mailAccounts]) else{return};
        guard window?.attachedSheet == nil else { return }
        do {
            let probe:NativeMailConnectionCheck.Probe = (usesQAServices) ? NativeMailQAServices.probe : NativeMailConnectionCheck.run
            let controller = try NativeMailAccountsWindow(service:service,store:try generalMailRuntime?.store ?? providerStores().mailAccounts(),probe:probe,allowsProcessing:effectPolicy?.allowsManualGroup(.mailAccounts) == true)
            generalMailAccountsWindow = controller; controller.onChanged = { [weak self] in
                self?.wakeSettingsWorker("mail.general") { self?.generalMailRuntime?.resume() }; self?.wakeSettingsWorker("ai.embedding") { self?.aiRuntime?.resume() }
            }
            window.beginSheet(controller.window) { [weak self] _ in self?.generalMailAccountsWindow = nil; self?.memory.settle() }
        } catch { status.stringValue = error.localizedDescription }
    }
    private func showRelatedMail(_ record:NativeRecord) { guard !restoreAdmissionClosed else{return}; guard manual(["mail.general"]) else{return};
        guard window?.attachedSheet == nil else { return }
        do {
            let controller = try NativeMailMailboxWindow(service:service,context:.crm(model:record.model,id:record["id"].string)); relatedMailWindow = controller
            controller.onChanged = { [weak self] in self?.generalMailRuntime?.resume(); self?.aiRuntime?.resume() }
            window.beginSheet(controller.window) { [weak self] _ in self?.relatedMailWindow = nil; self?.memory.settle() }
        } catch { showError(error) }
    }
    @objc private func showMailSettings() { guard !restoreAdmissionClosed else{return}; guard settings(Self.resendSettingsGroups) else{return};
        guard window?.attachedSheet == nil else { return }
        do {
            let controller = try CRMInvoiceMailSettingsWindow(service:service,store:try mailRuntime?.store ?? providerStores().invoiceMail())
            mailSettingsWindow = controller
            controller.onSaved = { [weak self] in
                guard let self else { return }
                for (id,runner) in [("mail.invoice",self.invoiceRunner),("mail.orders",self.orderRunner),("mail.projects",self.projectRunner),("mail.crm-tasks",self.crmTaskRunner),("mail.crm-automation",self.crmAutomationMailRunner),("mail.leads",self.leadRunner),("mail.reports",self.reportRunner)] {
                    self.wakeSettingsWorker(id) { runner?.kick() }
                }; self.resumeCampaignJobs()
            }
            window.beginSheet(controller.window) { [weak self] _ in self?.mailSettingsWindow = nil; self?.memory.settle() }
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func showCalendarSettings() { guard !restoreAdmissionClosed else{return}; guard settings([.googleCalendar]) else{return};
        guard window?.attachedSheet == nil else { return }
        do {
            let authorize: GoogleCalendarSettingsWindow.Authorize = (usesQAServices) ? { _,_,_ in throw NativeDBError.message("検証モードでは実際のGoogleアカウントに接続しません。") } : GoogleCalendarSettingsWindow.browser
            let controller = try GoogleCalendarSettingsWindow(service:service,store:try calendarRuntime?.store ?? providerStores().googleCalendar(),authorize:authorize,allowsProcessing:effectPolicy?.allowsManualGroup(.googleCalendar) == true)
            calendarSettingsWindow = controller
            controller.onConnected = { [weak self] in self?.wakeSettingsWorker("calendar.google") { self?.calendarRuntime?.resume() } }
            window.beginSheet(controller.window) { [weak self] _ in self?.calendarSettingsWindow = nil; self?.memory.settle() }
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func showCalendlySettings() { guard !restoreAdmissionClosed else{return}; guard settings([.calendly]) else{return};
        guard window?.attachedSheet == nil else { return }
        do {
            let store = try calendlyRuntime?.store ?? providerStores().calendly()
            let qa = store as? CalendlyQAServices
            let controller = try CalendlySettingsWindow(service:service,store:store,allowLoopbackHTTP:usesQAServices,apiRequest:qa?.provider ?? calendlyAPIRequest,relayRequest:usesQAServices ? CalendlyQAServices.relay : calendlyRelayRequest,allowsProcessing:effectPolicy?.allowsManualGroup(.calendly) == true)
            calendlySettingsWindow = controller; controller.onChanged = { [weak self] in self?.wakeSettingsWorker("calendar.calendly") { self?.calendlyRuntime?.resume() } }
            window.beginSheet(controller.window) { [weak self] _ in self?.calendlySettingsWindow = nil; self?.memory.settle() }
        } catch { status.stringValue = error.localizedDescription }
    }
    private func resumeCampaignJobs() {
        guard !quitPreflight,!mcpTerminating,let policy=effectPolicy,let campaignRuntime else{return}
        policy.wake("campaign.relay"){do{_ = try campaignRuntime.requestSync()}catch{status.stringValue=error.localizedDescription};campaignSyncRunner?.kick()}
        policy.wake("campaign.dispatch"){campaignDispatchRunner?.kick()};policy.wake("campaign.delivery"){campaignMailRunner?.kick()}
    }
    @objc private func showCampaignSettings() { guard !restoreAdmissionClosed else{return}; guard settings([.campaigns]) else{return};
        guard window?.attachedSheet == nil else { return }
        do {
            let controller = try CRMCampaignRelaySettingsWindow(service:service,store:try campaignRuntime?.store ?? providerStores().campaignRelay(),allowLoopbackHTTP:usesQAServices,request:usesQAServices ? CampaignRelayQACredentials.request : campaignRelayRequest)
            campaignSettingsWindow = controller; controller.onSaved = { [weak self] in self?.resumeCampaignJobs() }
            window.beginSheet(controller.window) { [weak self] _ in self?.campaignSettingsWindow = nil; self?.memory.settle() }
        } catch { status.stringValue = error.localizedDescription }
    }
    private func makeWindow() {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1260,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.minSize = NSSize(width:1040,height:620); window.title = "NextCRM Native"
        #if !HELD_HOST_TESTING
        window.setFrameAutosaveName("NextCRMNativeWorkspace")
        #endif
        window.center(); window.delegate = self
        let brand = NSTextField(labelWithString:"NextCRM"); brand.font = .systemFont(ofSize:22,weight:.bold)
        let local = NSTextField(labelWithString:readOnlyWorkspace ? "復元後の確認待ち · 閲覧専用" : (usesQAServices) ? "検証用 · 外部メール送信なし" : "日本語版 · このMacに保存"); local.font = .systemFont(ofSize:11); local.textColor = .secondaryLabelColor
        let globalSearch = NSButton(title: "横断検索…", target: self, action: #selector(showGlobalSearch)); globalSearch.bezelStyle = .rounded; globalSearch.alignment = .left; globalSearch.widthAnchor.constraint(equalToConstant: 156).isActive = true
        let documentSearch = NSButton(title: "文書を検索…", target: self, action: #selector(showDocumentSearch)); documentSearch.bezelStyle = .rounded; documentSearch.alignment = .left; documentSearch.widthAnchor.constraint(equalToConstant: 156).isActive = true
        let reports = NSButton(title:"レポート…",target:self,action:#selector(showReports)); reports.bezelStyle = .rounded; reports.alignment = .left; reports.widthAnchor.constraint(equalToConstant:156).isActive = true
        var items: [NSView] = [brand,local,globalSearch,documentSearch,reports]
        for (index, section) in CRMModule.all.enumerated() {
            let button = NSButton(title:section.title,target:self,action:#selector(navigate(_:))); button.tag = index; button.bezelStyle = .rounded; button.setButtonType(.pushOnPushOff); button.alignment = .left; button.identifier = NSUserInterfaceItemIdentifier("module-\(section.model)")
            button.widthAnchor.constraint(equalToConstant:156).isActive = true; navigation.append(button); items.append(button)
        }
        
        let crmTasks = NSButton(title:"CRMタスク…",target:self,action:#selector(showCRMTasks)); crmTasks.bezelStyle = .rounded; crmTasks.alignment = .left; crmTasks.widthAnchor.constraint(equalToConstant:156).isActive = true; items.append(crmTasks)
        let campaigns = NSButton(title:"キャンペーン…",target:self,action:#selector(showCampaigns)); campaigns.bezelStyle = .rounded; campaigns.alignment = .left; campaigns.widthAnchor.constraint(equalToConstant:156).isActive = true; items.append(campaigns)
        let templates = NSButton(title:"メールテンプレート…",target:self,action:#selector(showTemplates)); templates.bezelStyle = .rounded; templates.alignment = .left; templates.widthAnchor.constraint(equalToConstant:156).isActive = true; items.append(templates)
        let mail = NSButton(title:"メール…",target:self,action:#selector(showGeneralMailAccounts)); mail.bezelStyle = .rounded; mail.alignment = .left; mail.widthAnchor.constraint(equalToConstant:156).isActive = true; items.append(mail)
        let sidebarContent = NSStackView(views:items); sidebarContent.orientation = .vertical; sidebarContent.alignment = .leading; sidebarContent.spacing = 13; sidebarContent.translatesAutoresizingMaskIntoConstraints = false
        let sidebar = NSScrollView(); sidebar.drawsBackground = false; sidebar.hasVerticalScroller = true; sidebar.autohidesScrollers = true; sidebar.widthAnchor.constraint(equalToConstant:170).isActive = true
        let navigationDocument = FlippedContentView(); navigationDocument.translatesAutoresizingMaskIntoConstraints = false; sidebar.documentView = navigationDocument; navigationDocument.addSubview(sidebarContent)
        NSLayoutConstraint.activate([navigationDocument.widthAnchor.constraint(equalTo:sidebar.contentView.widthAnchor),sidebarContent.leadingAnchor.constraint(equalTo:navigationDocument.leadingAnchor),sidebarContent.topAnchor.constraint(equalTo:navigationDocument.topAnchor),sidebarContent.trailingAnchor.constraint(equalTo:navigationDocument.trailingAnchor),sidebarContent.bottomAnchor.constraint(equalTo:navigationDocument.bottomAnchor)])
        title.font = .systemFont(ofSize:27,weight:.bold); subtitle.textColor = .secondaryLabelColor; subtitle.font = .systemFont(ofSize:12)
        search.placeholderString = "名称・メールなどで検索"; search.setAccessibilityLabel("一覧を検索"); search.delegate = self; search.sendsSearchStringImmediately = true
        filter.addItems(withTitles:["通常の一覧","削除済み"]); filter.target = self; filter.action = #selector(filterChanged); filter.setAccessibilityLabel("一覧の種類")
        filter.isEnabled = service.identity.role == "admin"
        create.target = self; create.action = #selector(newRecord); create.bezelStyle = .rounded
        targetSpreadsheet.target = self; targetSpreadsheet.action = #selector(openTargetSpreadsheet); targetSpreadsheet.bezelStyle = .rounded
        targetSelectPage.target = self; targetSelectPage.action = #selector(toggleTargetPageSelection); targetSelectPage.bezelStyle = .rounded
        targetClearSelection.target = self; targetClearSelection.action = #selector(clearTargetSelection); targetClearSelection.bezelStyle = .rounded
        targetSelectedCount.font = .systemFont(ofSize:12)
        targetSelectionControls = NSStackView(views:[targetSelectedCount,NSView(),targetSelectPage,targetClearSelection]); targetSelectionControls.spacing = 10
        importProducts.target = self; importProducts.action = #selector(openProductImport); importProducts.bezelStyle = .rounded
        search.setContentHuggingPriority(.defaultLow,for:.horizontal); filter.setContentHuggingPriority(.required,for:.horizontal); create.setContentHuggingPriority(.required,for:.horizontal)
        let toolbar = NSStackView(views:[search,filter,importProducts,targetSpreadsheet,create]); toolbar.spacing = 12
        let allTasks = NSButton(title:"すべてのタスク…",target:self,action:#selector(openAllProjectTasks))
        let myTasks = NSButton(title:"自分の担当タスク…",target:self,action:#selector(openMyProjectTasks))
        let dashboard = NSButton(title:"ダッシュボード…",target:self,action:#selector(openProjectDashboard))
        for button in [allTasks,myTasks,dashboard] { button.bezelStyle = .rounded; button.isEnabled = service.identity.role != "partner" }
        projectControls = NSStackView(views:[allTasks,myTasks,dashboard,NSView()]); projectControls.spacing = 12
        orderStatus.addItems(withTitles:["すべての受注状態"]+OrderWorkflow.statuses.map { OrderWorkflow.labels[$0]! }); orderStatus.setAccessibilityLabel("受注の状態で絞り込み")
        orderStatus.target = self; orderStatus.action = #selector(orderFilterChanged)
        for (button,selector) in [(orderOwner,#selector(chooseOrderOwner)),(clearOrderOwner,#selector(resetOrderFilters)),(orderSettings,#selector(openOrderSettings))] { button.target = self; button.action = selector; button.bezelStyle = .rounded }
        orderOwner.isHidden = !service.identity.elevated; orderSettings.isHidden = service.identity.role != "admin"
        orderFilters = NSStackView(views:[orderStatus,orderOwner,clearOrderOwner,NSView(),orderSettings]); orderFilters.spacing = 12
        invoiceStatus.addItems(withTitles:["すべての請求状態"]+CRMModule.invoiceStatuses.map(\.1)); invoiceStatus.setAccessibilityLabel("請求書の状態で絞り込み")
        invoiceType.addItems(withTitles:["すべての請求種類"]+CRMModule.invoiceTypes.map(\.1)); invoiceType.setAccessibilityLabel("請求書の種類で絞り込み")
        for control in [invoiceStatus,invoiceType] { control.target = self; control.action = #selector(orderFilterChanged) }
        invoiceSortControl.addItems(withTitles:InvoiceListSort.Field.allCases.flatMap { ["\($0.label)・昇順","\($0.label)・降順"] }); invoiceSortControl.setAccessibilityLabel("請求書の並べ替え")
        invoiceSortControl.target = self; invoiceSortControl.action = #selector(invoiceSortChanged)
        invoiceSettings.addItems(withTitles:["請求書の設定","会社・標準設定…","採番系列…","税率…","メール送信…"]); invoiceSettings.target = self; invoiceSettings.action = #selector(openInvoiceSettings(_:)); invoiceSettings.isHidden = service.identity.role != "admin"
        invoiceFilters = NSStackView(views:[invoiceStatus,invoiceType,invoiceSortControl,NSView(),invoiceSettings]); invoiceFilters.spacing = 12
        table.dataSource = self; table.delegate = self; table.style = .inset; table.rowHeight = 40; table.headerView = nil; table.allowsMultipleSelection = false; table.target = self; table.doubleAction = #selector(editRecord); table.setAccessibilityLabel("CRMの一覧")
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("summary")); column.width = 1000; table.addTableColumn(column)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        header.horizontalInset = 16; header.heightAnchor.constraint(equalToConstant:24).isActive = true
        let listing = NSStackView(views:[header,scroll]); listing.orientation = .vertical; listing.alignment = .leading; listing.spacing = 4
        header.widthAnchor.constraint(equalTo:listing.widthAnchor).isActive = true; scroll.widthAnchor.constraint(equalTo:listing.widthAnchor).isActive = true
        edit.target = self; edit.action = #selector(editRecord); historyButton.target = self; historyButton.action = #selector(showHistory); deleteButton.target = self; deleteButton.action = #selector(deleteRecord); activities.target = self; activities.action = #selector(showActivities)
        previous.target = self; previous.action = #selector(back); next.target = self; next.action = #selector(forward)
        for button in [edit,historyButton,deleteButton,activities,previous,next] { button.bezelStyle = .rounded }
        actions.addItems(withTitles:["承認操作","承認を申請","承認する","却下する"]); actions.target = self; actions.action = #selector(approvalAction(_:))
        relations.target = self; relations.action = #selector(relationAction(_:)); relations.menu?.autoenablesItems = false
        moveUp.target = self; moveUp.action = #selector(moveSelected(_:)); moveUp.tag = -1; moveUp.bezelStyle = .rounded
        moveDown.target = self; moveDown.action = #selector(moveSelected(_:)); moveDown.tag = 1; moveDown.bezelStyle = .rounded
        pluginInfo.isHidden = true; pluginInfo.setAccessibilityLabel("選択した情報の連携情報")
        let operations = NSStackView(views:[edit,activities,historyButton,deleteButton,actions,relations,pluginInfo,moveUp,moveDown,NSView()]); operations.spacing = 10
        count.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular); status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor
        let footer = NSStackView(views:[count,NSView(),previous,next]); footer.spacing = 10
        let content = NSStackView(views:[title,subtitle,toolbar,targetSelectionControls,projectControls,orderFilters,invoiceFilters,listing,operations,footer,status]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 15
        targetSelectionControls.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true
        projectControls.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true
        orderFilters.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true; invoiceFilters.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true
        let root = NSStackView(views:[sidebar,content]); root.alignment = .top; root.spacing = 26; root.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-196).isActive = true
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:24),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-24),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:24),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-22),content.heightAnchor.constraint(equalTo:root.heightAnchor),sidebar.heightAnchor.constraint(equalTo:root.heightAnchor),toolbar.widthAnchor.constraint(equalTo:content.widthAnchor),listing.widthAnchor.constraint(equalTo:content.widthAnchor),operations.widthAnchor.constraint(equalTo:content.widthAnchor),footer.widthAnchor.constraint(equalTo:content.widthAnchor),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:260)])
    }
    private func columns() -> [NativeColumn] { module.columns.map { NativeColumn(title:$0.label,fraction:$0.fraction) } }
    private func updateHeader() {
        let invoice = module.model == "Invoices"
        header.actionableColumns = invoice ? Set(module.columns.indices.filter { index in InvoiceListSort.Field.allCases.contains { $0.column == module.columns[index].fields.first } }) : []
        header.onColumnPress = invoice ? { [weak self] index in
            guard let self, let field = InvoiceListSort.Field.allCases.first(where: { $0.column == self.module.columns[index].fields.first }) else { return }
            self.invoiceSort.toggle(field); self.offset = 0; self.updateHeader(); self.reload()
        } : nil
        let labels = module.columns.map { column in column.label + (invoice && column.fields.first == invoiceSort.field.column ? (invoiceSort.descending ? " ↓" : " ↑") : "") }
        header.configure(columns:columns(),values:labels,heading:true)
        if invoice, let index = InvoiceListSort.Field.allCases.firstIndex(of:invoiceSort.field) { invoiceSortControl.selectItem(at:index*2+(invoiceSort.descending ? 1 : 0)) }
    }
    @objc private func invoiceSortChanged() {
        let index = invoiceSortControl.indexOfSelectedItem
        guard index >= 0 else { return }
        invoiceSort = InvoiceListSort(field:InvoiceListSort.Field.allCases[index/2],descending:index%2 == 1)
        offset = 0; updateHeader(); reload()
    }
    private func displayModule() {
        if module.model != "crm_Targets" { targetSelection.clear() }
        targetSelectionControls.isHidden = module.model != "crm_Targets"
        targetSpreadsheet.isHidden = module.model != "crm_Targets"
        targetSpreadsheet.isEnabled = filter.indexOfSelectedItem == 0 && !service.db.isReadOnly
        table.allowsMultipleSelection = module.model == "crm_Targets"
        projectControls.isHidden = module.model != "Boards"
        orderFilters.isHidden = module.model != "crm_Orders"; invoiceFilters.isHidden = module.model != "Invoices"; edit.title = ["crm_Orders","Invoices","Boards"].contains(module.model) ? "開く" : "編集"
        importProducts.isHidden = module.model != "crm_Products"; importProducts.isEnabled = service.identity.elevated && filter.indexOfSelectedItem == 0
        deleteButton.title = filter.indexOfSelectedItem == 1 ? "復元" : "削除"
        let supportsTrash = (try? service.db.schema.model(module.model).field("deletedAt")) != nil
        filter.isHidden = !supportsTrash; deleteButton.isHidden = ["crm_ProductCategories","Invoices"].contains(module.model)
        let isLine = LineContext.forModel(module.model)?.totalField != nil
        moveUp.isHidden = !isLine; moveDown.isHidden = !isLine
        if module.model == "crm_AccountProducts" { deleteButton.title = "割当を取消" }
        title.stringValue = module.title
        subtitle.stringValue = linkedParent.map { CRMModule.displayName($0) + (module.model == "crm_Activities" ? "に関連する活動" : "の" + module.title) } ?? "\(module.title)の情報を管理します。"
        window.title = "NextCRM Native — \(module.title)"; create.title = module.model == "crm_Activities" ? "活動を記録" : "新規\(module.singular)"
        navigation.forEach { $0.state = CRMModule.all[$0.tag].model == module.model ? .on : .off }
        updateHeader()
        actions.isHidden = module.model != "crm_Opportunities"; activities.isHidden = !["account","contact","lead","opportunity","contract"].contains(module.entity)
        relations.removeAllItems(); relations.addItem(withTitle:"関連操作")
        switch module.model {
        case "crm_Contacts":
            relations.addItem(withTitle: "情報補完…"); relations.lastItem?.representedObject = "enrichContact"
            relations.addItem(withTitle: "情報補完の履歴…"); relations.lastItem?.representedObject = "enrichmentHistory"
        case "crm_Accounts": relations.addItems(withTitles:["ウォッチを開始","外部パートナーを設定…","外部パートナーを解除","商品割当を管理…","受注を表示…","受注を作成…","請求書を表示…","請求書を作成…"])
        case "crm_Targets": relations.addItems(withTitles:["取引先・連絡先に変換…","商談まで作成…","情報補完…","情報補完の履歴…","担当者を管理…"])
        case "crm_TargetLists": relations.addItem(withTitle:"メンバーを管理…")
        case "crm_Products": relations.addItems(withTitles:["価格を確認…","導入先を表示…"])
        case "crm_Opportunities": relations.addItem(withTitle:"明細を管理…")
        case "crm_Contracts": relations.addItems(withTitles:["明細を管理…","商談から明細をコピー…"])
        case "crm_PriceLists": relations.addItems(withTitles:["価格ルールを管理…","価格を確認…","標準価格表に設定","標準価格表を解除"])
        default: break
        }
        if module.model == "crm_Accounts" { relations.addItem(withTitle:"導入事例…"); relations.lastItem?.representedObject = "caseStudy" }
        if ["crm_Accounts","crm_Contacts","crm_Leads","crm_Opportunities"].contains(module.model) { relations.addItem(withTitle:"関連文書…"); relations.lastItem?.representedObject = "documents" }
        if ["crm_Accounts","crm_Opportunities"].contains(module.model) { relations.addItem(withTitle:"関連タスク…"); relations.lastItem?.representedObject = "crmTasks" }
        if ["crm_Accounts","crm_Contacts"].contains(module.model) { relations.addItem(withTitle:"関連メール…"); relations.lastItem?.representedObject = "crmMail" }
        if module.model == "crm_Leads" { relations.addItem(withTitle:"担当通知…"); relations.lastItem?.representedObject = "leadNotifications" }
        relations.isHidden = relations.numberOfItems == 1
        applyingTargetSelection = true; rows = []; table.reloadData(); applyingTargetSelection = false; updateTargetSelectionControls(); refresh();applyReadOnlyControls()
    }
    @objc private func navigate(_ button: NSButton) { guard !restoreAdmissionClosed else{return};
        if CRMModule.all[button.tag].model == "Documents", !readOnlyWorkspace { openDocuments(); button.state = .off; return }
        guard window.attachedSheet == nil else { return }; module = CRMModule.all[button.tag]; linkedParent = nil; search.stringValue = ""; filter.selectItem(at:0); offset = 0; displayModule(); memory.settle()
    }
    @objc private func showCampaigns() { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard window.attachedSheet == nil, campaignsWindow == nil else { return }
        do { let runtime = campaignRuntime; let controller = try CRMCampaignsWindow(service:service,readiness:{guard let runtime else{throw NativeDBError.message("復元した配信接続は確認待ちです。")};try await runtime.validateForLaunch()},ai:campaignAIService(),allowsDelivery:effectPolicy?.allowsManualGroup(.campaigns)==true && runtime != nil); campaignsWindow = controller
            window.beginSheet(controller.window) { [weak self] _ in self?.campaignsWindow = nil; self?.memory.settle() }
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func showTemplates() { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard window.attachedSheet == nil, templatesWindow == nil else { return }
        do { let controller = try CRMTemplatesWindow(service:service,ai:campaignAIService(),allowsAI:effectPolicy?.allowsManual(["ai.embedding"])==true); templatesWindow = controller
            window.beginSheet(controller.window) { [weak self] _ in self?.templatesWindow = nil; self?.memory.settle() }
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func showCRMTasks() { openCRMTasks(parent:nil) }
    private func openCRMTasks(parent: NativeRecord?) { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard window.attachedSheet == nil, crmTasksWindow == nil else { return }
        do {
            let controller = try CRMAccountTasksWindow(service:service,parent:parent); crmTasksWindow = controller
            window.beginSheet(controller.window) { [weak self] _ in self?.crmTasksWindow = nil; self?.reload(); self?.memory.settle() }
        } catch { showError(error) }
    }
    private func openDocuments(parent: NativeRecord? = nil, focusedDocumentID: String? = nil) { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard window.attachedSheet == nil else { return }
        do {
            let controller = try CRMDocumentsWindow(service:service,linkedTo:parent,focusedDocumentID:focusedDocumentID); documentsWindow = controller
            window.beginSheet(controller.window) { [weak self] _ in self?.documentsWindow = nil; self?.reload(); self?.memory.settle() }
        } catch { showError(error) }
    }
    @objc private func filterChanged() { offset = 0; deleteButton.title = filter.indexOfSelectedItem == 1 ? "復元" : "削除"; reload() }
    @objc private func refresh() { reload() }
    func controlTextDidChange(_ notification: Notification) { offset = 0; reload(delay:0.18) }
    private func reload(delay: Double = 0, selected: SQLValue? = nil) {
        guard !quitPreflight, !mcpTerminating else { return }
        pending?.cancel(); version += 1; let version = version; let module = module; let term = search.stringValue; let offset = offset; let trash = filter.indexOfSelectedItem == 1; let parent = linkedParent
        let selectedTargetSnapshot = module.model == "crm_Targets" ? targetSelection.ids : []
        let invoiceSort = invoiceSort
        let matching: RecordFilter = module.model == "Invoices" ? .every([invoiceStatus.indexOfSelectedItem > 0 ? .equal("status",.text(CRMModule.invoiceStatuses[invoiceStatus.indexOfSelectedItem-1].0)) : .all,invoiceType.indexOfSelectedItem > 0 ? .equal("type",.text(CRMModule.invoiceTypes[invoiceType.indexOfSelectedItem-1].0)) : .all]) : module.model == "crm_Orders" ? .every([orderStatus.indexOfSelectedItem > 0 ? .equal("status",.text(OrderWorkflow.statuses[orderStatus.indexOfSelectedItem-1])) : .all,service.identity.elevated ? orderOwnerID.map { .equal("ownerId",$0) } ?? .all : .all]) : .all
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.readsState.lock(); let stopped = self.readsStopped; self.readsState.unlock()
            guard !stopped else { return }
            do {
                #if RESTORE_APP_TESTING
                try self.hostReadProbeForTesting?()
                #endif
                let result = try self.service.list(module,search:term,offset:offset,trash:trash,linkedTo:parent,matching:matching,invoiceSort:invoiceSort)
                let liveSelectedTargets = try NativeTargetSpreadsheetSelection.liveIDs(selectedTargetSnapshot,service:self.service,checkpoint:{
                    self.readsState.lock(); let stopped = self.readsStopped; self.readsState.unlock()
                    guard !stopped else { throw CancellationError() }
                })
                let parentWritable = parent.map { (try? self.service.assertAccess($0.model,id:$0["id"].string,write:true)) != nil } ?? true
                let parentAmount: String? = try parent.flatMap { p in
                    guard let field = LineContext.forModel(module.model)?.totalField else { return nil }
                    let current = try self.service.catalogRecord(p.model,p["id"])
                    return (current.model == "crm_Opportunities" ? "商談の金額：" : "契約の金額：")+current[field].string+" "+self.service.lineCurrency(current)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.quitPreflight, !self.mcpTerminating, self.version == version else { return }
                    if result.rows.isEmpty, offset > 0 { self.offset = max(0, ((result.total - 1) / 100) * 100); self.reload(); return }
                    self.applyingTargetSelection = true
                    self.rows = result.rows; self.total = result.total; self.table.reloadData()
                    if module.model == "crm_Targets" {
                        self.targetSelection.prune(snapshot:selectedTargetSnapshot,live:liveSelectedTargets)
                        if !trash {
                            if let selected { self.targetSelection.select(selected.string) }
                            self.table.selectRowIndexes(self.targetSelection.indexes(in:self.rows.map{$0.record["id"].string}),byExtendingSelection:false)
                        }
                    } else if let selected, let index = self.rows.firstIndex(where: { $0.record["id"] == selected }) { self.table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
                    self.applyingTargetSelection = false
                    let start = result.total == 0 ? 0 : offset + 1
                    self.count.stringValue = "\(start)–\(min(offset+100,result.total)) ／ \(result.total)件"; self.previous.isEnabled = offset > 0; self.next.isEnabled = offset+100 < result.total
                    self.create.isEnabled = !trash && (!CRMService.catalogModels.contains(module.model) || self.service.identity.elevated && (!["crm_ProductCategories","ExchangeRate"].contains(module.model) || self.service.identity.role == "admin")); if LineContext.forModel(module.model) != nil { self.create.isEnabled = self.create.isEnabled && parentWritable && parent?.model != "crm_Products" }
                    if module.model == "Invoices" { self.create.isEnabled = parentWritable }
                    if module.model == "crm_Orders" { self.create.isEnabled = self.service.identity.role != "partner" && parentWritable }
                    if module.model == "Boards" { self.create.isEnabled = self.service.identity.role != "partner" }
                    self.selectionChanged(); self.status.stringValue = self.readOnlyWorkspace ? NativeRestoreApplicationEffectPolicy.heldMessage : parentAmount ?? (trash ? "削除済みの情報を選択すると復元できます。" : result.total == 0 ? "新規登録から情報を追加できます。" : "行をダブルクリックすると編集できます。")
                    self.finishFirstWorkspaceRead(.success(()))
                }
            } catch { DispatchQueue.main.async { [weak self] in guard let self, !self.quitPreflight, !self.mcpTerminating, self.version == version else { return }; self.applyingTargetSelection = true; self.rows = []; self.table.reloadData(); self.applyingTargetSelection = false; self.selectionChanged(); self.status.stringValue = error.localizedDescription; self.finishFirstWorkspaceRead(.failure(error)) } }
        }
        pending = work; reads.asyncAfter(deadline:.now()+delay,execute:work)
    }
    private func selectionChanged() {
        guard !quitPreflight, !mcpTerminating else { return }
        if module.model == "crm_Targets", filter.indexOfSelectedItem == 0, !applyingTargetSelection {
            targetSelection.updatePage(ids:rows.map{$0.record["id"].string},indexes:table.selectedRowIndexes)
        }
        updateTargetSelectionControls()
        updatePluginRecordMenu()
        let selected = rows.indices.contains(table.selectedRow) && table.selectedRowIndexes.count == 1
        moveUp.isEnabled = selected && offset+table.selectedRow > 0 && search.stringValue.isEmpty; moveDown.isEnabled = selected && offset+table.selectedRow+1 < total && search.stringValue.isEmpty
        edit.isEnabled = selected && filter.indexOfSelectedItem == 0; historyButton.isEnabled = selected; deleteButton.isEnabled = selected; activities.isEnabled = selected && filter.indexOfSelectedItem == 0; actions.isEnabled = selected && filter.indexOfSelectedItem == 0
        relations.isEnabled = selected && (filter.indexOfSelectedItem == 0 || module.model == "crm_Leads" && service.identity.role == "admin")
        if module.model == "crm_Leads" { for item in relations.itemArray.dropFirst() { item.isEnabled = filter.indexOfSelectedItem == 0 || item.representedObject as? String == "leadNotifications" } }
        if selected, module.model == "crm_Orders" { deleteButton.isEnabled = (try? selectedRecord()).map { service.orderCan($0,"delete") } ?? false }
        if selected, module.model == "crm_Accounts" {
            let watching = (try? service.isWatching(rows[table.selectedRow].record["id"].string)) == true
            relations.item(at:1)?.title = watching ? "ウォッチを解除" : "ウォッチを開始"
            relations.item(at:1)?.isEnabled = service.identity.role != "partner"
            relations.item(at:2)?.isEnabled = service.identity.elevated; relations.item(at:3)?.isEnabled = service.identity.elevated
            relations.item(at:6)?.isEnabled = service.identity.role != "partner" && (try? service.assertAccess("crm_Accounts",id:rows[table.selectedRow].record["id"].string,write:true)) != nil
        }
        applyReadOnlyControls()
        table.enumerateAvailableRowViews { view, _ in view.subviews.forEach { $0.needsDisplay = true } }
    }
    private func selectedRecord() throws -> NativeRecord? {
        guard rows.indices.contains(table.selectedRow), table.selectedRowIndexes.count == 1 else { return nil }
        return try service.fullRecord(rows[table.selectedRow].record)
    }
    @objc private func newRecord() { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return}; if create.isEnabled && filter.indexOfSelectedItem == 0 { openEditor(nil) } }
    @objc private func editRecord() { guard !restoreAdmissionClosed else{return}; guard filter.indexOfSelectedItem == 0 else { return }; do { if let record = try selectedRecord() { openEditor(record) } } catch { showError(error) } }
    private func makeWorkspaceEditor(_ record:NativeRecord?,requestedReadOnly:Bool)throws->CRMEditor {
        try CRMEditor(module:module,record:record,linkedTo:linkedParent,service:service,readOnly:requestedReadOnly || readOnlyWorkspace)
    }
    private func showAccountCaseStudy(_ record: NativeRecord) {
        guard manualLocal(), record.model == "crm_Accounts", caseStudyWindow == nil, window.attachedSheet == nil else { return }
        do {
            let controller = try NativeAccountCaseStudyWindow(service: service, accountID: record["id"].string)
            caseStudyWindow = controller
            controller.onChanged = { [weak self] in self?.reload(selected: record["id"]) }
            window.beginSheet(controller.window) { [weak self] _ in self?.caseStudyWindow = nil; self?.memory.settle() }
        } catch { showError(error) }
    }
    private func openEditor(_ record: NativeRecord?, readOnly: Bool = false) { guard !restoreAdmissionClosed else{return};
        let viewingOnly=readOnly || readOnlyWorkspace
        guard record != nil || !viewingOnly else{status.stringValue=NativeRestoreApplicationEffectPolicy.heldMessage;return}
        guard editor == nil, window.attachedSheet == nil else { return }
        if !viewingOnly, module.model == "Boards" { if let record { openProject(record) } else { createProject() }; return }
        if !viewingOnly, module.model == "Invoices" { if let record { openInvoice(record,accountID:record["accountId"].string) } else { createInvoice(account:linkedParent) }; return }
        if !viewingOnly, module.model == "crm_Orders" { if let record { openOrder(record,accountID:record["accountId"].string) } else { createOrder(account:linkedParent) }; return }
        do {
            let controller = try makeWorkspaceEditor(record,requestedReadOnly:readOnly)
            if module.model == "crm_Accounts", !viewingOnly, let registry = plugins?.registry,
               try !registry.countries().isEmpty || registry.canValidateVat() {
                try controller.attachCompanyRegistry(registry, allowLookup: record == nil)
            }
            if let record, record.model == "crm_Accounts" {
                let state = try service.accountCaseStudy(record["id"].string)
                let hint = state.canSetCandidate || state.canApprove ? "　変更は編集画面を閉じて、一覧の「関連操作」→「導入事例…」から行います。" : "（表示のみ）"
                let summary = NSTextField(wrappingLabelWithString: "導入事例：" + state.label + hint)
                summary.setAccessibilityLabel("導入事例の状態")
                controller.installAccessory(summary, readOnlyAllowed: true, onClose: {})
            }
            if let record, let menu = pluginMenu(for: record, on: controller.window) {
                let popup = NSPopUpButton(frame: .zero, pullsDown: true); popup.menu = menu; popup.setAccessibilityLabel("この情報の連携情報")
                let controls = NSStackView(views: [popup, NSView()]); controls.spacing = 8
                controller.installAccessory(controls, readOnlyAllowed: true, onClose: {})
            }
            editor = controller
            window.beginSheet(controller.window) { [weak self,weak controller] _ in
                guard let self else { return }; let saved = controller?.saved; self.editor = nil
                if let saved { self.reload(selected:saved["id"]) }; self.memory.settle()
            }
        } catch { showError(error) }
    }
    private func createProject() { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        do {
            var created: NativeRecord?
            let controller = try CRMEditor(module:.projects,record:nil,linkedTo:nil,service:service,saveTitle:"作成",onSave:{ [service] input in created = try service!.saveProject(original:nil,input:input) }); editor = controller
            window.beginSheet(controller.window) { [weak self] result in
                guard let self else { return }; self.editor = nil
                if result == .OK, let created {
                    self.reload(selected:created["id"])
                    // Let AppKit finish detaching the creation sheet before
                    // opening the project's detail sheet on the same window.
                    DispatchQueue.main.async { [weak self] in self?.openProject(created) }
                }; self.memory.settle()
            }
        } catch { showError(error) }
    }
    private func openProject(_ record: NativeRecord) { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard projectWindow == nil, window.attachedSheet == nil else { return }
        let controller = CRMProjectWindow(project:record,service:service); projectWindow = controller
        window.beginSheet(controller.window) { [weak self] _ in guard let self else { return }; self.projectWindow = nil; self.reload(selected:record["id"]); self.memory.settle() }
    }
    @objc private func openAllProjectTasks() { openProjectTasks(mine:false) }
    @objc private func openMyProjectTasks() { openProjectTasks(mine:true) }
    private func openProjectTasks(mine: Bool) { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard window.attachedSheet == nil, taskOverviewWindow == nil else { return }
        let controller = CRMTaskOverviewWindow(service:service,mine:mine); taskOverviewWindow = controller
        window.beginSheet(controller.window) { [weak self] _ in guard let self else { return }; self.taskOverviewWindow = nil; self.reload(); self.memory.settle() }
    }
    @objc private func openProjectDashboard() { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard window.attachedSheet == nil, projectDashboardWindow == nil else { return }
        let controller = CRMProjectDashboardWindow(service:service); projectDashboardWindow = controller
        window.beginSheet(controller.window) { [weak self] _ in guard let self else { return }; self.projectDashboardWindow = nil; self.reload(); self.memory.settle() }
    }
    @objc private func showActivities() {
        do { guard let parent = try selectedRecord() else { return }; linkedParent = parent; module = CRMModule.find("crm_Activities")!; offset = 0; search.stringValue = ""; filter.selectItem(at:0); displayModule() } catch { showError(error) }
    }
    @objc private func deleteRecord() { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        do {
            guard let record = try selectedRecord() else { return }; let restore = filter.indexOfSelectedItem == 1
            let alert = NSAlert(); alert.messageText = restore ? "この情報を復元しますか？" : "この情報を削除済みに移動しますか？"
            let soft = (try service.db.schema.model(record.model)).field("deletedAt") != nil
            if !soft { alert.messageText = "この情報を削除しますか？" }
            alert.informativeText = CRMModule.displayName(record) + (restore ? "" : soft ? "\n管理者は削除済みの一覧から復元できます。" : "\nこの操作は元に戻せません。")
            let assignment = record.model == "crm_AccountProducts"
            if assignment { alert.messageText = "この商品割当を取り消しますか？"; alert.informativeText = "割当の履歴は残り、状態が取消済みになります。" }
            alert.addButton(withTitle:assignment ? "割当を取消" : restore ? "復元" : soft ? "削除済みに移動" : "削除"); alert.addButton(withTitle:"キャンセル")
            alert.beginSheetModal(for:window) { [weak self] result in
                guard let self, result == .alertFirstButtonReturn else { return }
                do { try self.service.delete(record,restore:restore); if record.model == "crm_Targets", !restore { self.targetSelection.remove(record["id"].string) }; self.reload(); self.memory.settle() } catch { self.showError(error) }
            }
        } catch { showError(error) }
    }
    @objc private func showHistory() { guard !restoreAdmissionClosed else{return};
        do {
            guard let record = try selectedRecord() else { return }
            let text = NSTextView(frame:NSRect(x:0,y:0,width:650,height:380)); text.isEditable = false; text.isRichText = false; text.font = .systemFont(ofSize:12); text.string = try service.historyText(record)
            let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:650,height:380)); scroll.documentView = text; scroll.hasVerticalScroller = true
            text.autoresizingMask = [.width]; text.isVerticallyResizable = true; text.textContainer?.widthTracksTextView = true
            let alert = NSAlert(); alert.messageText = "変更履歴"; alert.informativeText = CRMModule.displayName(record); alert.accessoryView = scroll; alert.addButton(withTitle:"閉じる"); alert.beginSheetModal(for:window)
        } catch { showError(error) }
    }
    @objc private func approvalAction(_ sender: NSPopUpButton) { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        do { guard let record = try selectedRecord(), sender.indexOfSelectedItem > 0 else { return }; let choices = ["","PENDING","APPROVED","REJECTED"]
            _ = try service.approval(record,decision:choices[sender.indexOfSelectedItem]); reload(selected:record["id"])
        } catch { showError(error) }
    }
    @objc private func relationAction(_ sender: NSPopUpButton) { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        let leadNotifications = sender.selectedItem?.representedObject as? String == "leadNotifications"
        guard window.attachedSheet == nil, filter.indexOfSelectedItem == 0 || leadNotifications else { return }
        do {
            guard let record = try selectedRecord() else { return }
            if leadNotifications {
                let controller = try CRMInvoiceJobsWindow(service:service,invoice:record); leadJobsWindow = controller
                window.beginSheet(controller.window) { [weak self] _ in self?.leadJobsWindow = nil; self?.memory.settle() }
                return
            }
            if sender.selectedItem?.representedObject as? String == "caseStudy" { showAccountCaseStudy(record); return }
            if sender.selectedItem?.representedObject as? String == "documents" { openDocuments(parent:record); return }
            if sender.selectedItem?.representedObject as? String == "crmTasks" { openCRMTasks(parent:record); return }
            if sender.selectedItem?.representedObject as? String == "crmMail" { showRelatedMail(record); return }
            if sender.selectedItem?.representedObject as? String == "enrichContact" { openEnrichment(contactID: record["id"].string); return }
            if sender.selectedItem?.representedObject as? String == "enrichmentHistory" { openEnrichmentHistory(contactID: record["id"].string); return }
            switch (module.model,sender.indexOfSelectedItem) {
            case ("crm_Accounts",5):
                linkedParent = record; module = .orders; offset = 0; search.stringValue = ""; filter.selectItem(at:0); orderStatus.selectItem(at:0); orderOwnerID = nil; orderOwner.title = "担当者：すべて"; displayModule()
            case ("crm_Accounts",6): createOrder(account:record)
            case ("crm_Accounts",7): linkedParent = record; module = .invoices; offset = 0; search.stringValue = ""; filter.selectItem(at:0); invoiceStatus.selectItem(at:0); invoiceType.selectItem(at:0); displayModule()
            case ("crm_Accounts",8): createInvoice(account:record)
            case ("crm_Accounts",4), ("crm_Products",2), ("crm_Opportunities",1), ("crm_Contracts",1):
                showLines(record)
            case ("crm_Contracts",2):
                let picker = CRMReferencePicker(model:"crm_Opportunities",service:service) { [weak self] source in
                    guard let self else { return }; self.referencePicker = nil; guard let source else { return }
                    let alert = NSAlert(); alert.messageText = "商談の明細を契約に追加しますか？"; alert.informativeText = CRMModule.displayName(source)+" → "+CRMModule.displayName(record)+"\n既存の契約明細の末尾に追加します。"
                    alert.addButton(withTitle:"コピー"); alert.addButton(withTitle:"キャンセル")
                    alert.beginSheetModal(for:self.window) { [weak self] response in guard let self, response == .alertFirstButtonReturn else { return }; do { _ = try self.service.copyOpportunityLines(to:record,from:source["id"].string); self.showLines(record) } catch { self.showError(error) } }
                }; referencePicker = picker; window.beginSheet(picker.window); picker.start()
            case ("crm_Products",1), ("crm_PriceLists",2):
                let controller = CRMPriceCheckWindow(service:service,productID:record.model == "crm_Products" ? record["id"] : .null,listID:record.model == "crm_PriceLists" ? record["id"] : .null)
                priceCheckWindow = controller; window.beginSheet(controller.window) { [weak self] _ in self?.priceCheckWindow = nil; self?.memory.settle() }
            case ("crm_PriceLists",1):
                linkedParent = record; module = .priceRule; offset = 0; search.stringValue = ""; filter.selectItem(at:0); displayModule()
            case ("crm_PriceLists",3), ("crm_PriceLists",4):
                let enabling = sender.indexOfSelectedItem == 3
                let alert = NSAlert(); alert.messageText = enabling ? "この価格表を標準に設定しますか？" : "標準価格表を解除しますか？"
                alert.informativeText = enabling ? CRMModule.displayName(record) : "取引先ごとの設定がない場合、商品の販売単価を使います。"
                alert.addButton(withTitle:enabling ? "設定" : "解除"); alert.addButton(withTitle:"キャンセル")
                alert.beginSheetModal(for:window) { [weak self] response in guard let self, response == .alertFirstButtonReturn else { return }; do { try self.service.setDefaultPriceList(enabling ? record["id"] : .null); self.status.stringValue = enabling ? "標準価格表を設定しました。" : "標準価格表を解除しました。" } catch { self.showError(error) } }
            case ("crm_TargetLists",1):
                let controller = CRMTargetListWindow(list:record,service:service); targetListWindow = controller
                window.beginSheet(controller.window) { [weak self] _ in guard let self else { return }; self.targetListWindow = nil; self.reload(selected:record["id"]); self.memory.settle() }
            case ("crm_Accounts",1):
                _ = try service.setWatching(record["id"].string,enabled:!service.isWatching(record["id"].string)); reload(selected:record["id"])
            case ("crm_Accounts",2):
                let picker = CRMReferencePicker(model:"Users",service:service,userRole:"partner") { [weak self] selected in
                    guard let self else { return }; self.referencePicker = nil
                    if let selected { do { _ = try self.service.setPartner(record,userID:selected["id"].string); self.reload(selected:record["id"]) } catch { self.showError(error) } }
                    self.memory.settle()
                }
                picker.window.title = "外部パートナーを選択"; referencePicker = picker; window.beginSheet(picker.window); picker.start()
            case ("crm_Accounts",3):
                let alert = NSAlert(); alert.messageText = "外部パートナーの設定を解除しますか？"; alert.informativeText = CRMModule.displayName(record)+"\nこの取引先を担当するパートナーのアクセスが解除されます。"; alert.addButton(withTitle:"解除"); alert.addButton(withTitle:"キャンセル")
                alert.beginSheetModal(for:window) { [weak self] result in guard let self, result == .alertFirstButtonReturn else { return }; do { _ = try self.service.setPartner(record,userID:nil); self.reload(selected:record["id"]) } catch { self.showError(error) } }
            case ("crm_Targets",1), ("crm_Targets",2): confirmConversion(record,deal:sender.indexOfSelectedItem == 2)
            case ("crm_Targets",3): openTargetEnrichment(targetID: record["id"].string)
            case ("crm_Targets",4): openTargetEnrichmentHistory(targetID: record["id"].string)
            case ("crm_Targets",5): openTargetContacts(targetID: record["id"].string)
            default: break
            }
        } catch { showError(error) }
    }
    private func showLines(_ parent: NativeRecord) {
        linkedParent = parent; module = CRMModule.find(LineContext.childModel(parent.model) ?? "crm_AccountProducts")!; offset = 0; search.stringValue = ""; filter.selectItem(at:0); displayModule()
    }
    private func createInvoice(account: NativeRecord?) { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard window.attachedSheet == nil else { return }
        if let account { openInvoice(nil,accountID:account["id"].string); return }
        let picker = CRMReferencePicker(model:"crm_Accounts",service:service,matching:service.scope("crm_Accounts",write:true)) { [weak self] record in
            guard let self else { return }; self.referencePicker = nil; if let record { self.openInvoice(nil,accountID:record["id"].string) }
        }; picker.window.title = "請求先を選択"; referencePicker = picker; window.beginSheet(picker.window); picker.start()
    }
    private func openInvoice(_ record: NativeRecord?, accountID: String) { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard invoiceWindow == nil, window.attachedSheet == nil else { return }
        // Diagnostic-only phase isolation on an explicitly selected test store.
        // Never changes invoice data or applies to the normal user database.
        let probe = ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_DATA_DIR"] != nil ? ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_INVOICE_MEMORY_PROBE"] : nil
        if probe == "data", let record {
            reads.async { [weak self] in
                guard let self else { return }
                let result = Result { try autoreleasepool { let draft = try self.service.makeInvoiceDraft(record); return (try draft.count(),try draft.page().count) } }
                DispatchQueue.main.async { [weak self] in
                    do { let (total,page) = try result.get(); self?.status.stringValue = "データ処理の診断完了：\(total)件／先頭\(page)件"; self?.memory.settle() }
                    catch { self?.status.stringValue = error.localizedDescription }
                }
            }
            return
        }
        let controller = CRMInvoiceWindow(service:service,invoice:record,accountID:accountID,mailStore:mailRuntime?.store,allowsMail:effectPolicy?.allowsManual(["mail.invoice"])==true && mailRuntime != nil,allowsFXLookup:effectPolicy?.allowsManual(["currency.ecb"])==true); invoiceWindow = controller
        window.beginSheet(controller.window) { [weak self,weak controller] _ in guard let self else { return }; let saved = controller?.saved; self.invoiceWindow = nil; self.reload(selected:saved?["id"]); self.memory.settle() }
        if probe != "shell" { controller.start() }
    }
    @objc private func openInvoiceSettings(_ sender: NSPopUpButton) { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard service.identity.role == "admin", window.attachedSheet == nil else { return }
        do {
            if sender.indexOfSelectedItem == 1 {
                let original = try service.invoiceSettings(); var values = try original?.values ?? service.db.initialValues("Invoice_Settings")
                if original == nil { values["baseCurrency"] = .text("JPY"); values["defaultDueDays"] = .integer(14) }
                let controller = try CRMEditor(module:.invoiceCompany,record:.init(model:"Invoice_Settings",values:values,revision:original?.revision ?? 0),linkedTo:nil,service:service,referenceFilters:["defaultSeriesId":.equal("active",.integer(1)),"defaultTaxRateId":.equal("active",.integer(1))],onSave:{ [service] input in _ = try service!.saveInvoiceSettings(original:original,input:input) })
                editor = controller; window.beginSheet(controller.window) { [weak self] _ in self?.editor = nil; self?.memory.settle() }; return
            }
            if sender.indexOfSelectedItem == 4 {
                showMailSettings(); return
            }
            guard [2,3].contains(sender.indexOfSelectedItem) else { return }; let module: CRMModule = sender.indexOfSelectedItem == 2 ? .invoiceSeries : .invoiceTax
            let controller = CRMInvoiceRecordsWindow(service:service,module:module,fetch:{ [service] term,offset in
                try service!.db.page(module.model,fields:service!.db.schema.model(module.model).fields.map(\.name),search:term,offset:offset,filter:service!.scope(module.model),sort:"name")
            },save:{ [service] original,input in if module.model == "Invoice_Series" { _ = try service!.saveInvoiceSeries(original:original,input:input) } else { _ = try service!.saveInvoiceTaxRate(original:original,input:input) } },remove:{ [service] record in try service!.deleteInvoiceConfiguration(record) })
            invoiceRecords = controller; window.beginSheet(controller.window) { [weak self] _ in self?.invoiceRecords = nil; self?.memory.settle() }; controller.start()
        } catch { showError(error) }
    }
    private func createOrder(account: NativeRecord?) { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard window.attachedSheet == nil, service.identity.role != "partner" else { return }
        if let account { openOrder(nil,accountID:account["id"].string); return }
        let picker = CRMReferencePicker(model:"crm_Accounts",service:service,matching:service.scope("crm_Accounts",write:true)) { [weak self] record in
            guard let self else { return }; self.referencePicker = nil
            if let record { self.openOrder(nil,accountID:record["id"].string) }
        }
        picker.window.title = "受注の取引先を選択"; referencePicker = picker; window.beginSheet(picker.window); picker.start()
    }
    private func openOrder(_ record: NativeRecord?, accountID: String) { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard orderWindow == nil, window.attachedSheet == nil else { return }
        let controller = CRMOrderWindow(service:service,order:record,accountID:accountID); orderWindow = controller
        controller.pluginMenu = { [weak self] record, parent in self?.pluginMenu(for: record, on: parent) }
        controller.linkForOrder = { [service] record in try service!.orderLink(record).string }
        controller.onShowNotifications = { [weak self] record,parent in
            guard let self else { return }
            let jobs = try CRMInvoiceJobsWindow(service:self.service,order:record); self.orderJobsWindow = jobs
            parent.beginSheet(jobs.window) { [weak self] _ in self?.orderJobsWindow = nil }
        }
        window.beginSheet(controller.window) { [weak self,weak controller] _ in
            guard let self else { return }; let saved = controller?.saved; self.orderWindow = nil; self.reload(selected:saved?["id"]); self.memory.settle()
        }; controller.start()
    }
    @objc private func orderFilterChanged() { offset = 0; reload() }
    @objc private func resetOrderFilters() { orderOwnerID = nil; orderOwner.title = "担当者：すべて"; orderStatus.selectItem(at:0); offset = 0; reload() }
    @objc private func chooseOrderOwner() { guard !restoreAdmissionClosed else{return};
        guard service.identity.elevated, window.attachedSheet == nil else { return }
        let picker = CRMReferencePicker(model:"Users",service:service) { [weak self] record in
            guard let self else { return }; self.referencePicker = nil
            if let record { self.orderOwnerID = record["id"]; self.orderOwner.title = "担当者："+CRMModule.displayName(record); self.offset = 0; self.reload() }
        }; picker.window.title = "受注の担当者で絞り込み"; referencePicker = picker; window.beginSheet(picker.window); picker.start()
    }
    @objc private func openOrderSettings() { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard service.identity.role == "admin", window.attachedSheet == nil else { return }
        do { let controller = try CRMOrderSettingsWindow(service:service); orderSettingsWindow = controller
            window.beginSheet(controller.window) { [weak self] _ in self?.orderSettingsWindow = nil; self?.memory.settle() }
        } catch { showError(error) }
    }
    @objc private func moveSelected(_ button: NSButton) { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        do { guard search.stringValue.isEmpty, let record = try selectedRecord() else { return }; let destination = offset+table.selectedRow+button.tag
            if try service.moveLine(record,direction:button.tag) { offset = max(0,destination/100*100); reload(selected:record["id"]) }
        } catch { showError(error) }
    }
    private func updateTargetSelectionControls() {
        let available = module.model == "crm_Targets" && filter.indexOfSelectedItem == 0 && !service.db.isReadOnly && !quitPreflight && !mcpTerminating
        targetSpreadsheet.isEnabled = available
        targetSelectPage.isEnabled = available && !rows.isEmpty
        targetClearSelection.isEnabled = available && targetSelection.count > 0
        targetSelectPage.title = !rows.isEmpty && targetSelection.indexes(in:rows.map{$0.record["id"].string}).count == rows.count ? "このページの選択を解除" : "このページをすべて選択"
        targetSelectedCount.stringValue = targetSelection.count == 0 ? "選択なし：現在の検索結果を書き出します" : "\(targetSelection.count)件選択中（別ページ・検索前の選択を含む）"
    }
    @objc private func toggleTargetPageSelection() {
        guard targetSelectPage.isEnabled,module.model == "crm_Targets",filter.indexOfSelectedItem == 0,!quitPreflight,!mcpTerminating,window.attachedSheet == nil else{return}
        let all = targetSelection.indexes(in:rows.map{$0.record["id"].string}).count == rows.count
        table.selectRowIndexes(all ? IndexSet() : IndexSet(integersIn:rows.indices),byExtendingSelection:false)
        selectionChanged()
    }
    @objc private func clearTargetSelection() {
        guard targetClearSelection.isEnabled,module.model == "crm_Targets",filter.indexOfSelectedItem == 0,!quitPreflight,!mcpTerminating,window.attachedSheet == nil else{return}
        targetSelection.clear();table.deselectAll(nil);selectionChanged()
    }
    @MainActor @objc private func openTargetSpreadsheet() {
        guard !quitPreflight,!mcpTerminating,window.attachedSheet == nil,targetSpreadsheet.isEnabled,module.model == "crm_Targets",filter.indexOfSelectedItem == 0 else{return}
        guard manualLocal() else{return}
        do {
            try service.authenticated()
            // Closing this sheet preserves explicit selection; leaving Targets clears it.
            let ids=targetSelection.ids
            let backend=NativeTargetSpreadsheetController(service:service,keys:effectPolicy?.allowsManual(["ai.embedding"])==true ? aiKeys:nil,admission:{[weak self] in
                guard let self else{throw CancellationError()}
                self.readsState.lock();let stopped=self.readsStopped;self.readsState.unlock()
                guard !stopped else{throw CancellationError()}
            })
            if usesQAServices {backend.request={_ in throw NativeTargetSpreadsheetFailure(message:"隔離検証では外部AIへ送信しません。")}}
            let controller=NativeTargetSpreadsheetWindow(controller:backend,selection:.init(selectedIDs:ids,search:search.stringValue))
            targetSpreadsheetWindow=controller
            window.beginSheet(controller.window){[weak self] _ in self?.targetSpreadsheetWindow=nil;self?.reload();self?.memory.settle()}
        }catch{showError(error)}
    }
    @objc private func openProductImport() { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        guard window.attachedSheet == nil, importProducts.isEnabled, module.model == "crm_Products" else { return }
        let controller = CRMProductImportWindow(service:service); productImportWindow = controller
        window.beginSheet(controller.window) { [weak self] _ in self?.productImportWindow = nil; self?.reload(); self?.memory.settle() }
    }
    private func confirmConversion(_ record: NativeRecord, deal: Bool) { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return};
        let alert = NSAlert(); alert.messageText = deal ? "営業対象から商談を作成しますか？" : "取引先と連絡先に変換しますか？"
        alert.informativeText = CRMModule.displayName(record)+"\n営業対象の元情報は残ります。作成済みの変換先がある場合は再利用します。"
        alert.addButton(withTitle:deal ? "商談を作成" : "変換"); alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                let converted = try self.service.convertTarget(record,createOpportunity:deal); self.reload(selected:record["id"])
                let result = NSAlert(); result.messageText = deal ? "商談を作成しました" : "取引先と連絡先を作成しました"
                result.informativeText = "取引先：\(CRMModule.displayName(converted.account))\n連絡先：\(CRMModule.displayName(converted.contact))" + (converted.opportunity.map { "\n商談："+CRMModule.displayName($0) } ?? "")
                result.addButton(withTitle:deal ? "商談を開く" : "連絡先を開く"); result.addButton(withTitle:"閉じる")
                result.beginSheetModal(for:self.window) { [weak self] response in
                    guard let self, response == .alertFirstButtonReturn else { return }
                    let record = converted.opportunity ?? converted.contact
                    self.module = CRMModule.find(record.model)!; self.linkedParent = nil; self.search.stringValue = record[self.module.sort].string; self.filter.selectItem(at:0); self.offset = 0; self.displayModule()
                    DispatchQueue.main.async { [weak self] in self?.openEditor(record) }
                }
            } catch { self.showError(error) }
        }
    }
    @objc private func back() { offset = max(0,offset-100); reload() }
    @objc private func forward() { if offset+100 < total { offset += 100; reload() } }
    @objc private func focusSearch() { window.makeFirstResponder(search) }
    @objc private func openData() { guard !restoreAdmissionClosed else{return}; guard manualLocal() else{return}; NSWorkspace.shared.open(support) }
    @objc private func openGuide() { guard !restoreAdmissionClosed else{return}; if let url = Bundle.main.url(forResource:"使い方",withExtension:"txt") { NSWorkspace.shared.open(url) } }
    @objc private func about() { guard !restoreAdmissionClosed else{return}; let alert = NSAlert(); alert.messageText = "NextCRM Native"; alert.informativeText = "日本語ネイティブ版 0.6\nSwift・AppKit・SQLite\nNextCRM © Pavel Dovhomilja — MIT License"; alert.beginSheetModal(for:window) }
    private func showError(_ error: Error) { let alert = NSAlert(); alert.messageText = "操作を完了できませんでした"; alert.informativeText = error.localizedDescription; alert.beginSheetModal(for:window) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let id = NSUserInterfaceItemIdentifier("crm-row")
        let cell = tableView.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = id; cell.configure(columns:columns(),values:rows[row].cells); return cell
    }
    /// Noninteractive final check. Existing form confirmations may run nested
    /// loops, so restore requires those live controllers to be closed first.
    @MainActor func checkRestoreParentAdmission(ownedWindows:[NSWindow])throws {
        guard !restoreAdmissionClosed else{throw NativeRestoreParentFailure.notFenced}
        guard let service,service.identity.role=="admin" else{throw NativeRestoreParentFailure.authority}
        try service.authenticated()
        var live:[(String,NSWindow)]=[]
        if let value=personalRuntimeWindow {live.append(("personalRuntimeWindow",value.window))}
        if let value=personalProviderReviewWindow {live.append(("personalProviderReviewWindow",value.window))}
        if let value=priceCheckWindow {live.append(("priceCheckWindow",value.window))}
        if let value=targetSpreadsheetWindow {live.append(("targetSpreadsheetWindow",value.window))}
        if let value=productImportWindow {live.append(("productImportWindow",value.window))}
        if let value=targetListWindow {live.append(("targetListWindow",value.window))}
        if let value=projectWindow {live.append(("projectWindow",value.window))}
        if let value=taskOverviewWindow {live.append(("taskOverviewWindow",value.window))}
        if let value=projectDashboardWindow {live.append(("projectDashboardWindow",value.window))}
        if let value=documentsWindow {live.append(("documentsWindow",value.window))}
        if let value=crmTasksWindow {live.append(("crmTasksWindow",value.window))}
        if let value=leadJobsWindow {live.append(("leadJobsWindow",value.window))}
        if let value=templatesWindow {live.append(("templatesWindow",value.window))}
        if let value=campaignsWindow {live.append(("campaignsWindow",value.window))}
        if let value=invoiceWindow {live.append(("invoiceWindow",value.window))}
        if let value=invoiceRecords {live.append(("invoiceRecords",value.window))}
        if let value=mailSettingsWindow {live.append(("mailSettingsWindow",value.window))}
        if let value=generalMailAccountsWindow {live.append(("generalMailAccountsWindow",value.window))}
        if let value=aiSettingsWindow {live.append(("aiSettingsWindow",value.window))}
        if let value=apiTokensWindow {live.append(("apiTokensWindow",value.window))}
        if let value=mcpSettingsWindow {live.append(("mcpSettingsWindow",value.window))}
        if let value=pluginsSettingsWindow {live.append(("pluginsSettingsWindow",value.window))}
        if let value=userAdministrationWindow {live.append(("userAdministrationWindow",value.window))}
        if let value=userProfileWindow {live.append(("userProfileWindow",value.window))}
        if let value=crmConfigurationWindow {live.append(("crmConfigurationWindow",value.window))}
        if let value=crmFunnelSettingsWindow {live.append(("crmFunnelSettingsWindow",value.window))}
        if let value=caseStudyWindow {live.append(("caseStudyWindow",value.window))}
        if let value=crmAutomationJobsWindow {live.append(("crmAutomationJobsWindow",value.window))}
        if let value=adminAuditWindow {live.append(("adminAuditWindow",value.window))}
        if let value=currencyAdministrationWindow {live.append(("currencyAdministrationWindow",value.window))}
        if let value=pluginStatusWindow {live.append(("pluginStatusWindow",value.window))}
        if let value=e2bSettingsWindow {live.append(("e2bSettingsWindow",value.window))}
        if let value=aiJobsWindow {live.append(("aiJobsWindow",value.window))}
        if let value=enrichmentRequestWindow {live.append(("enrichmentRequestWindow",value.window))}
        if let value=enrichmentHistoryWindow {live.append(("enrichmentHistoryWindow",value.window))}
        if let value=targetEnrichmentRequestWindow {live.append(("targetEnrichmentRequestWindow",value.window))}
        if let value=targetEnrichmentHistoryWindow {live.append(("targetEnrichmentHistoryWindow",value.window))}
        if let value=targetContactsWindow {live.append(("targetContactsWindow",value.window))}
        if let value=globalSearchWindow {live.append(("globalSearchWindow",value.window))}
        if let value=reportsWindow {live.append(("reportsWindow",value.window))}
        if let value=relatedMailWindow {live.append(("relatedMailWindow",value.window))}
        if let value=campaignSettingsWindow {live.append(("campaignSettingsWindow",value.window))}
        if let value=calendarSettingsWindow {live.append(("calendarSettingsWindow",value.window))}
        if let value=calendlySettingsWindow {live.append(("calendlySettingsWindow",value.window))}
        if let value=reportReviewWindow {live.append(("reportReviewWindow",value.window))}
        if let value=orderJobsWindow {live.append(("orderJobsWindow",value.window))}
        if let value=orderWindow {live.append(("orderWindow",value.window))}
        if let value=orderSettingsWindow {live.append(("orderSettingsWindow",value.window))}
        if let value=editor {live.append(("editor",value.window))}
        guard live.isEmpty else{throw NativeRestoreParentFailure.closeWindows(live.map{$0.0})}
        guard dataMaintenanceWindow?.hasOperation != true,restoreActivities.acceptedWriteCount==0 else{throw NativeRestoreParentFailure.busy}
        let owned=Set(ownedWindows.map(ObjectIdentifier.init))
        var current=window?.attachedSheet
        while let sheet=current {
            guard owned.contains(ObjectIdentifier(sheet)) else{throw NativeRestoreParentFailure.unownedSheet}
            current=sheet.attachedSheet
        }
        if let modal=NSApp.modalWindow,!owned.contains(ObjectIdentifier(modal)){throw NativeRestoreParentFailure.unownedSheet}
        if let maintenance=dataMaintenanceWindow,!owned.contains(ObjectIdentifier(maintenance.window)){throw NativeRestoreParentFailure.unownedSheet}
    }
    /// No await or modal confirmation between the final checks and this fence.
    /// This is terminal for this App instance; rollback is a fresh old-root launch.
    @MainActor func fenceRestoreParent(ownedWindows:[NSWindow])throws {
        try checkRestoreParentAdmission(ownedWindows:ownedWindows)
        restoreAdmissionClosed=true;quitPreflight=true
        try restoreActivities.seal()
        stopBackgroundWork();mcpStartup?.cancel();pluginsStartup?.cancel();currencyStartup?.cancel()
        maintenanceRecoveryOperation?.cancel();maintenanceRecovery?.cancel()
        showShutdownProgress()
    }
    @MainActor func drainRestoreParent()async throws->NativeRestoreParentActivities.Receipt {
        guard restoreAdmissionClosed else{throw NativeRestoreParentFailure.notFenced}
        await drainPersonalProviderReview()
        await drainDataMaintenance();await drainMaintenanceRecovery()
        await mcpStartup?.value;await mcpRuntime?.stop()
        await pluginsStartup?.value;await plugins?.runtime.stop()
        await currencyStartup?.value;await currencyRuntime?.stop()
        await drainBackgroundWork()
        let receipt=try await restoreActivities.drain()
        guard let service,service.identity.role=="admin" else{throw NativeRestoreParentFailure.authority}
        try service.authenticated();restoreDrainCompleted=true
        return receipt // Explicitly requires NOTE_EXIT for final DB-handle quiescence.
    }
    @MainActor func terminateAfterRestoreDrain()throws {
        guard restoreDrainCompleted else{throw NativeRestoreParentFailure.notFenced}
        // NSApp.terminate must run outside a Swift MainActor Task: terminateLater
        // enters a nested loop and otherwise starves the shutdown Task.
        quitConfirmed=true
        RunLoop.main.perform(inModes:[.default,.common]){NSApp.terminate(nil)}
    }

    #if RESTORE_PARENT_TESTING
    func prepareParentForTesting(_ service:CRMService){self.service=service;window=NSWindow(contentRect:.zero,styleMask:[.titled],backing:.buffered,defer:true)}
    var activitiesForTesting:NativeRestoreParentActivities {restoreActivities}
    func setWindowsForTesting(product:CRMProductImportWindow?=nil,target:CRMTargetListWindow?=nil,tokens:NativeAPITokensWindow?=nil){productImportWindow=product;targetListWindow=target;apiTokensWindow=tokens}
    @MainActor func confirmQuitForTesting()->Bool{confirmClose()}
    func blockedActionsForTesting(){newRecord();showAPITokens();showReports();showHistory();openData()}
    #endif

}
