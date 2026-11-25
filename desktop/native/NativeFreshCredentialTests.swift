import Foundation
import SQLite3
import Darwin
private final class MailFake:NativeMailSecretStore {
 var data:[String:Data]=[:],saved:[String]=[],removed:[String]=[],failRemove=false,afterSave:((String)throws->Void)?
 func load(id:String,interactive:Bool)throws->Data?{data[id]}
 func save(id:String,data:Data)throws{saved.append(id);self.data[id]=data;try afterSave?(id)}
 func remove(id:String)throws{removed.append(id);if failRemove{throw NativeDBError.message("synthetic store failure")};data[id]=nil}
}
@main enum NativeFreshCredentialTests {
 static var checks=0
 static func check(_ c:@autoclosure()throws->Bool,_ s:String)throws{guard try c() else{throw NativeDBError.message("FAIL: "+s)};checks+=1}
 static func reject(_ s:String,_ f:()throws->Void)throws{var failure=false;do{try f()}catch{failure=true};try check(failure,s)}
 static func main(){do{try run()}catch{fputs("Fresh credential: \(error)\n",stderr);exit(1)}}
 static func run()throws{
  umask(0o077);let native=URL(fileURLWithPath:CommandLine.arguments[1]),root=URL(fileURLWithPath:CommandLine.arguments[2]),db=try NativeDatabase(url:root.appendingPathComponent("source/crm.sqlite"),schemaURL:native.appendingPathComponent("schema.json"),sqlURL:native.appendingPathComponent("schema.sql"))
  let user=try db.insert("Users",values:["name":.text("合成管理者"),"email":.text("synthetic@example.invalid"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:"system"),identity=CRMIdentity(id:user["id"].string,role:"admin",partnerAccountID:nil),service=CRMService(db:db,identity:identity)
  let settings=NativeMailAccountSettings(label:"合成メール",username:"synthetic@example.invalid",imap:.init(host:"imap.example.invalid",port:993,tls:.implicitTLS),smtp:.init(host:"smtp.example.invalid",port:465,tls:.implicitTLS)),store=MailFake()
  func failPublication(){db.beforeRecordWrite={model,_,_,input,_ in if model=="EmailAccount"{throw NativeDBError.conflict};return input}}
  store.failRemove=true;failPublication()
  try reject("failed create publication"){_ = try service.createMailAccount(settings,password:"synthetic-pass",store:store)}
  db.beforeRecordWrite=nil;try check(store.saved.count==1&&store.data.count==1,"fake key persisted and removal failed")
  try check(try service.mailAccounts().total==0,"failed publication leaves no account")
  let first=store.saved[0]
  try check(try NativeFreshCredentialPublication.receipts(db:db,purpose:.email)[first]?.state=="failed","candidate durable failed receipt")
  store.failRemove=false;let retry=try service.cleanupFailedMailCredentials(store:store)
  try check(retry.removed==1&&store.data.isEmpty,"actual mail consumer retries failed fresh key")
  try check(try NativeFreshCredentialPublication.receipts(db:db,purpose:.email).isEmpty,"successful cleanup consumes receipt")
  store.failRemove=false;let account=try service.createMailAccount(settings,password:"published-pass",store:store),current=try CRMService.mailCredentialID(account)
  try check(store.data[current] != nil,"successful create retains published secret")
  try check(try NativeFreshCredentialPublication.receipts(db:db,purpose:.email).isEmpty,"publication atomically removes waiting receipt")
  for operation in 0..<2 {
   store.failRemove=true;failPublication();let count=store.saved.count
   try reject("failed update/replace publication"){if operation==0{_ = try service.updateMailAccount(account,settings:settings,password:"failed-new-password",store:store)}else{_ = try service.replaceMailPassword(account,password:"failed-new-password",store:store)}}
   db.beforeRecordWrite=nil;try check(store.saved.count==count+1,"fresh attempt saved one UUID")
   let failed=store.saved.last!;try check(try NativeFreshCredentialPublication.receipts(db:db,purpose:.email)[failed]?.state=="failed","update/replace failure retained")
   store.failRemove=false;try check(try service.cleanupFailedMailCredentials(store:store).removed==1,"update/replace cleanup retry")
   try check(try CRMService.mailCredentialID(service.mailAccount(account["id"].string))==current&&store.data[current] != nil,"failed update retains old live key")
  }
  let legacy=UUID().uuidString.lowercased();store.data[legacy]=Data([9]);try db.setMetadata("mail.orphanCredential."+legacy,value:"pending")
  let beforeRemoved=store.removed.count;_ = try service.cleanupFailedMailCredentials(store:store)
  try check(store.data[legacy] != nil&&store.removed.count==beforeRemoved,"legacy ambiguous pending never adopted or removed")
  // Held/active/foreign owner/foreign namespace/waiting receipts are never erased.
  let hold=UUID().uuidString.lowercased(),waiting=UUID().uuidString.lowercased(),foreign=UUID().uuidString.lowercased(),other=UUID().uuidString.lowercased(),namespace=NativeFreshCredentialPublication.namespace(db)
  let receipt=NativeFreshCredentialPublication.Receipt(version:1,namespace:namespace,ownerID:identity.id,state:"failed")
  var map=[hold:receipt,current:receipt,waiting:NativeFreshCredentialPublication.Receipt(version:1,namespace:namespace,ownerID:identity.id,state:"waiting"),foreign:NativeFreshCredentialPublication.Receipt(version:1,namespace:String(repeating:"f",count:64),ownerID:identity.id,state:"failed"),other:NativeFreshCredentialPublication.Receipt(version:1,namespace:namespace,ownerID:UUID().uuidString.lowercased(),state:"failed")]
  for id in map.keys{store.data[id]=Data([1])};try db.setMetadata(NativeUserCredentialCleanup.markerKey(.email,hold),value:"held")
  try db.setMetadata(NativeFreshCredentialPublication.key(.email),value:String(decoding:JSONEncoder().encode(map),as:UTF8.self))
  let protected=try service.cleanupFailedMailCredentials(store:store);try check(protected.removed==0&&protected.retained==5,"all protected receipt kinds retained")
  try check(map.keys.allSatisfy{store.data[$0] != nil},"protected bytes remain")
  try db.setMetadata(NativeFreshCredentialPublication.key(.email),value:"{}")
  // Reject caller's outer transaction before any external write; delayed no-op
  // boundary callbacks must not create a key after commit or rollback.
  let saves=store.saved.count
  try db.transaction{try reject("outer transaction refused"){_ = try service.createMailAccount(settings,password:"synthetic",store:store)}}
  try reject("outer rollback"){try db.transaction{try reject("nested rejected"){_ = try service.replaceMailPassword(account,password:"synthetic",store:store)};throw NativeDBError.conflict}}
  try check(store.saved.count==saves,"outer callbacks have no delayed side effects")
  // Pure generic state engine exercises all named purposes with actual DB fences.
  for purpose in [NativeFreshCredentialPublication.Purpose.google,.calendly] {
   var values=Set<String>(),removed=0,id=""
   try reject("generic publication failure") {let _:Int=try NativeFreshCredentialPublication.perform(db:db,purpose:purpose,ownerID:identity.id,authorize:service.authenticated,referenced:{_ in false},save:{id=$0;values.insert($0)},remove:{_ in throw NativeDBError.conflict},publish:{_ in throw NativeDBError.conflict})}
   try check(try NativeFreshCredentialPublication.receipts(db:db,purpose:purpose)[id]?.state=="failed","purpose failed receipt durable")
   let cleaned=try NativeFreshCredentialPublication.cleanup(db:db,purpose:purpose,ownerID:identity.id,authorize:service.authenticated,referenced:{_ in false},remove:{values.remove($0);removed+=1})
   try check(cleaned.removed==1&&removed==1&&values.isEmpty,"purpose exact failed cleanup")
  }
  // Queue is bounded before external save; malformed/restored values fail closed.
  let unresolved=NativeFreshCredentialPublication.Receipt(version:1,namespace:namespace,ownerID:identity.id,state:"waiting")
  map=Dictionary(uniqueKeysWithValues:(0..<128).map{_ in (UUID().uuidString.lowercased(),unresolved)})
  try db.setMetadata(NativeFreshCredentialPublication.key(.email),value:String(decoding:JSONEncoder().encode(map),as:UTF8.self))
  try reject("queue full before save"){_ = try service.createMailAccount(settings,password:"synthetic",store:store)}
  try check(store.saved.count==saves,"queue full causes no external save")
  try db.setMetadata(NativeFreshCredentialPublication.key(.email),value:"invalid")
  try reject("malformed queue refused"){_ = try service.cleanupFailedMailCredentials(store:store)}
  try db.setMetadata(NativeFreshCredentialPublication.key(.email),value:"{}")
  // Read-only source must not cause even a fresh secret save.
  let sealed=root.appendingPathComponent("sealed.sqlite");var src:OpaquePointer?,dst:OpaquePointer?
  guard sqlite3_open_v2(db.url.path,&src,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,sqlite3_open(sealed.path,&dst)==SQLITE_OK,let copy=sqlite3_backup_init(dst,"main",src,"main") else{throw NativeDBError.conflict}
  let result=sqlite3_backup_step(copy,-1);sqlite3_backup_finish(copy);sqlite3_close(src);sqlite3_close(dst);try check(result==SQLITE_DONE,"actual sealed DB")
  let ro=try NativeDatabase(readOnlyURL:sealed,schemaURL:native.appendingPathComponent("schema.json")),roService=CRMService(db:ro,identity:identity),rs=MailFake(),before=try Data(contentsOf:sealed)
  try reject("readonly create refuses"){_ = try roService.createMailAccount(settings,password:"readonly",store:rs)}
  try check(rs.saved.isEmpty&&rs.removed.isEmpty,"candidate readonly before store operation")
  try reject("readonly cleanup refuses"){_ = try roService.cleanupFailedMailCredentials(store:rs)}
  try check(rs.removed.isEmpty,"readonly cleanup has no effects")
  try check(try Data(contentsOf:sealed)==before,"sealed DB unchanged")
  let mode="candidate"
  print(String(decoding:try JSONSerialization.data(withJSONObject:["checks":checks,"mode":mode,"readonlySaves":rs.saved.count,"realKeychain":false,"network":false],options:.sortedKeys),as:UTF8.self))
 }
}
