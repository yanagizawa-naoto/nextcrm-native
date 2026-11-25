import Foundation

struct NativeDataMaintenanceRecoveryIdentity:Codable,Equatable {
    let device:UInt64,inode:UInt64
}
enum NativeDataMaintenanceRecoveryRole:String,Codable {case temporary,publication}
enum NativeDataMaintenanceRecoveryState:String,Codable {case planned,attached,publishing,published,cleaning,removed}
struct NativeDataMaintenanceRecoveryEntry:Codable,Equatable {
    let role:NativeDataMaintenanceRecoveryRole,parentPath:String,name:String,parent:NativeDataMaintenanceRecoveryIdentity,nonce:String
    var identity:NativeDataMaintenanceRecoveryIdentity?
    var destinationName:String?
    var state:NativeDataMaintenanceRecoveryState = .planned
}
struct NativeDataMaintenanceRecoveryJournal:Codable,Equatable {
    var version=1
    let purpose:String,registry:String,id:String,uid:UInt32,lock:NativeDataMaintenanceRecoveryIdentity
    var sequence=0
    var entries:[NativeDataMaintenanceRecoveryEntry]=[]
}
struct NativeDataMaintenanceRecoveryOwner:Codable,Equatable {let version:Int,purpose:String,id:String,uid:UInt32}
struct NativeDataMaintenanceRecoveryMarker:Codable,Equatable {let version:Int,registry:String,operation:String,role:NativeDataMaintenanceRecoveryRole,nonce:String,uid:UInt32}
struct NativeDataMaintenanceRecoveryItem:Codable {
    enum Status:String,Codable {case recovered,live,pending,failed}
    let operation:String,status:Status,code:String,message:String
    let removedDirectories:Int
    init(operation:String,status:Status,code:String,message:String,removedDirectories:Int=0){self.operation=operation;self.status=status;self.code=code;self.message=message;self.removedDirectories=removedDirectories}
}
struct NativeDataMaintenanceRecoveryPage:Codable {
    let items:[NativeDataMaintenanceRecoveryItem]
    let nextCursor:String?
    let hasMore:Bool
}
struct NativeDataMaintenanceRecoveryFailure:Error {
    let code:String,message:String
    static var changed:Self{.init(code:"recovery.changed",message:"作業用フォルダや回収記録が変更されています。自動回収せず保留しました。")}
    static var unsafe:Self{.init(code:"recovery.unsafe",message:"回収記録の形式・所有者・パスを確認できません。自動回収せず保留しました。")}
    static var io:Self{.init(code:"recovery.io",message:"作業用フォルダの回収を完了できません。記録を保持して再確認します。")}
}
