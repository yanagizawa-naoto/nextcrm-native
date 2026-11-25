import Foundation

final class NativeMigrationPreflight {
    typealias SecretProbe = (NativeMigrationSecretReference) -> NativeMigrationSecretAvailability
    private let options:NativeMigrationOptions,probe:SecretProbe,cancelled:()->Bool
    private var result=NativeMigrationResult()
    private var schema:NativeMigrationSchema!
    private var models:[String:NativeMigrationSchema.Model]=[:]
    private var index:NativeMigrationIndex!
    private var source:NativeMigrationManifest.Source!
    private var files:NativeMigrationFiles!
    init(options:NativeMigrationOptions = .init(),secretAvailability:@escaping SecretProbe = {_ in .unknown},cancelled:@escaping ()->Bool = {Task.isCancelled}) {
        self.options=options;self.probe=secretAvailability;self.cancelled=cancelled
    }
    /// Single use is not required: every invocation receives its own scratch index.
    func inspect(bundleURL:URL,schemaURL:URL)->NativeMigrationResult {
        result=NativeMigrationResult();models=[:];index=nil;files=nil;schema=nil;source=nil
        defer {index=nil;files=nil;schema=nil;models=[:];source=nil}
        do {
            guard (1024...64*1024*1024).contains(options.maximumLineBytes),(1024...16*1024*1024).contains(options.maximumMetadataBytes),(1...10000).contains(options.maximumDiagnostics) else {throw NativeMigrationFailure("options.invalid","検査上限の設定が不正です。")}
            let catalog=try NativeMigrationFiles(root:schemaURL.deletingLastPathComponent()).data(schemaURL.lastPathComponent,maximum:options.maximumMetadataBytes,cancelled:cancelled)
            _ = try NativeMigrationJSON.parse(catalog)
            schema=try JSONDecoder().decode(NativeMigrationSchema.self,from:catalog)
            guard schema.formatVersion==1,NativeMigrationCodec.validHash(schema.schemaSHA256),!schema.models.isEmpty,Set(schema.models.map(\.name)).count==schema.models.count else {throw NativeMigrationFailure("schema.invalid","検査用catalogの形式が不正です。")}
            for model in schema.models {
                guard !model.primaryKey.isEmpty,Set(model.fields.map(\.name)).count==model.fields.count,Set(model.primaryKey).isSubset(of:Set(model.fields.map(\.name))),model.primaryKey.allSatisfy({name in model.fields.contains(where:{$0.name==name && !$0.optional})}) else {throw NativeMigrationFailure("schema.invalid","catalogの主キー・scalar項目が不正です。")}
                models[model.name]=model
            }
            files=try NativeMigrationFiles(root:bundleURL)
            let rawManifest=try files.data("manifest.json",maximum:options.maximumMetadataBytes,cancelled:cancelled)
            let envelope=try object(NativeMigrationJSON.parse(rawManifest),allowed:["formatVersion","schemaSHA256","source","models","assets","jobs","secrets"])
            _ = try object(envelope["source"] ?? .null,allowed:["kind","snapshotID","consistent","completed","databaseNamespaceSHA256"])
            guard let descriptions=envelope["models"]?.array else {throw NativeMigrationFailure("manifest.invalid","モデル一覧が不正です。")}
            for description in descriptions {_ = try object(description,allowed:["name","path","rows","bytes","sha256"])}
            for name in ["assets","jobs","secrets"] {_ = try object(envelope[name] ?? .null,allowed:["path","rows","bytes","sha256"])}
            let manifest=try JSONDecoder().decode(NativeMigrationManifest.self,from:rawManifest);source=manifest.source
            guard manifest.formatVersion==1 else {throw NativeMigrationFailure("manifest.version","未対応のbundle版です。")}
            guard manifest.schemaSHA256==schema.schemaSHA256 else {throw NativeMigrationFailure("manifest.schema","元schemaと現行catalogの識別子が一致しません。")}
            guard ["web-postgresql","native-sqlite","legacy-accounts"].contains(source.kind),!source.snapshotID.isEmpty,source.snapshotID.utf8.count<=256,source.consistent,source.completed else {throw NativeMigrationFailure("manifest.snapshot","一貫した完了済みsnapshotの宣言がありません。")}
            if let ns=source.databaseNamespaceSHA256,!NativeMigrationCodec.validHash(ns) {throw NativeMigrationFailure("manifest.namespace","元namespace識別子が不正です。")}
            if source.kind != "web-postgresql" {add("incomplete","scope.auxiliary","旧native版の補助table・ジョブ・保存形式は、この92モデル検査だけでは復元できません。")}
            var seen=Set<String>(),paths=Set<Data>();paths.insert(Data("manifest.json".utf8))
            for entry in manifest.models {
                guard seen.insert(entry.name).inserted,models[entry.name] != nil else {throw NativeMigrationFailure("manifest.models","モデル名が重複しているか未知のモデルが含まれています。")}
                try descriptor(entry.file,paths:&paths)
            }
            for entry in [manifest.assets,manifest.jobs,manifest.secrets] {try descriptor(entry,paths:&paths)}
            for model in schema.models where !seen.contains(model.name) {add("error","manifest.missing_model","モデルのexportがありません。",model:model.name)}
            index=try NativeMigrationIndex()
            for entry in manifest.models {
                if cancelled(){throw CancellationError()}
                guard let model=models[entry.name] else {continue}
                do {
                    _ = try files.lines(entry.file,limit:options.maximumLineBytes,cancelled:cancelled) {data,row in
                        do {try autoreleasepool {try self.index.batch {try self.record(data,model:model,row:row)}}}
                        catch is CancellationError {throw CancellationError()}
                        catch {self.failure(error,model:model.name,row:row)}
                        self.result.checkedRows+=1
                    }
                    result.checkedModels+=1
                } catch is CancellationError {throw CancellationError()} catch {failure(error,model:model.name)}
            }
            try index.locations("SELECT model,row,field FROM refs WHERE NOT EXISTS(SELECT 1 FROM keys WHERE keys.space=refs.space AND keys.value=refs.value)",cancelled:cancelled) {model,row,field in self.add("error","relation.missing","参照先のレコードがありません。",model:model,row:row,field:field)}
            try inventory(manifest.assets,kind:"assets"){try self.asset($0,row:$1)}
            try inventory(manifest.secrets,kind:"secrets"){try self.secret($0,row:$1)}
            try inventory(manifest.jobs,kind:"jobs"){try self.job($0,row:$1)}
            try index.locations("SELECT model,row,field FROM needs WHERE declared=0",cancelled:cancelled) {model,row,field in self.add("error","inventory.missing","添付または秘密情報の参照inventoryがありません。",model:model,row:row,field:field)}
            try index.locations("SELECT model,row,field FROM needs WHERE declared>1",cancelled:cancelled) {model,row,field in self.add("error","inventory.duplicate_owner","同じ項目に複数のinventoryが宣言されています。",model:model,row:row,field:field)}
            let finalManifest=try files.data("manifest.json",maximum:options.maximumMetadataBytes,cancelled:cancelled)
            guard finalManifest==rawManifest else {throw NativeMigrationFailure("manifest.changed","検査中にmanifestが変更されました。")}
            result.status=result.errorCount>0 ? "invalid":result.incompleteCount>0 ? "incomplete":"validated"
        } catch is CancellationError {result.status="cancelled";add("warning","inspection.cancelled","検査を中止しました。元データは変更していません。")}
        catch {failure(error);result.status="invalid"}
        return result
    }
    private func add(_ severity:String,_ code:String,_ message:String,model:String?=nil,row:Int64?=nil,field:String?=nil) {
        result.diagnosticCount+=1
        if severity=="error" {result.errorCount+=1} else if severity=="incomplete" {result.incompleteCount+=1} else {result.warningCount+=1}
        if result.diagnostics.count<options.maximumDiagnostics {result.diagnostics.append(.init(severity:severity,code:code,message:message,model:model,row:row,field:field))}
    }
    private func failure(_ error:Error,model:String?=nil,row:Int64?=nil,field:String?=nil) {
        let e=(error as? NativeMigrationFailure) ?? NativeMigrationFailure("format.invalid","bundleの構造・型・読み取り結果を確認してください。")
        add("error",e.code,e.message,model:model,row:row,field:field)
    }
    private func object(_ value:NativeMigrationJSON,allowed:Set<String>?=nil) throws -> [String:NativeMigrationJSON] {
        guard let object=value.object,allowed.map({Set(object.keys).isSubset(of:$0)}) ?? true else {throw NativeMigrationFailure("format.object","レコードの形式または項目名が不正です。")};return object
    }
    private func descriptor(_ entry:NativeMigrationManifest.File,paths:inout Set<Data>) throws {
        _ = try NativeMigrationFiles.path(entry.path)
        guard entry.rows>=0,entry.bytes>=0,NativeMigrationCodec.validHash(entry.sha256),paths.insert(Data(entry.path.utf8)).inserted else {throw NativeMigrationFailure("manifest.file","ファイルの件数・サイズ・hash・重複パスが不正です。")}
    }
    private func owner(_ model:String,_ key:Data,_ field:String)->Data {NativeMigrationCodec.tuple([Data(model.utf8),key,Data(field.utf8)])}
    private func record(_ data:Data,model:NativeMigrationSchema.Model,row:Int64) throws {
        let values=try object(NativeMigrationJSON.parse(data))
        guard Set(values.keys)==Set(model.fields.map(\.name)) else {throw NativeMigrationFailure("record.fields","scalar項目の欠落または未知の項目があります。")}
        var cells:[String:Data]=[:];var valid=true
        for field in model.fields {
            do {if let value=try NativeMigrationCodec.cell(values[field.name]!,field:field,enums:schema.enums){cells[field.name]=value}}
            catch {failure(error,model:model.name,row:row,field:field.name);valid=false}
        }
        guard valid else {return}
        let pk=NativeMigrationCodec.tuple(model.primaryKey.map{cells[$0]!})
        var unique=[model.primaryKey]
        for field in model.fields where field.attributes.contains("@unique") {unique.append([field.name])}
        for d in model.directives where d.hasPrefix("@@unique") {if let names=NativeMigrationCodec.fields(in:d){unique.append(names)}}
        var used=Set<String>()
        for fields in unique {
            let space=NativeMigrationCodec.namespace(model.name,fields);guard used.insert(space).inserted else {continue}
            let parts=fields.compactMap{cells[$0]};if parts.count != fields.count {continue}
            if try !index.key(space,NativeMigrationCodec.tuple(parts)) {add("error","key.duplicate","主キーまたは一意制約が重複しています。",model:model.name,row:row,field:fields.joined(separator:","))}
        }
        for relation in model.relations {
            guard let names=NativeMigrationCodec.groups(#"fields:\s*\[([^\]]+)\].*?references:\s*\[([^\]]+)\]"#,relation.attributes) else {continue}
            let fields=NativeMigrationCodec.names(names[0]),target=NativeMigrationCodec.names(names[1]),parts=fields.compactMap{cells[$0]}
            if parts.count==fields.count {try index.ref(NativeMigrationCodec.namespace(relation.type,target),NativeMigrationCodec.tuple(parts),model:model.name,row:row,field:fields.joined(separator:","))}
        }
        for field in model.fields {
            guard let text=values[field.name]?.string else {continue}
            let key=owner(model.name,pk,field.name);try index.cell(owner:key,digest:NativeMigrationCodec.hash(Data(text.utf8)),shape:Self.secretShape(text))
            if !text.isEmpty && Self.assetFields[model.name]?.contains(field.name)==true {try index.need("asset",owner:key,model:model.name,row:row,field:field.name)}
            if !text.isEmpty && Self.secretFields[model.name]?.contains(field.name)==true {try index.need("secret",owner:key,model:model.name,row:row,field:field.name)}
        }
        if model.name=="ImageUpload" {add("incomplete","asset.image_key","ImageUploadの元object keyには専用exporterの対応が必要です。",model:model.name,row:row)}
    }
    private static func secretShape(_ text:String)->String {
        for prefix in ["native-ai-keychain:","native-plugin-keychain:","native-keychain:","keychain:v1:"] where text.hasPrefix(prefix) {
            return UUID(uuidString:String(text.dropFirst(prefix.count))) != nil ? "native":"invalid-native"
        }
        if let bytes=Data(base64Encoded:text),bytes.count>=28,bytes.base64EncodedString()==text {return "aes"}
        return "other"
    }
    private static let encryptedFields:[String:Set<String>]=["ApiKeys":["encryptedKey"],"EmailAccount":["passwordEncrypted"],"CalendarConnection":["accessTokenEncrypted","refreshTokenEncrypted"],"InstalledPlugin":["secrets"]]
    private static let assetFields:[String:Set<String>]=["Documents":["key","document_file_url","thumbnail_url"],"Invoices":["pdfStorageKey"],"Invoice_Attachments":["storageKey"],"Users":["avatar","image"]]
    private static let secretFields:[String:Set<String>]=["Users":["password"],"ApiKeys":["encryptedKey"],"EmailAccount":["passwordEncrypted"],"CalendarConnection":["accessTokenEncrypted","refreshTokenEncrypted"],"InstalledPlugin":["secrets"],"systemServices":["servicePassword"],"Session":["token"],"Account":["accessToken","refreshToken","idToken","password"],"Verification":["value"],"ApiToken":["tokenHash"],"crm_campaign_sends":["unsubscribe_token"]]
    private func inventory(_ file:NativeMigrationManifest.File,kind:String,handle:(NativeMigrationJSON,Int64)throws->Void) throws {
        do {_ = try files.lines(file,limit:options.maximumLineBytes,cancelled:cancelled) {data,row in
            do {try autoreleasepool {try handle(NativeMigrationJSON.parse(data),row)}}
            catch is CancellationError {throw CancellationError()}
            catch {failure(error,model:nil,row:row)}
        }} catch is CancellationError {throw CancellationError()} catch {failure(error)}
    }
    private func text(_ object:[String:NativeMigrationJSON],_ field:String,limit:Int=1024) throws -> String {
        guard let value=object[field]?.string,!value.isEmpty,value.utf8.count<=limit,!value.utf8.contains(0) else {throw NativeMigrationFailure("inventory.field","inventoryの必須項目が不正です。")};return value
    }
    private func reference(_ value:NativeMigrationJSON,withField:Bool) throws -> (model:NativeMigrationSchema.Model,key:Data,field:String?) {
        let object=try self.object(value,allowed:withField ? ["model","key","field"]:["model","key"])
        guard let name=object["model"]?.string,let model=models[name],let values=object["key"]?.object else {throw NativeMigrationFailure("reference.model","参照先モデル・主キーの形式が不正です。")}
        let pk=try NativeMigrationCodec.key(values,model:model,enums:schema.enums)
        guard try index.one("SELECT 1 FROM keys WHERE space=? AND value=?",[.text(NativeMigrationCodec.namespace(model.name,model.primaryKey)),.blob(pk)]) != nil else {throw NativeMigrationFailure("reference.missing","inventoryの参照先レコードがありません。")}
        let field:String?
        if withField {let name=try text(object,"field");guard model.fields.contains(where:{$0.name==name}) else {throw NativeMigrationFailure("reference.field","参照先のscalar項目がありません。")};field=name} else {field=nil}
        return(model,pk,field)
    }
    private func asset(_ value:NativeMigrationJSON,row:Int64) throws {
        let object=try self.object(value,allowed:["id","path","bytes","sha256","owners","storageKey","externalURL","unresolved"])
        let id=try text(object,"id",limit:256)
        guard try index.id("asset",id) else {throw NativeMigrationFailure("asset.duplicate","添付inventoryのIDが重複しています。")}
        guard let owners=object["owners"]?.array,!owners.isEmpty else {throw NativeMigrationFailure("asset.metadata","添付のサイズ・hash・参照元が不正です。")}
        if let unresolved=object["unresolved"] {
            let detail=try self.object(unresolved,allowed:["reason"])
            guard ["missing-object","external-url","unknown-storage"].contains(detail["reason"]?.string ?? ""),object["path"]==nil,object["externalURL"]==nil,object["bytes"]==nil,object["sha256"]==nil else {throw NativeMigrationFailure("asset.unresolved","未解決添付の宣言が不正です。")}
            add("incomplete","asset.unresolved","元objectの取得・確認が未完了です。",row:row)
        } else {
        guard let bytes=object["bytes"]?.integer,bytes>=0,let hash=object["sha256"]?.string,NativeMigrationCodec.validHash(hash) else {throw NativeMigrationFailure("asset.metadata","添付のサイズ・hashが不正です。")}
        guard (object["path"] != nil) != (object["externalURL"] != nil) else {throw NativeMigrationFailure("asset.location","添付の保存先を一つ指定してください。")}
        if let external=object["externalURL"] {
            guard let url=external.string,let parts=URLComponents(string:url),["http","https"].contains(parts.scheme ?? ""),parts.host?.isEmpty==false,parts.user==nil,parts.password==nil,!url.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else {throw NativeMigrationFailure("asset.url","外部添付のURL形式が不正です。")}
            add("incomplete","asset.external","外部添付のbytesは含まれていません。取得や内容の検証は行っていません。",row:row)
        } else {
            let path=try text(object,"path")
            let actual=try files.read(path,cancelled:cancelled){_ in}
            guard actual.bytes==bytes,actual.sha256==hash else {throw NativeMigrationFailure("asset.digest","添付のサイズ・SHA256が宣言と一致しません。")}
        }
        }
        for value in owners {
            let ref=try reference(value,withField:true),ownerKey=owner(ref.model.name,ref.key,ref.field!)
            guard Self.assetFields[ref.model.name]?.contains(ref.field!)==true else {throw NativeMigrationFailure("asset.owner_field","添付の参照元は対応する保存キー項目である必要があります。")}
            guard let digest=try index.one("SELECT digest FROM cells WHERE owner=?",[.blob(ownerKey)]) else {throw NativeMigrationFailure("asset.owner","添付の参照元は文字列項目である必要があります。")}
            guard let text=object["storageKey"]?.string,digest==NativeMigrationCodec.hash(Data(text.utf8)) else {throw NativeMigrationFailure("asset.key","添付の論理キーと参照元の値が一致しません。") }
            try index.declare("asset",owner:ownerKey)
        }
        result.checkedAssets+=1
    }
    private func secret(_ value:NativeMigrationJSON,row:Int64) throws {
        let object=try self.object(value,allowed:["id","purpose","storage","valueSHA256","owner","namespaceSHA256"])
        let id=try text(object,"id",limit:256),purpose=try text(object,"purpose",limit:256),storage=try text(object,"storage",limit:64)
        guard try index.id("secret",id) else {throw NativeMigrationFailure("secret.duplicate","秘密情報inventoryのIDが重複しています。")}
        guard ["server-aes256gcm","native-keychain","environment","password-hash","opaque-auth"].contains(storage) else {throw NativeMigrationFailure("secret.storage","秘密情報の保存形式が不明です。")}
        let namespace=object["namespaceSHA256"]?.string
        if object["namespaceSHA256"] != nil && (namespace == nil || !NativeMigrationCodec.validHash(namespace!)) {throw NativeMigrationFailure("secret.namespace","秘密情報のnamespace識別子が不正です。")}
        if let value=object["owner"] {
            let ref=try reference(value,withField:true),ownerKey=owner(ref.model.name,ref.key,ref.field!)
            guard storage != "environment",Self.secretFields[ref.model.name]?.contains(ref.field!)==true else {throw NativeMigrationFailure("secret.owner_field","秘密情報の参照元・保存形式の組合せを確認してください。")}
            guard let expected=object["valueSHA256"]?.string,NativeMigrationCodec.validHash(expected),try index.one("SELECT digest FROM cells WHERE owner=?",[.blob(ownerKey)])==expected else {throw NativeMigrationFailure("secret.digest","秘密情報参照と元scalar値の識別子が一致しません。")}
            let shape=try index.one("SELECT shape FROM cells WHERE owner=?",[.blob(ownerKey)])
            if Self.encryptedFields[ref.model.name]?.contains(ref.field!)==true && !["server-aes256gcm","native-keychain"].contains(storage) {throw NativeMigrationFailure("secret.scheme","暗号化項目の保存形式宣言が一致しません。")}
            if storage=="server-aes256gcm" && shape != "aes" {throw NativeMigrationFailure("secret.envelope","暗号文envelopeの長さ・Base64形式が不正です。復号は別検証です。")}
            if storage=="native-keychain" && shape != "native" {throw NativeMigrationFailure("secret.pointer","native Keychain参照の形式が不正です。")}
            try index.declare("secret",owner:ownerKey)
        } else if storage != "environment" {throw NativeMigrationFailure("secret.owner","保存された秘密情報に参照元がありません。")}
        if storage=="native-keychain" {
            guard let namespace else {throw NativeMigrationFailure("secret.namespace","Keychain参照に元namespaceがありません。")}
            if let original=source.databaseNamespaceSHA256,namespace != original {add("incomplete","secret.namespace_mismatch","元DBとは異なるnamespaceの秘密情報参照です。別パスの移送確認が必要です。",row:row)}
            add("incomplete","secret.rebind","Keychain参照の別パス復元・rotation後の旧鍵保持は別途確認が必要です。",row:row)
        }
        switch probe(.init(id:id,purpose:purpose,storage:storage,namespaceSHA256:namespace)) {
        case .missing:add("incomplete","secret.missing","参照する秘密情報がありません。旧鍵の回復または再入力が必要です。",row:row)
        case .unknown:add("incomplete","secret.unverified","秘密情報の可用性・復号・移送は未検証です。",row:row)
        case .present: add("warning","secret.presence_only","可用性の申告のみを確認しました。復号・移送・認証継続を保証しません。",row:row)
        }
        result.checkedSecrets+=1
    }
    private func job(_ value:NativeMigrationJSON,row:Int64) throws {
        let object=try self.object(value,allowed:["id","event","state","deliveryStarted","hasReceipt","policy","references"])
        let id=try text(object,"id",limit:256);_ = try text(object,"event",limit:256)
        let state=try text(object,"state",limit:32),policy=try text(object,"policy",limit:32)
        guard try index.id("job",id) else {throw NativeMigrationFailure("job.duplicate","job inventoryのIDが重複しています。")}
        guard ["pending","retry","running","done","failed","cancelled","needs_review"].contains(state),["manual-review","rebuild","none"].contains(policy),let started=object["deliveryStarted"]?.bool,let receipt=object["hasReceipt"]?.bool,let references=object["references"]?.array else {throw NativeMigrationFailure("job.metadata","job状態・再開方針・参照の形式が不正です。")}
        guard state != "done" || policy=="none",!(["running","needs_review"].contains(state) || started || receipt) || policy != "rebuild" else {throw NativeMigrationFailure("job.unsafe_replay","完了済み・結果不明の外部処理を再実行可能として宣言できません。")}
        for ref in references {_ = try reference(ref,withField:false)}
        add("incomplete","job.recovery","元サービスの処理結果と再開方針を照合してください。検査は再送を許可しません。",row:row)
        result.checkedJobs+=1
    }
}
