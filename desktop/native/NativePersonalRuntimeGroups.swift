import Foundation

/// These are closed application feature families, never caller-selected runtime
/// IDs. Settings admission alone does not construct, wake or permit a worker.
enum NativePersonalRuntimeGroup:String,Codable,CaseIterable,Comparable {
    case mailAccounts,resendNotifications,scheduledReports,campaigns,googleCalendar,calendly
    case aiDocumentsAndSearch,aiContacts,aiTargets,aiKeyCleanup,plugins,crmAutomation,documents,currency,mcp,maintenance
    static func <(a:Self,b:Self)->Bool{a.rawValue<b.rawValue}
    var title:String {
        switch self {
        case .mailAccounts:return "メールアカウントの送受信"
        case .resendNotifications:return "請求書・CRMの通知メール"
        case .scheduledReports:return "定期レポートの送信"
        case .campaigns:return "キャンペーンの配信"
        case .googleCalendar:return "Googleカレンダー"
        case .calendly:return "Calendly"
        case .aiDocumentsAndSearch:return "AI文書処理・検索"
        case .aiContacts:return "連絡先のAI調査"
        case .aiTargets:return "営業先のAI調査"
        case .aiKeyCleanup:return "不要なAI認証情報の整理"
        case .plugins:return "プラグインの連携処理"
        case .crmAutomation:return "CRMの自動処理"
        case .documents:return "文書の処理・整理"
        case .currency:return "為替レートの更新"
        case .mcp:return "MCP接続"
        case .maintenance:return "保存途中ファイルの保全整理"
        }
    }
    var runtimeIDs:[String] {
        switch self {
        case .mailAccounts:return ["mail.general"]
        case .resendNotifications:return ["mail.invoice","mail.orders","mail.projects","mail.crm-tasks","mail.crm-automation","mail.leads"]
        case .scheduledReports:return ["mail.reports"]
        case .campaigns:return ["campaign.dispatch","campaign.delivery","campaign.relay"]
        case .googleCalendar:return ["calendar.google"]
        case .calendly:return ["calendar.calendly"]
        case .aiDocumentsAndSearch:return ["ai.embedding"]
        case .aiContacts:return ["ai.contacts"]
        case .aiTargets:return ["ai.targets"]
        case .aiKeyCleanup:return ["credentials.ai-cleanup"]
        case .plugins:return ["plugins.host","plugins.scheduler"]
        case .crmAutomation:return ["crm.automation"]
        case .documents:return ["documents.cleanup","documents.processing","documents.recovery"]
        case .currency:return ["currency.ecb"]
        case .mcp:return ["mcp.server"]
        case .maintenance:return ["maintenance.recovery"]
        }
    }
    var requirements:[NativePersonalRuntimeRequirement] {
        switch self {
        case .mailAccounts:return [.imapSMTPAccountsAndCursors]
        case .resendNotifications:return [.resendSender]
        case .scheduledReports:return [.resendSender,.reportSchedules]
        case .campaigns:return [.resendSender,.campaignSchedules,.campaignRelay]
        case .googleCalendar:return [.googleConnectionsAndCursors]
        case .calendly:return [.calendlySubscriptionsAndRelay]
        case .aiDocumentsAndSearch:return [.openAI,.aiOutstandingWork]
        case .aiContacts,.aiTargets:return [.openAI,.e2b,.aiOutstandingWork]
        case .aiKeyCleanup:return [.credentialCleanupOwnership]
        case .plugins:return [.allEnabledPluginsAndSchedules]
        case .crmAutomation:return [.crmAutomationSchedules]
        case .documents:return [.documentPendingWork]
        case .currency:return [.ecbSettings]
        case .mcp:return [.mcpCredentialsAndListener]
        case .maintenance:return [.maintenanceOwnership]
        }
    }
    static func permitted(_ groups:[Self])->[String]{(["workspace.local"]+groups.flatMap(\.runtimeIDs)).sorted()}
    static func validateCatalog()throws {
        let ids=allCases.flatMap(\.runtimeIDs)
        guard Set(ids).count==ids.count,Set(ids)==Set(NativeRestoreRuntimeCatalog.ids).subtracting(["workspace.local","ui.external-actions"]) else{
            throw NativeRestoreActivationFailure("personal.runtimeCatalogChanged")
        }
    }
}
/// A provider/group verifier must cover each named dependency, not return one
/// successful credential check for an entire notification/scheduler group.
enum NativePersonalRuntimeRequirement:String,Codable,CaseIterable,Comparable {
    case imapSMTPAccountsAndCursors,resendSender,reportSchedules,campaignSchedules,campaignRelay
    case googleConnectionsAndCursors,calendlySubscriptionsAndRelay,openAI,e2b,aiOutstandingWork
    case credentialCleanupOwnership,allEnabledPluginsAndSchedules,crmAutomationSchedules,documentPendingWork
    case ecbSettings,mcpCredentialsAndListener,maintenanceOwnership
    static func <(a:Self,b:Self)->Bool{a.rawValue<b.rawValue}
}
