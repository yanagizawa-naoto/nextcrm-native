import Foundation

// Oracle: original native audit serializer before the memory-only replacement.
// The fixed baseline method is recorded by the handoff manifest. key(for:) and
// secret() are unchanged production helpers; only this tiny test extension is
// appended to a private copy, never to the application source.
extension NativeDatabase {
    func auditProbeWrite(before:NativeRecord?,after:NativeRecord)throws{try audit(before:before,after:after,action:"probe",actor:"synthetic")}
    func auditProbeLast()throws->[String:SQLValue]{try query("SELECT record_key,before_json,after_json,action,actor FROM native_audit ORDER BY rowid DESC LIMIT 1").first!}
    func auditProbeSQL(_ sql:String)throws{try execute(sql)}
    func auditProbeOriginal(before:NativeRecord?,after:NativeRecord)throws->[String:SQLValue] {
        let key = try key(for: after)
        func json(_ values: [String: SQLValue]) throws -> String {
            let hiddenModel = ["ApiKeys", "ApiToken", "Account", "Session", "Verification", "EmailAccount", "CalendarConnection"].contains(after.model)
            let safe = values.mapValues(\.json).filter { !secret($0.key) && (!hiddenModel || key[$0.key] != nil) }
            return String(decoding: try JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
        }
        return ["record_key":.text(try json(key)),"before_json":before == nil ? .null:.text(try json(before!.values)),"after_json":.text(try json(after.values))]
    }
}
