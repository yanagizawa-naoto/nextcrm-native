import Foundation
import SQLite3
import Darwin
final class CalendlyStore:CalendlySecretStore {
 var data:[String:Data]=[:],removed:[String]=[],loads=0,saves=0,fail=false
 func load(id:String,interactive:Bool)throws->Data?{loads+=1;return data[id]}
 func save(id:String,data:Data)throws{saves+=1;self.data[id]=data}
 func remove(id:String)throws{removed.append(id);if fail{throw NativeDBError.conflict};data[id]=nil}
}
private final class RelayStore:CampaignRelayCredentialStore {
 var value:CampaignRelayCredentials? = .init(publicURL:"https://relay.example.invalid",appName:"合成",clientID:UUID().uuidString.lowercased(),instanceID:UUID().uuidString.lowercased(),authKey:"synthetic"),removed=0
 func load(interactive:Bool)throws->CampaignRelayCredentials?{value}
 func save(_ value:CampaignRelayCredentials)throws{self.value=value}
 func remove()throws{removed+=1;value=nil}
}
@main enum NativeCredentialRemovalTests {
 static var checks=0
 static let removalKey="calendly.credential.cleanup.removal.v1"
 static func check(_ c:@autoclosure()throws->Bool,_ s:String)throws{guard try c() else{throw NativeDBError.message("FAIL: "+s)};checks+=1}
 static func reject(_ s:String,_ f:()throws->Void)throws{var rejected=false;do{try f()}catch{rejected=true};try check(rejected,s)}
 static func sql(_ db:NativeDatabase,_ statement:String)throws{var connection:OpaquePointer?;guard sqlite3_open(db.url.path,&connection)==SQLITE_OK else{throw NativeDBError.conflict};defer{sqlite3_close(connection)};guard sqlite3_exec(connection,statement,nil,nil,nil)==SQLITE_OK else{throw NativeDBError.message("synthetic SQL setup failure")}}
 final class Fixture {
  let db:NativeDatabase,service:CRMService,store=CalendlyStore(),id=UUID().uuidString.lowercased()
  init(_ native:URL,_ root:URL,_ name:String)throws{
   db=try NativeDatabase(url:root.appendingPathComponent(name+"/crm.sqlite"),schemaURL:native.appendingPathComponent("schema.json"),sqlURL:native.appendingPathComponent("schema.sql"))
   let user=try db.insert("Users",values:["name":.text("合成管理者"),"email":.text(name+"@example.invalid"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:"system")
   service=CRMService(db:db,identity:.init(id:user["id"].string,role:"admin",partnerAccountID:nil))
   var state=CalendlyControlState();let before=state;state.credentialID=id;try state.save(db,expected:before)
   store.data[id]=try JSONEncoder().encode(CalendlyCredentials(publicURL:"https://relay.example.invalid",clientID:UUID().uuidString.lowercased(),instanceID:UUID().uuidString.lowercased(),authKey:"synthetic",apiToken:"synthetic-token",signingKey:"synthetic-signing"))
   try db.setMetadata("calendlyRelay.binding.v1",value:"synthetic-binding-preserved")
  }
 }
 static func main()async{do{try await run()}catch{fputs("Credential removal: \(error)\n",stderr);exit(1)}}
 static func run()async throws{
  umask(0o077);let native=URL(fileURLWithPath:CommandLine.arguments[1]),root=URL(fileURLWithPath:CommandLine.arguments[2])
  let outer=try Fixture(native,root,"outer"),outerRaw=try outer.db.metadata(CalendlyControlState.metadataKey)
  try reject("outer rollback"){try outer.db.transaction{try outer.service.removeCalendlySettings(store:outer.store);throw NativeDBError.conflict}}
  try check(try outer.db.metadata(CalendlyControlState.metadataKey)==outerRaw,"outer rollback retains original DB control")
  #if BASELINE
  try check(outer.store.data[outer.id]==nil&&outer.store.removed==[outer.id],"baseline outer rollback lost key")
  #else
  try check(outer.store.data[outer.id] != nil&&outer.store.removed.isEmpty,"candidate outer boundary preserves key")
  try check(try outer.db.metadata(removalKey)==nil,"outer rejection leaves no deferred intent")
  #endif
  let committed=try Fixture(native,root,"commit-failure"),old=try committed.service.calendlyControl()
  // SQLite genuinely rejects final COMMIT, not just a throwing Swift mock.
  try sql(committed.db,"CREATE TABLE test_parent(id INTEGER PRIMARY KEY); CREATE TABLE test_child(pid INTEGER REFERENCES test_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER test_commit AFTER UPDATE OF value ON native_metadata WHEN NEW.key='calendly.control.v1' AND json_extract(NEW.value,'$.credentialID') IS NULL BEGIN INSERT INTO test_child(pid) VALUES(1); END;")
  try reject("actual deferred FK commit failure"){try committed.service.removeCalendlySettings(store:committed.store)}
  try check(try committed.service.calendlyControl()==old,"failed final COMMIT restores control row")
  try check(committed.store.data[committed.id]==nil,"physical remove succeeded before final failure")
  #if BASELINE
  try check(try committed.db.metadata(removalKey)==nil,"baseline loses key with no committed deletion receipt")
  #else
  try check(try committed.db.metadata(removalKey)?.contains(committed.id)==true,"committed intent survives final COMMIT failure")
  let loads=committed.store.loads;try reject("pending deleted key cannot be reused"){_ = try committed.service.calendlyCredentials(old,store:committed.store)}
  try check(committed.store.loads==loads,"pending intent blocks before credential load")
  try reject("new token cannot race pending deletion"){try committed.service.replaceCalendlyAPIToken("synthetic-new",store:committed.store)}
  try check(committed.store.saves==0,"pending intent prevents replacement save")
  var requests=0,rejected=false
  do{try await committed.service.saveCalendlySettings(publicURL:"https://relay.example.invalid",authKey:String(repeating:"A",count:43),apiToken:"synthetic",signingKey:"synthetic",store:committed.store,request:{_ in requests+=1;throw NativeDBError.conflict})}catch{rejected=true}
  try check(rejected&&requests==0&&committed.store.saves==0,"pending async settings blocks before external callback")
  try sql(committed.db,"DROP TRIGGER test_commit")
  try committed.service.removeCalendlySettings(store:committed.store)
  try check(try committed.service.calendlyControl().credentialID==nil&&committed.db.metadata(removalKey)=="","missing-key retry finalizes control and intent")
  #endif
  let unavailable=try Fixture(native,root,"store-failure");unavailable.store.fail=true
  try reject("fake store removal failure"){try unavailable.service.removeCalendlySettings(store:unavailable.store)}
  try check(try unavailable.service.calendlyControl().credentialID==unavailable.id&&unavailable.store.data[unavailable.id] != nil,"failure keeps retryable ID and key")
  unavailable.store.fail=false;try unavailable.service.removeCalendlySettings(store:unavailable.store)
  try check(try unavailable.service.calendlyControl().credentialID==nil&&unavailable.store.data.isEmpty,"explicit successful retry")
  try check(try unavailable.db.metadata("calendlyRelay.binding.v1")=="synthetic-binding-preserved","permanent binding untouched")
  let sealedFixture=try Fixture(native,root,"readonly-source"),sealed=root.appendingPathComponent("sealed.sqlite");var src:OpaquePointer?,dst:OpaquePointer?
  guard sqlite3_open_v2(sealedFixture.db.url.path,&src,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,sqlite3_open(sealed.path,&dst)==SQLITE_OK,let copy=sqlite3_backup_init(dst,"main",src,"main") else{throw NativeDBError.conflict};let copied=sqlite3_backup_step(copy,-1);sqlite3_backup_finish(copy);sqlite3_close(src);sqlite3_close(dst);try check(copied==SQLITE_DONE,"actual sealed backup")
  let readonly=try NativeDatabase(readOnlyURL:sealed,schemaURL:native.appendingPathComponent("schema.json")),service=CRMService(db:readonly,identity:sealedFixture.service.identity),bytes=try Data(contentsOf:sealed),relay=RelayStore()
  try reject("readonly Calendly removal"){try service.removeCalendlySettings(store:sealedFixture.store)}
  var relayError=false;do{try service.removeCampaignRelaySettings(store:relay)}catch{relayError=true}
  #if BASELINE
  try check(sealedFixture.store.data[sealedFixture.id]==nil,"baseline readonly Calendly loses key")
  try check(!relayError&&relay.removed==1&&relay.value==nil,"baseline readonly relay mutates store successfully")
  #else
  try check(sealedFixture.store.removed.isEmpty&&sealedFixture.store.data[sealedFixture.id] != nil,"readonly Calendly refuses before store")
  try check(relayError&&relay.removed==0&&relay.value != nil,"readonly relay refuses before store")
  #endif
  try check(try Data(contentsOf:sealed)==bytes,"sealed DB exact bytes unchanged")
  for ext in ["-wal","-shm","-journal"]{try check(!FileManager.default.fileExists(atPath:sealed.path+ext),"no readonly sidecars")}
  let ordinary=RelayStore();try sealedFixture.service.removeCampaignRelaySettings(store:ordinary);try check(ordinary.removed==1&&ordinary.value==nil,"normal relay explicit remove unchanged")
  let revoked=try Fixture(native,root,"revoked"),revokedRelay=RelayStore(),actor=try revoked.db.get("Users",key:["id":.text(revoked.service.identity.id)])!
  _ = try revoked.db.update(actor,changes:["userStatus":.text("INACTIVE")],actor:"system")
  try reject("revoked Calendly admin"){try revoked.service.removeCalendlySettings(store:revoked.store)}
  try reject("revoked relay admin"){try revoked.service.removeCampaignRelaySettings(store:revokedRelay)}
  try check(revoked.store.removed.isEmpty&&revokedRelay.removed==0,"revoked actions have no secret effects")
  #if !BASELINE
  let firstCommit=try Fixture(native,root,"intent-commit-failure")
  try sql(firstCommit.db,"CREATE TABLE test_parent(id INTEGER PRIMARY KEY); CREATE TABLE test_child(pid INTEGER REFERENCES test_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER test_intent AFTER INSERT ON native_metadata WHEN NEW.key='calendly.credential.cleanup.removal.v1' BEGIN INSERT INTO test_child(pid) VALUES(1); END;")
  try reject("intent COMMIT failure"){try firstCommit.service.removeCalendlySettings(store:firstCommit.store)}
  try check(firstCommit.store.removed.isEmpty&&firstCommit.store.data[firstCommit.id] != nil,"no store delete until intent truly committed")
  try check(try firstCommit.db.metadata(removalKey)==nil,"failed intent transaction leaves no false pending")
  let lost=try Fixture(native,root,"revoke-after-intent")
  try sql(lost.db,"CREATE TRIGGER test_revoke AFTER INSERT ON native_metadata WHEN NEW.key='calendly.credential.cleanup.removal.v1' BEGIN UPDATE Users SET userStatus='INACTIVE' WHERE id='"+lost.service.identity.id+"'; END;")
  try reject("authority revoked at committed intent"){try lost.service.removeCalendlySettings(store:lost.store)}
  try check(lost.store.removed.isEmpty&&lost.store.data[lost.id] != nil,"post-intent fresh authority protects key")
  try check(try lost.db.metadata(removalKey) != nil,"revoked intent remains reviewable")
  let stale=try Fixture(native,root,"stale-intent");stale.store.fail=true;try reject("create pending CAS fixture"){try stale.service.removeCalendlySettings(store:stale.store)};stale.store.fail=false
  let count=stale.store.removed.count,before=try stale.service.calendlyControl();var changed=before;try changed.save(stale.db,expected:before)
  try reject("old ID revived with new revision"){try stale.service.removeCalendlySettings(store:stale.store)}
  try check(stale.store.removed.count==count&&stale.store.data[stale.id] != nil,"stale intent cannot erase changed control")
  let shared=try Fixture(native,root,"shared")
  for key in ["calendly_api_token","calendly_signing_key"]{_ = try shared.db.insert("crm_SystemSettings",values:["key":.text(key),"value":.text("native-calendly-keychain:"+shared.id)],actor:"system")}
  try shared.service.removeCalendlySettings(store:shared.store)
  try check(try shared.service.calendlyControl().credentialID==nil&&shared.store.data[shared.id] != nil&&shared.store.removed.isEmpty,"detach keeps M07 shared immutable key")
  try check(try shared.db.get("crm_SystemSettings",key:["key":.text("calendly_api_token")])?["value"] == .text("native-calendly-keychain:"+shared.id),"migration source reference unchanged")
  try check(try shared.db.metadata(removalKey)=="","shared detach completes without cleanup debt")
  let registered=try Fixture(native,root,"registered"),prior=try registered.service.calendlyControl();var registration=prior;registration.registration = .init(uri:"https://api.calendly.com/webhook_subscriptions/synthetic",organization:"synthetic",callbackURL:"https://relay.example.invalid",credentialID:registered.id);try registration.save(registered.db,expected:prior)
  try reject("active webhook blocks removal"){try registered.service.removeCalendlySettings(store:registered.store)}
  try check(registered.store.removed.isEmpty&&registered.store.data[registered.id] != nil,"webhook reference retained")
  #endif
  #if BASELINE
  let mode="baseline"
  #else
  let mode="candidate"
  #endif
  print(String(decoding:try JSONSerialization.data(withJSONObject:["checks":checks,"mode":mode,"realKeychain":false,"network":false,"normalData":false],options:.sortedKeys),as:UTF8.self))
 }
}
