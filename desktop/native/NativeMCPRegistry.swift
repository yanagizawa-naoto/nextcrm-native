import Foundation

/// One registration point for every original operation. External capabilities
/// are explicit; the application still owns authentication and runtime setup.
enum NativeMCPRegistry {
    static func makeHandlers(documentStorage: NativeMCPDocumentStorage,
                             enrichmentStore: @escaping NativeMCPEnrichment.Store = { KeychainNativeAISecrets(databaseURL: $0.db.url) },
                             enrichmentEnvironment: NativeAIEnvironment = NativeAIEnvironment(),
                             authorizeUserDirectory: @escaping NativeMCPReports.UserDirectoryAuthorization = { _ in throw NativeMCPFailure.reportSessionUnauthenticated },
                             clock: @escaping () -> Date = Date.init) -> [String: NativeMCPRequestRouter.Handler] {
        let families = [NativeMCPAccounts.handlers, NativeMCPContacts.handlers,
            NativeMCPUsers.handlers, NativeMCPEmailAccounts.handlers,
            NativeMCPLeads.handlers, NativeMCPOpportunities.handlers,
            NativeMCPContracts.handlers, NativeMCPTargets.handlers,
            NativeMCPTargetLists.handlers, NativeMCPProjects.handlers,
            NativeMCPActivities.handlers, NativeMCPProducts.handlers,
            NativeMCPPriceLists.handlers,
            NativeMCPDocuments.handlers(storage: documentStorage),
            NativeMCPCampaigns.handlers(events: NativeMCPCampaigns.persist, clock: clock),
            NativeMCPOrders.makeHandlers(clock: clock),
            NativeMCPReports.makeHandlers(clock: clock, authorizeUserDirectory: authorizeUserDirectory),
            NativeMCPEnrichment.handlers(store: enrichmentStore, environment: enrichmentEnvironment, clock: clock)]
        return families.reduce(into: [:]) { result, family in
            for (name, handler) in family {
                precondition(result[name] == nil, "Duplicate MCP operation: " + name)
                result[name] = handler
            }
        }
    }
}
