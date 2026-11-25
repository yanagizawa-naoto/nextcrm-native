import Foundation
import CryptoKit

/// A receipt grants cleanup only after this attempt definitely failed publication.
/// A waiting/crash-ambiguous receipt is intentionally retained. Old references and
/// legacy orphan markers are not adopted into this queue and are never scanned.
enum NativeFreshCredentialPublication {
    enum Purpose:String,Codable { case email,google,calendly }
    struct Receipt:Codable,Equatable {
        let version:Int,namespace:String,ownerID:String
        var state:String
    }
    struct Cleanup {var removed=0,failed=0,retained=0}
    private final class Boundary {var ended=false}
    static func requireBoundary(_ db:NativeDatabase)throws {
        guard !db.isReadOnly else{throw NativeDBError.message("このデータベースは閲覧専用です。")}
        let boundary=Boundary();db.deferUntilTransactionEnds(onCommit:{boundary.ended=true},onRollback:{boundary.ended=true})
        guard boundary.ended else{throw NativeDBError.message("認証情報の保存・整理はデータ更新処理の外で実行してください。")}
    }
    static func namespace(_ db:NativeDatabase)->String {SHA256.hash(data:Data(db.url.resolvingSymlinksInPath().standardizedFileURL.path.utf8)).map{String(format:"%02x",$0)}.joined()}
    static func key(_ purpose:Purpose)->String {"credential.fresh.cleanup.v1."+purpose.rawValue}
    static func receipts(db:NativeDatabase,purpose:Purpose)throws->[String:Receipt] {
        guard let text=try db.metadata(key(purpose)),!text.isEmpty else{return [:]}
        guard text.utf8.count<=65536,let rows=try? JSONDecoder().decode([String:Receipt].self,from:Data(text.utf8)),rows.count<=128,
              rows.allSatisfy({UUID(uuidString:$0.key) != nil && $0.value.version==1 && UUID(uuidString:$0.value.ownerID) != nil && $0.value.namespace.utf8.count==64 && $0.value.namespace.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) && ["waiting","failed"].contains($0.value.state)}) else{throw NativeDBError.message("認証情報の保存結果を確認できません。保全状態を確認してください。")}
        return rows
    }
    private static func put(_ rows:[String:Receipt],db:NativeDatabase,purpose:Purpose)throws {try db.setMetadata(key(purpose),value:String(decoding:JSONEncoder().encode(rows),as:UTF8.self))}
    static func perform<T>(db:NativeDatabase,purpose:Purpose,ownerID:String,authorize:()throws->Void,
                           referenced:(String)throws->Bool,save:(String)throws->Void,remove:(String)throws->Void,publish:(String)throws->T)throws->T {
        try requireBoundary(db);try authorize();guard UUID(uuidString:ownerID) != nil else{throw NativeDBError.conflict};try Task.checkCancellation()
        _ = try cleanup(db:db,purpose:purpose,ownerID:ownerID,authorize:authorize,referenced:referenced,remove:remove)
        let id=UUID().uuidString.lowercased(),receipt=Receipt(version:1,namespace:namespace(db),ownerID:ownerID,state:"waiting")
        try db.transaction {try authorize();var rows=try receipts(db:db,purpose:purpose);guard rows.count<128 else{throw NativeDBError.message("未完了の認証情報が多いため保存できません。保全状態を確認してください。")};guard rows[id]==nil,try !referenced(id) else{throw NativeDBError.conflict};rows[id]=receipt;try put(rows,db:db,purpose:purpose)}
        do {
            try authorize();try Task.checkCancellation();try save(id);try Task.checkCancellation()
            return try db.transaction {
                try authorize();var rows=try receipts(db:db,purpose:purpose);guard rows[id]==receipt else{throw NativeDBError.conflict}
                let result=try publish(id);try Task.checkCancellation();rows.removeValue(forKey:id);try put(rows,db:db,purpose:purpose);return result
            }
        }catch{
            // No operation can resume a failed ID. A committed publication consumes
            // its receipt in the same transaction and cannot enter this branch.
            try? db.transaction {var rows=try receipts(db:db,purpose:purpose);guard rows[id]==receipt,try !referenced(id) else{return};var failed=receipt;failed.state="failed";rows[id]=failed;try put(rows,db:db,purpose:purpose)}
            _ = try? cleanup(db:db,purpose:purpose,ownerID:ownerID,authorize:authorize,referenced:referenced,remove:remove)
            throw error
        }
    }
    @discardableResult static func cleanup(db:NativeDatabase,purpose:Purpose,ownerID:String,authorize:()throws->Void,referenced:(String)throws->Bool,remove:(String)throws->Void)throws->Cleanup {
        try requireBoundary(db);try authorize();let own=namespace(db),ids=try db.transaction{try receipts(db:db,purpose:purpose).keys.sorted()};var result=Cleanup()
        for id in ids {
            try db.transaction {
                try authorize();var rows=try receipts(db:db,purpose:purpose)
                guard let receipt=rows[id] else{return}
                guard receipt.state=="failed",receipt.namespace==own,receipt.ownerID==ownerID,try !referenced(id) else{result.retained+=1;return}
                do{try remove(id)}catch{result.failed+=1;return}
                rows.removeValue(forKey:id);try put(rows,db:db,purpose:purpose);result.removed+=1
            }
        }
        return result
    }
}
