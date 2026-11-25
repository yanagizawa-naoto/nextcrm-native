import Foundation

/// Non-secret immutable-artifact inventory; this grants no credential or worker authority.
struct NativeCredentialArchiveBinding:Codable,Equatable {
    struct File:Codable,Equatable {let path:String,bytes:Int64,sha256:String}
    static let prefix="migration.credentials.archive.v1.",folder="native-credential-archives"
    let version:Int,id:String,namespace:String,schemaSHA256:String,snapshotID:String,importManifestSHA256:String,handoffID:String,entries:Int64,holdsRows:Int64
    let files:[File]
    var key:String{Self.prefix+id}
    func validated()throws->Self {
        guard version==1,UUID(uuidString:id)?.uuidString.lowercased()==id,UUID(uuidString:handoffID) != nil,
              [namespace,schemaSHA256,importManifestSHA256].allSatisfy(NativeMigrationCodec.validHash),!snapshotID.isEmpty,snapshotID.utf8.count<=1024,
              entries>=0,holdsRows>=entries,files.count==2,Set(files.map(\.path))==Set([Self.folder+"/"+id+".handoff",Self.folder+"/"+id+".holds"]),
              files.allSatisfy({$0.bytes>=0&&NativeMigrationCodec.validHash($0.sha256)}),files.first(where:{$0.path.hasSuffix(".handoff")})!.bytes>12 else{throw NativeMigrationFailure("credential.archive_binding","暗号化引継ぎの保全情報が不正です。")}
        return self
    }
    static func decode(_ raw:String,key:String)throws->Self {
        guard raw.utf8.count<=65536,let shape=try NativeMigrationJSON.parse(Data(raw.utf8)).object,Set(shape.keys)==Set(["version","id","namespace","schemaSHA256","snapshotID","importManifestSHA256","handoffID","entries","holdsRows","files"]) else{throw NativeMigrationFailure("credential.archive_binding","暗号化引継ぎの保全情報が不正です。")}
        let value=try JSONDecoder().decode(Self.self,from:Data(raw.utf8)).validated();guard value.key==key else{throw NativeMigrationFiles.badPath};return value
    }
}
