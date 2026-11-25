import Foundation

/// Immutable launch policy. No environment override and no runtime unhold API.
/// A later review must supply a new validated StartupPlan through the host.
struct NativeRestoreApplicationEffectPolicy {
    let plan: NativeRestoreApplicationStartupPlan
    private let permitted: Set<String>
    init(_ plan: NativeRestoreApplicationStartupPlan) throws {
        let known=Set(NativeRestoreRuntimeCatalog.ids),allowed=Set(plan.permitted),held=Set(plan.held)
        guard allowed.count==plan.permitted.count,held.count==plan.held.count,
              allowed.isDisjoint(with:held),allowed.union(held)==known,
              plan.mode != .ordinary || allowed==known && !plan.requiresReview else { throw NativeRestoreActivationFailure("app.policy") }
        let ordinaryComposition=[NativeRestoreApplicationStartupMode.ordinary,.previousPolicy].contains(plan.mode) &&
            allowed==known && held.isEmpty && !plan.requiresReview
        let heldComposition=[NativeRestoreApplicationStartupMode.restoredHeld,.approvedHandoff].contains(plan.mode) &&
            allowed==Set(["workspace.local"]) && held==Set(NativeRestoreRuntimeCatalog.heldAutomatic) && plan.requiresReview
        try NativePersonalRuntimeResumption.validatePlan(plan)
        let personalAllowed=Set(plan.runtimeReview == nil ? NativePersonalRuntimeResumption.permitted(plan.resumption):["workspace.local"])
        let personalComposition=[NativeRestoreApplicationStartupMode.personalBindingPending,.personalActiveLocal].contains(plan.mode) &&
            allowed==personalAllowed && held==known.subtracting(personalAllowed) && plan.requiresReview &&
            plan.personal?.authority.selection==plan.selection &&
            plan.personal?.phase == (plan.mode == .personalActiveLocal ? .bound:.bindingPending)
        guard ordinaryComposition || heldComposition || personalComposition else {throw NativeRestoreActivationFailure("app.unsupportedComposition")}
        self.plan=plan;permitted=allowed
    }
    func allows(_ id:String)->Bool { permitted.contains(id) }
    func allowsAny(_ ids:[String])->Bool { ids.contains(where:allows) }
    var hasWorkspace:Bool { allows("workspace.local") }
    var readOnlyWorkspace:Bool {
        if plan.mode == .personalActiveLocal {return false}
        return plan.requiresReview || !allows("plugins.host") || !allows("ui.external-actions")
    }
    var allowsMutation:Bool { hasWorkspace && !readOnlyWorkspace }
    func allowsManual(_ ids:[String]=[])->Bool {
        guard allowsMutation else{return false}
        if plan.resumption != nil {return !ids.isEmpty && ids.allSatisfy{ $0 != "ui.external-actions" && $0 != "workspace.local" && allows($0) }}
        return allows("ui.external-actions") && ids.allSatisfy(allows)
    }
    func allowsSettings(_ group:NativePersonalRuntimeGroup)->Bool {
        guard allowsMutation else{return false}
        if let review=plan.runtimeReview{return review.settings.contains(group)}
        if let record=plan.resumption{return record.settings.contains(group)}
        return allows("ui.external-actions")
    }
    func allowsManualGroup(_ group:NativePersonalRuntimeGroup)->Bool {
        allowsMutation && group.runtimeIDs.allSatisfy(allows) && (plan.resumption?.workers.contains(group) ?? allows("ui.external-actions"))
    }
    /// The body is never evaluated for a held ID. Tests use throwing key/network
    /// spies here; application constructors use the exact same boundary.
    func construct<T>(_ id:String,_ body:()throws->T)rethrows->T? { guard allows(id) else{return nil};return try body() }
    func wake(_ id:String,_ body:()->Void) {guard allows(id) else{return};body()}
    static let personalHeldMessage="このMacでの編集は有効です。復元前の送信・同期・連携は確認が終わるまで停止しています。"
    static let heldMessage="復元後の確認が完了するまで閲覧専用です。編集・送信・同期・連携は停止しています。"
}
