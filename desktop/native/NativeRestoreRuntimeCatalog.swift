import Foundation

/// Candidate-only catalog. IDs describe gates, not proof that a runtime drained.
enum NativeRestoreRuntimeCatalog {
    static let version = "native-app-restore-policy-v2"
    static let runtimes: [NativeRestoreActivationRuntime] = [
        .init(id:"ai.contacts",events:["enrich/contact.run", "enrich/contacts.bulk"],canProduceExternalEffects:true),
        .init(id:"ai.embedding",events:["crm/account.saved", "crm/backfill.requested", "crm/contact.saved", "crm/lead.saved", "crm/opportunity.saved", "document/enrich.requested", "email/embed-email"],canProduceExternalEffects:true),
        .init(id:"ai.targets",events:["enrich/target.contact.run", "enrich/target.run", "enrich/targets.bulk"],canProduceExternalEffects:true),
        .init(id:"calendar.calendly",events:["native.calendly.subscription", "native.calendly.sync"],canProduceExternalEffects:true),
        .init(id:"calendar.google",events:["calendar/outbound", "native.google-calendar.sync"],canProduceExternalEffects:true),
        .init(id:"campaign.delivery",events:["campaigns/send-step"],canProduceExternalEffects:true),
        .init(id:"campaign.dispatch",events:["campaigns/follow-up", "campaigns/schedule", "campaigns/send-now"],canProduceExternalEffects:false),
        .init(id:"campaign.relay",events:["native.campaign-relay.sync"],canProduceExternalEffects:true),
        .init(id:"credentials.ai-cleanup",events:[],canProduceExternalEffects:true),
        .init(id:"crm.automation",events:["crm/opportunity.stage-changed","crm.automation.stage.touch","crm.automation.renewals.scan","crm.automation.renewals.task","crm.automation.kill.scan","crm.automation.kill.check","crm.automation.recycle.scan","crm.automation.recycle.apply"],canProduceExternalEffects:false),
        .init(id:"currency.ecb",events:["currency/ecb-sync"],canProduceExternalEffects:true),
        .init(id:"documents.cleanup",events:["documents.file_cleanup"],canProduceExternalEffects:false),
        .init(id:"documents.processing",events:["document/uploaded"],canProduceExternalEffects:false),
        .init(id:"documents.recovery",events:[],canProduceExternalEffects:false),
        .init(id:"mail.crm-automation",events:["crm.automation.kill.notice","crm.automation.recycle.notice"],canProduceExternalEffects:true),
        .init(id:"mail.crm-tasks",events:["crm.task_assigned", "crm.task_watched"],canProduceExternalEffects:true),
        .init(id:"mail.general",events:["email/link-crm", "native.mail.body", "native.mail.send", "native.mail.sync"],canProduceExternalEffects:true),
        .init(id:"mail.invoice",events:["invoice.email_requested", "invoice.pdf_requested"],canProduceExternalEffects:true),
        .init(id:"mail.leads",events:["crm.lead_assigned"],canProduceExternalEffects:true),
        .init(id:"mail.orders",events:["orders.approval_decided", "orders.approval_requested"],canProduceExternalEffects:true),
        .init(id:"mail.projects",events:["projects.task_assigned", "projects.task_commented", "projects.task_updated"],canProduceExternalEffects:true),
        .init(id:"mail.reports",events:["reports.scheduled"],canProduceExternalEffects:true),
        .init(id:"maintenance.recovery",events:[],canProduceExternalEffects:false),
        .init(id:"mcp.server",events:[],canProduceExternalEffects:true),
        .init(id:"plugins.host",events:[],canProduceExternalEffects:true),
        .init(id:"plugins.scheduler",events:["plugin/after", "plugin/cron", "plugin/event", "plugin/event-dispatch", "plugin/installed"],canProduceExternalEffects:true),
        .init(id:"ui.external-actions",events:[],canProduceExternalEffects:true),
        .init(id:"workspace.local",events:[],canProduceExternalEffects:false),
    ]
    static let writerParticipants: [String] = ["maintenance.window-cancel-and-onClosed", "mcp.accepted-requests-and-listener", "runtime.ai.contacts", "runtime.ai.embedding", "runtime.ai.targets", "runtime.calendar.calendly", "runtime.calendar.google", "runtime.campaign.delivery", "runtime.campaign.dispatch", "runtime.campaign.relay", "runtime.credentials.ai-cleanup", "runtime.crm.automation", "runtime.currency.ecb", "runtime.documents.cleanup", "runtime.documents.processing", "runtime.documents.recovery", "runtime.mail.crm-automation", "runtime.mail.crm-tasks", "runtime.mail.general", "runtime.mail.invoice", "runtime.mail.leads", "runtime.mail.orders", "runtime.mail.projects", "runtime.mail.reports", "runtime.maintenance.recovery", "runtime.mcp.server", "runtime.plugins.host", "runtime.plugins.scheduler", "runtime.ui.external-actions", "startup.tasks-and-wake-callbacks", "ui.accepted-db-writes", "ui.avatar-file-publication", "ui.delayed-panels-and-callbacks", "ui.document-import-and-export", "ui.external-authorization-and-admin-actions", "ui.plugin-actions-and-company-registry", "ui.read-queues-and-main-callbacks", "ui.settings-secret-publication", "ui.unsaved-editors-and-child-sheets", "workspace.bootstrap-and-migration", "workspace.database-handles", "workspace.root-process-lease"]
    static let ids = runtimes.map(\.id)
    static let external = runtimes.filter(\.canProduceExternalEffects).map(\.id)
    static let heldAutomatic = ids.filter { $0 != "workspace.local" }
    static func eventOwners(_ event: String?) -> [String] {
        guard let event, !event.isEmpty else { return [] }
        return runtimes.filter { $0.events.contains(event) }.map(\.id)
    }
    static func validate(_ context: NativeRestoreActivationContext) throws {
        guard context.runtimeCatalog == runtimes, Set(context.previousRunning).count == context.previousRunning.count, Set(context.previousRunning).isSubset(of: Set(ids)), Set(context.inheritedPending).count == context.inheritedPending.count else { throw NativeRestoreActivationFailure("policy.catalog") }
    }
    static func blockedRuntimes(for row: NativeRestorePlanEntry) -> [String] {
        var blocked: [String]
        switch row.kind {
        case "job", "terminalReceipt":
            let owners = eventOwners(row.event); blocked = owners.isEmpty ? heldAutomatic : owners + ["ui.external-actions"]
            if owners.contains("plugins.scheduler") { blocked += ["plugins.host"] }
        case "credential":
            switch row.model {
            case "ApiKeys": blocked = ["ai.embedding","ai.contacts","ai.targets","credentials.ai-cleanup","ui.external-actions","mcp.server"]
            case "EmailAccount": blocked = ["mail.general","ui.external-actions","ai.embedding"]
            case "CalendarConnection": blocked = ["calendar.google","ui.external-actions"]
            case "InstalledPlugin": blocked = ["plugins.host","plugins.scheduler","ui.external-actions"]
            case "systemServices": blocked = external
            default: blocked = heldAutomatic
            }
        case "mailCursor": blocked = ["mail.general","ui.external-actions"]
        case "relayBinding":
            if row.key?.hasPrefix("campaignRelay.") == true { blocked = ["campaign.dispatch","campaign.delivery","campaign.relay","ui.external-actions"] }
            else if row.key?.hasPrefix("calendlyRelay.") == true { blocked = ["calendar.calendly","ui.external-actions"] }
            else { blocked = heldAutomatic }
        case "credentialCleanup": blocked = external
        case "serviceSetting":
            if row.key?.hasPrefix("mcp.") == true { blocked = ["mcp.server","ui.external-actions"] }
            else if row.key?.hasPrefix("calendar.google.") == true { blocked = ["calendar.google","ui.external-actions"] }
            else if row.key?.hasPrefix("calendly.") == true { blocked = ["calendar.calendly","ui.external-actions"] }
            else { blocked = heldAutomatic }
        case "eventReceipts", "relayRegistrations": blocked = ["campaign.dispatch","campaign.delivery","campaign.relay","ui.external-actions"]
        case "mailPayloads": blocked = ["mail.general","ui.external-actions"]
        case "pluginState": blocked = ["plugins.host","plugins.scheduler","ui.external-actions"]
        case "localWork": blocked = ["ai.embedding","documents.processing","documents.cleanup","documents.recovery"]
        case "keychainOnlySettings": blocked = external
        default: blocked = heldAutomatic
        }
        // An event on an unfamiliar row must still satisfy the coordinator fence.
        if let event = row.event { let owners = eventOwners(event); blocked += owners.isEmpty ? heldAutomatic : owners }
        if row.flags.contains("unknownState") { blocked += heldAutomatic }
        return Array(Set(blocked)).sorted()
    }
    static func blockedRuntimes(for kind: NativeRestoreHeldReviewKind) -> [String] {
        switch kind {
        case .sourceProvenance, .runtimeStartup, .jobs: return heldAutomatic
        case .credentials: return external
        case .relayAndPluginState: return ["calendar.calendly","campaign.delivery","campaign.dispatch","campaign.relay","mail.general","plugins.host","plugins.scheduler","ui.external-actions"]
        case .pendingAssets: return ["ai.embedding","documents.cleanup","documents.processing","documents.recovery","maintenance.recovery","ui.external-actions"]
        }
    }
}
