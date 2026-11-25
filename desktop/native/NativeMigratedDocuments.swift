import Foundation
import CryptoKit

/// Provenance does not grant access. An imported row must still match its
/// authorization-bearing source fields/links and today's live user predicate.
enum NativeMigratedDocuments {
    static let fields=["id","parent_document_id","created_by_user","createdBy","assigned_user","visibility","deletedAt"]
    static let links=[("DocumentsToAccounts","account_id"),("DocumentsToLeads","lead_id"),("DocumentsToContacts","contact_id"),("DocumentsToOpportunities","opportunity_id")]
    static func key(_ id:String)->String{"migration.document.authorization.v1."+id}
    static func fingerprint(_ row:NativeRecord,db:NativeDatabase)throws->String{
        var digest=SHA256()
        func append(_ text:String){let bytes=Data(text.utf8);digest.update(data:Data(String(bytes.count).utf8));digest.update(data:Data([0]));digest.update(data:bytes)}
        for field in fields{append(field);append(row[field] == .null ? "null":"text:"+row[field].string)}
        for (model,field) in links {append(model);var offset=0
            while true{try Task.checkCancellation();let page=try db.page(model,fields:[field],equal:["document_id":row["id"]],includeDeleted:true,offset:offset,sort:field,descending:false,limit:100)
                for item in page.rows{append(item[field].string)};offset+=page.rows.count;if page.rows.count<100{break}
            }
        }
        return digest.finalize().map{String(format:"%02x",$0)}.joined()
    }
    static func recordAll(in db:NativeDatabase)throws{
        var after:String?
        while true{let rows=try db.keysetPage("Documents",fields:fields,after:after,includeDeleted:true,limit:100)
            for row in rows{try db.setMetadata(key(row["id"].string),value:fingerprint(row,db:db))}
            guard let last=rows.last,rows.count==100 else{break};after=last["id"].string
        }
    }
}
extension CRMService {
    func hasImportedDocumentProof(_ id:String)throws->Bool{try db.metadata(NativeMigratedDocuments.key(id)) != nil}
    func importedDocumentAuthorize(_ id:String)throws->NativeRecord {
        try db.transaction {
            try authenticated()
            guard let proof=try db.metadata(NativeMigratedDocuments.key(id)),let current=try db.keysetPage("Documents",fields:NativeMigratedDocuments.fields,filter:.equal("id",.text(id)),includeDeleted:true,limit:1).first else{throw NativeDBError.conflict}
            guard try db.importedDocumentAncestorsLive(id) else{throw NativeDBError.message("文書または親文書が削除されたか、親関係が不正です。")}
            if proof != (try NativeMigratedDocuments.fingerprint(current,db:db)) {
                // Changed authorization data revokes the legacy exception. The
                // ordinary current native guard may independently grant access.
                try assertAccess("Documents",id:id);return current
            }
            let predicate=RecordFilter.every([.equal("id",.text(id)),.equal("deletedAt",.null),documentRootScope(write:false)])
            guard try db.page("Documents",fields:[],filter:predicate,limit:1).total==1 else{throw NativeDBError.message("この文書を閲覧する権限がありません。")}
            return current
        }
    }
    func importedDocumentRecord(_ id:String)throws->NativeRecord {
        try db.transaction{_ = try importedDocumentAuthorize(id);guard let row=try db.get("Documents",key:["id":.text(id)])else{throw NativeDBError.conflict};return row}
    }

}
