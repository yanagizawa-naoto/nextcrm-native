import Foundation
import Darwin

final class NativeMigrationImport {
    private let options:NativeMigrationOptions;private let cancelled:()->Bool
    /// Optional cut point hook is for isolated fault tests; production leaves it nil.
    private let checkpoint:((String)throws->Void)?
    init(options:NativeMigrationOptions = .init(),cancelled:@escaping ()->Bool = {Task.isCancelled},checkpoint:((String)throws->Void)? = nil){self.options=options;self.cancelled=cancelled;self.checkpoint=checkpoint}
    func prepare(bundleURL:URL,schemaURL:URL,sqlURL:URL,destinationURL:URL)->NativeMigrationImportResult {
        var result=NativeMigrationImportResult();var workspace:NativeMigrationImportWorkspace?;var db:NativeMigrationImportDatabase?;var descriptor:Int32 = -1
        defer{db=nil;if descriptor>=0{close(descriptor)};workspace=nil}
        func check(_ point:String)throws {if cancelled(){throw CancellationError()};try checkpoint?(point);if cancelled(){throw CancellationError()}}
        do {
            let source=try NativeMigrationFiles(root:bundleURL)
            let rawManifest=try source.data("manifest.json",maximum:options.maximumMetadataBytes,cancelled:cancelled)
            let manifest=try JSONDecoder().decode(NativeMigrationManifest.self,from:rawManifest)
            let rawSchema=try NativeMigrationFiles(root:schemaURL.deletingLastPathComponent()).data(schemaURL.lastPathComponent,maximum:options.maximumMetadataBytes,cancelled:cancelled)
            let schema=try JSONDecoder().decode(NativeMigrationSchema.self,from:rawSchema)
            let rawSQL=try NativeMigrationFiles(root:sqlURL.deletingLastPathComponent()).data(sqlURL.lastPathComponent,maximum:options.maximumMetadataBytes,cancelled:cancelled)
            guard let sql=String(data:rawSQL,encoding:.utf8) else {throw NativeMigrationFailure("candidate.schema","trusted DDLの文字コードが不正です。")}
            result.schemaSHA256=schema.schemaSHA256;result.sqlSHA256=NativeMigrationCodec.hash(rawSQL)
            let preflight=NativeMigrationPreflight(options:options,cancelled:cancelled).inspect(bundleURL:bundleURL,schemaURL:schemaURL);result.preflight=preflight
            guard preflight.status=="validated" || preflight.status=="incomplete" else {result.status=preflight.status=="cancelled" ? .cancelled:.rejected;return result}
            guard try source.data("manifest.json",maximum:options.maximumMetadataBytes,cancelled:cancelled)==rawManifest else {throw NativeMigrationFailure("candidate.source_changed","事前検査後にmanifestが変更されました。")}
            guard try NativeMigrationFiles(root:schemaURL.deletingLastPathComponent()).data(schemaURL.lastPathComponent,maximum:options.maximumMetadataBytes,cancelled:cancelled)==rawSchema,try NativeMigrationFiles(root:sqlURL.deletingLastPathComponent()).data(sqlURL.lastPathComponent,maximum:options.maximumMetadataBytes,cancelled:cancelled)==rawSQL else {throw NativeMigrationFailure("candidate.schema_changed","事前検査中にtrusted schemaが変更されました。")}
            try check("afterPreflight")
            workspace=try NativeMigrationImportWorkspace(destination:destinationURL,bundle:bundleURL)
            let out=workspace!;try out.makeAssets();try out.put(Data("NextCRM offline migration candidate; NOT ACTIVATED\n".utf8),path:".native-migration-candidate")
            try check("afterDirectory")
            descriptor=try out.create("candidate.sqlite");db=try NativeMigrationImportDatabase(descriptor:descriptor,sql:sql)
            try check("afterSchema")
            let modelMap=Dictionary(uniqueKeysWithValues:schema.models.map{($0.name,$0)})
            for entry in manifest.models {
                guard let model=modelMap[entry.name] else {throw NativeMigrationFailure("candidate.model","モデルがtrusted catalogにありません。")}
                let count=try source.lines(entry.file,limit:options.maximumLineBytes,cancelled:cancelled){raw,row in
                    try autoreleasepool {
                        try check("beforeRow")
                        guard let values=try NativeMigrationJSON.parse(raw).object,Set(values.keys)==Set(model.fields.map(\.name)) else {throw NativeMigrationFailure("candidate.fields","事前検査後にscalar項目が変更されました。")}
                        let bound=try model.fields.map{try NativeMigrationImportCodec.value(values[$0.name]!,field:$0,enums:schema.enums,normalized:&result.normalizedUUIDValues)}
                        try db!.row(model:model,values:bound);result.importedRows+=1
                        try check("afterRow")
                    }
                }
                guard try db!.one("SELECT COUNT(*) FROM "+NativeMigrationImportDatabase.quote(model.name)) == .integer(count) else {throw NativeMigrationFailure("candidate.count","候補DBの行数が一致しません。")}
                result.modelProofs.append(.init(model:model.name,rows:count,readBackRows:count,sourceSHA256:entry.sha256))
            }
            try check("afterModels")
            _ = try source.lines(manifest.assets,limit:options.maximumLineBytes,cancelled:cancelled){raw,row in
                try autoreleasepool {
                    try check("beforeAsset")
                    guard let item=try NativeMigrationJSON.parse(raw).object,let id=item["id"]?.string else {throw NativeMigrationFailure("candidate.asset","添付inventoryが変更されています。")}
                    if item["unresolved"] != nil {
                        guard item["path"]==nil,item["sha256"]==nil,item["bytes"]==nil else {throw NativeMigrationFailure("candidate.asset","未解決添付の宣言が変更されています。")}
                        try db!.asset(id:id,hash:"",path:nil,raw:raw)
                        if !result.pending.contains(.externalAssets){result.pending.append(.externalAssets)}
                        return
                    }
                    guard let hash=item["sha256"]?.string,NativeMigrationCodec.validHash(hash),let bytes=item["bytes"]?.integer,bytes>=0 else {throw NativeMigrationFailure("candidate.asset","添付inventoryが変更されています。")}
                    var local:String?
                    if let path=item["path"]?.string {
                        local="assets/"+hash+".blob"
                        if try db!.one("SELECT local_path FROM _migration_assets WHERE sha256=? AND local_path IS NOT NULL LIMIT 1",[.text(Data(hash.utf8))]) == nil {
                            try out.copy(path,from:source,to:local!,expectedBytes:bytes,expectedHash:hash,cancelled:cancelled,progress:{try check("assetChunk")});result.copiedAssetBytes+=bytes
                        } else {
                            let actual=try source.read(path,cancelled:cancelled){_ in};guard actual.bytes==bytes,actual.sha256==hash else {throw NativeMigrationFailure("candidate.asset","共有添付の内容が一致しません。")}
                        }
                        result.copiedAssets+=1
                    } else {if !result.pending.contains(.externalAssets){result.pending.append(.externalAssets)}}
                    try db!.asset(id:id,hash:hash,path:local,raw:raw);try check("afterAsset")
                }
            }
            for (name,file) in [("assets.ndjson",manifest.assets),("jobs.ndjson",manifest.jobs),("secrets.ndjson",manifest.secrets)] {
                try out.copy(file.path,from:source,to:name,expectedBytes:file.bytes,expectedHash:file.sha256,cancelled:cancelled)
            }
            if manifest.secrets.rows>0 {result.pending.append(.credentials)}
            if manifest.jobs.rows>0 {result.pending.append(.jobRecovery)}
            if manifest.source.kind != "web-postgresql" {result.pending.append(.nativeAuxiliaryTables)}
            if manifest.assets.rows>0 {result.pending.append(.assetReaderIntegration)}
            if (manifest.models.first(where:{$0.name=="ImageUpload"})?.rows ?? 0)>0 {result.pending.append(.imageObjectInventory)}
            try check("beforeCommit");try db!.finish();db=nil
            try out.put(rawManifest,path:"bundle-manifest.json")
            guard try source.data("manifest.json",maximum:options.maximumMetadataBytes,cancelled:cancelled)==rawManifest else {throw NativeMigrationFailure("candidate.source_changed","検査中にmanifestが変更されました。")}
            guard try NativeMigrationFiles(root:schemaURL.deletingLastPathComponent()).data(schemaURL.lastPathComponent,maximum:options.maximumMetadataBytes,cancelled:cancelled)==rawSchema,try NativeMigrationFiles(root:sqlURL.deletingLastPathComponent()).data(sqlURL.lastPathComponent,maximum:options.maximumMetadataBytes,cancelled:cancelled)==rawSQL else {throw NativeMigrationFailure("candidate.schema_changed","検査中にtrusted schemaが変更されました。")}
            try check("beforePublish")
            result.status=preflight.status=="incomplete" || result.pending.count>2 ? .preparedWithGaps:.prepared
            result.candidateCreated=true
            try out.put(JSONEncoder().encode(result),path:"candidate.json");try check("afterResult")
            try out.publish()
        } catch is CancellationError {result.status = .cancelled;result.candidateCreated=false;result.diagnostics.append(.init(severity:"warning",code:"candidate.cancelled",message:"候補作成を中止しました。作成途中の候補を回収します。",model:nil,row:nil,field:nil))}
        catch {
            result.status = .failed;result.candidateCreated=false
            let error=(error as? NativeMigrationFailure) ?? NativeMigrationFailure("candidate.failed","候補の作成に失敗しました。元データは変更していません。")
            result.diagnostics.append(.init(severity:"error",code:error.code,message:error.message,model:nil,row:nil,field:nil))
        }
        return result
    }
}
