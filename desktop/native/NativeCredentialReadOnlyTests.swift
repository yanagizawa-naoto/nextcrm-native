import Foundation
import SQLite3

private final class ReadOnlySecretStore:NativeAISecretStore {
    var values:[String:Data]=[:],removed:[String]=[],loads=0,saves=0,fail=false
    func load(id:String,interactive:Bool)throws->Data?{loads+=1;return values[id]}
    func save(id:String,data:Data)throws{saves+=1;values[id]=data}
    func remove(id:String)throws{removed.append(id);if fail{throw NativeDBError.message("synthetic store refusal")};values[id]=nil}
}

@main enum NativeCredentialReadOnlyTests {
    static var checks=0
    static func check(_ value:@autoclosure ()throws->Bool,_ label:String)throws{guard try value() else{throw NativeDBError.message("FAIL: "+label)};checks+=1}
    static func main(){do{try run()}catch{FileHandle.standardError.write(Data("NativeCredentialReadOnlyTests: \(error)\n".utf8));exit(1)}}
    static func run()throws {
        let native=URL(fileURLWithPath:CommandLine.arguments[1]),root=URL(fileURLWithPath:CommandLine.arguments[2]),now=Date(timeIntervalSince1970:1_800_000_000)
        let db=try NativeDatabase(url:root.appendingPathComponent("source/crm.sqlite"),schemaURL:native.appendingPathComponent("schema.json"),sqlURL:native.appendingPathComponent("schema.sql"))
        let identity=try CRMService.bootstrap(db,resources:native.appendingPathComponent("../../prisma"))
        let due=UUID().uuidString.lowercased(),held=UUID().uuidString.lowercased(),future=UUID().uuidString.lowercased()
        try db.queueAIKeyCleanup(due,notBefore:now.addingTimeInterval(-1));try db.queueAIKeyCleanup(held,notBefore:now.addingTimeInterval(-1));try db.queueAIKeyCleanup(future,notBefore:now.addingTimeInterval(1))
        try db.setMetadata(NativeUserCredentialCleanup.markerKey(.ai,held),value:"invalid restored marker still holds")
        func sealed(_ name:String)throws->NativeDatabase {
            let path=root.appendingPathComponent(name+".sqlite");var source:OpaquePointer?,dest:OpaquePointer?
            guard sqlite3_open_v2(db.url.path,&source,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,sqlite3_open(path.path,&dest)==SQLITE_OK,let copy=sqlite3_backup_init(dest,"main",source,"main") else{throw NativeDBError.conflict}
            let result=sqlite3_backup_step(copy,-1);sqlite3_backup_finish(copy);sqlite3_close(source);sqlite3_close(dest)
            try check(result==SQLITE_DONE,"actual SQLite backup sealed")
            return try NativeDatabase(readOnlyURL:path,schemaURL:native.appendingPathComponent("schema.json"))
        }
        let readOnly=try sealed("sealed"),before=try Data(contentsOf:readOnly.url)
        try check(readOnly.isReadOnly && !db.isReadOnly,"actual read-only opener")
        try check(try readOnly.aiKeyCleanupPage(now:now).sorted()==[due,held].sorted(),"readonly cleanup queue is readable")
        var closureInvocations=0,readonlyFailures=0
        for family in [NativeUserCredentialCleanup.Family.ai,.email,.google] {
            let id=UUID().uuidString.lowercased(),store=ReadOnlySecretStore();store.values[id]=Data("synthetic disposable fixture".utf8)
            var erased:Bool?,failure:Error?
            do{erased=try NativeUserCredentialCleanup.removeUnlessHeld(db:readOnly,family:family,credentialID:id){closureInvocations+=1;try store.remove(id:id)}}catch{failure=error}
                try check(erased==nil && failure?.localizedDescription=="このデータベースは閲覧専用です。","readonly cleanup explicitly refused")
                try check(store.removed.isEmpty && store.values[id] != nil,"readonly "+family.rawValue+" keeps fake secret");readonlyFailures+=1
            try check(store.loads==0 && store.saves==0,"cleanup performs no other credential operation")
        }
        let heldStore=ReadOnlySecretStore();heldStore.values[held]=Data([1]);var heldOutcome:Bool?,heldError:Error?
        do{heldOutcome=try NativeUserCredentialCleanup.removeUnlessHeld(db:readOnly,family:.ai,credentialID:held){try heldStore.remove(id:held)}}catch{heldError=error}
        try check(heldStore.removed.isEmpty && heldStore.values[held] != nil,"readonly held key retained")
        try check(heldOutcome==nil && heldError?.localizedDescription=="このデータベースは閲覧専用です。","readonly mode checked even when hold exists")
        let aiStore=ReadOnlySecretStore();aiStore.values=[due:Data([2]),held:Data([3]),future:Data([4])]
        var ai=NativeAIKeys(service:CRMService(db:readOnly,identity:identity),store:aiStore);ai.clock={now};ai.environment=NativeAIEnvironment(lookup:{_ in nil})
        var aiResult:(removed:Int,pending:Int)?,aiError:Error?
        do{aiResult=try ai.cleanup()}catch{aiError=error}
            try check(aiResult==nil && aiError?.localizedDescription=="このデータベースは閲覧専用です。","AI readonly cleanup explicitly refused")
            try check(aiStore.removed.isEmpty && aiStore.values.count==3,"AI readonly guard precedes every fake-store operation");readonlyFailures+=1
        try check(aiStore.loads==0 && aiStore.saves==0,"no other AI credential operation")
        try check(try readOnly.aiKeyCleanupPage(now:now).sorted()==[due,held].sorted(),"sealed queue survives failure/denial")
        try check(try Data(contentsOf:readOnly.url)==before,"sealed SQLite bytes unchanged")
        try check(!FileManager.default.fileExists(atPath:readOnly.url.path+"-wal") && !FileManager.default.fileExists(atPath:readOnly.url.path+"-shm") && !FileManager.default.fileExists(atPath:readOnly.url.path+"-journal"),"no readonly sidecars")
        // Writable controls preserve the preexisting hold/removal and retry behavior.
        let writableStore=ReadOnlySecretStore()
        for family in [NativeUserCredentialCleanup.Family.ai,.email,.google] {
            let id=UUID().uuidString.lowercased();writableStore.values[id]=Data([5])
            try check(try NativeUserCredentialCleanup.removeUnlessHeld(db:db,family:family,credentialID:id){try writableStore.remove(id:id)},"writable explicit cleanup proceeds")
            try check(writableStore.values[id]==nil,"writable key removed")
            let holdID=UUID().uuidString.lowercased();try db.setMetadata(NativeUserCredentialCleanup.markerKey(family,holdID),value:"held");writableStore.values[holdID]=Data([6])
            try check(try !NativeUserCredentialCleanup.removeUnlessHeld(db:db,family:family,credentialID:holdID){try writableStore.remove(id:holdID)},"writable held cleanup stays deferred")
            try check(writableStore.values[holdID] != nil,"writable held key retained")
        }
        let writableAIStore=ReadOnlySecretStore();writableAIStore.values=[due:Data([7]),held:Data([8]),future:Data([9])]
        var writableAI=NativeAIKeys(service:CRMService(db:db,identity:identity),store:writableAIStore);writableAI.clock={now};writableAI.environment=NativeAIEnvironment(lookup:{_ in nil})
        let writableResult=try writableAI.cleanup()
        try check(writableResult.removed==1 && writableResult.pending==1 && writableAIStore.removed==[due],"writable AI removes eligible and keeps held")
        try check(try db.aiKeyCleanupPage(now:now)==[held],"writable AI clears successful queue row only")
        writableAIStore.fail=true;writableAI.clock={now.addingTimeInterval(2)}
        let retry=try writableAI.cleanup()
        try check(retry.removed==0 && retry.pending==2 && writableAIStore.values[future] != nil,"writable store failure remains pending")
        try check(try db.aiKeyCleanupPage(now:now.addingTimeInterval(2)).sorted()==[held,future].sorted(),"failed cleanup reservation retained")
        try check(try Data(contentsOf:readOnly.url)==before,"source writable controls do not alter sealed snapshot")
        let output:[String:Any]=["checks":checks,"readonlyGuardRejections":readonlyFailures,"readonlyExplicitRemoveClosureInvocations":closureInvocations,"readonlyAIStoreRemoveCalls":aiStore.removed.count,"realKeychainCalls":0,"normalData":false,"network":false]
        print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:.sortedKeys),as:UTF8.self))
    }
}
