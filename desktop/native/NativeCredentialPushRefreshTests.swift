import Foundation
import SQLite3
import Darwin
final class PushRefreshStore:GoogleCalendarSecretStore {
 var values:[String:Data]=[:],saved:[String]=[],removed:[String]=[],failRemove=false,afterSave:((String)throws->Void)?
 func load(id:String,interactive:Bool)throws->Data?{values[id]}
 func save(id:String,data:Data)throws{saved.append(id);values[id]=data;try afterSave?(id)}
 func remove(id:String)throws{removed.append(id);if failRemove{throw NativeDBError.conflict};values[id]=nil}
}
@main enum NativeCredentialPushRefreshTests {
 static var checks=0
 static func check(_ value:@autoclosure()throws->Bool,_ label:String)throws{guard try value() else{throw NativeDBError.message("FAIL: "+label)};checks+=1}
 final class Fixture {
  let db:NativeDatabase,service:CRMService,store=PushRefreshStore(),now=Date(timeIntervalSince1970:1_800_000_000);var id="",job="",activity=""
  init(_ native:URL,_ root:URL,_ name:String)throws{
   db=try NativeDatabase(url:root.appendingPathComponent(name+"/crm.sqlite"),schemaURL:native.appendingPathComponent("schema.json"),sqlURL:native.appendingPathComponent("schema.sql"))
   let row=try db.insert("Users",values:["name":.text("合成管理者"),"email":.text(name+"@example.invalid"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:"system");service=CRMService(db:db,identity:.init(id:row["id"].string,role:"admin",partnerAccountID:nil))
   try service.saveGoogleCalendarClient(clientID:"synthetic.apps.googleusercontent.com",clientSecret:"synthetic-client",store:store)
   let ticket=try service.beginGoogleCalendarAuthorization(expected:nil,requested:.readwrite,store:store),grant=GoogleCalendarGrant(accountEmail:"synthetic@example.invalid",accessToken:"synthetic-access",refreshToken:"synthetic-refresh",expiresAt:now.addingTimeInterval(-60),grantedScopes:GoogleCalendarScope.readwrite.requested)
   id=try service.completeGoogleCalendarAuthorization(ticket,grant:grant,store:store)["id"].string
   activity=try db.insert("crm_Activities",values:["type":.text("meeting"),"title":.text("合成予定"),"date":.text(try NativeCalendarEvents.stamp(now.addingTimeInterval(86400))),"status":.text("scheduled"),"createdBy":.text(service.identity.id),"duration":.integer(30)],actor:service.identity.id)["id"].string
   job=try db.enqueue(GoogleCalendarOutbound.event,payload:["activity_id":activity,"operation":"upsert"],now:now)
  }
  func current()throws->NativeRecord{try db.get("CalendarConnection",key:["id":.text(id)])!}
  func sql(_ statement:String)throws{var connection:OpaquePointer?;guard sqlite3_open(db.url.path,&connection)==SQLITE_OK else{throw NativeDBError.conflict};defer{sqlite3_close(connection)};guard sqlite3_exec(connection,statement,nil,nil,nil)==SQLITE_OK else{throw NativeDBError.message("synthetic SQL failure")}}
  func response(_ request:URLRequest)throws->(Data,HTTPURLResponse){
   let object:[String:Any],status:Int
   if request.url!.host=="oauth2.googleapis.com"{object=["access_token":"synthetic-new-access","refresh_token":"synthetic-new-refresh","expires_in":3600,"token_type":"Bearer"];status=200}
   else if request.httpMethod=="GET"{object=["error":[:]];status=404}
   else{var result=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any];result["etag"]="synthetic-etag";result["iCalUID"]="synthetic@example.invalid";result["organizer"]=["self":true];object=result;status=200}
   return(try JSONSerialization.data(withJSONObject:object),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
  }
 }
 static func main()async{do{try await run()}catch{fputs("Push refresh receipt: \(error)\n",stderr);exit(1)}}
 static func run()async throws{
  umask(0o077);let native=URL(fileURLWithPath:CommandLine.arguments[1]),root=URL(fileURLWithPath:CommandLine.arguments[2])
  for mode in ["cas","commit","lease","cancel","revoked","activity"] {
   let f=try Fixture(native,root,mode),old=try f.current()["refreshTokenEncrypted"],count=f.store.saved.count;var requests=0
   f.store.failRemove=mode != "revoked"
   if mode=="commit"{try f.sql("CREATE TABLE test_parent(id INTEGER PRIMARY KEY); CREATE TABLE test_child(pid INTEGER REFERENCES test_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER test_refresh AFTER UPDATE OF refreshTokenEncrypted ON CalendarConnection WHEN NEW.refreshTokenEncrypted<>OLD.refreshTokenEncrypted BEGIN INSERT INTO test_child(pid) VALUES(1); END;")}
   f.store.afterSave={_ in
    if mode=="cas"{_ = try f.db.update(f.current(),changes:["lastSyncError":.text("synthetic competing writer")],actor:"system")}
    if mode=="activity"{let activity=try f.db.get("crm_Activities",key:["id":.text(f.activity)])!;_ = try f.db.update(activity,changes:["title":.text("合成競合変更")],actor:"system")}
    if mode=="lease"{try f.db.finishJob(f.db.job(id:f.job)!,result:["synthetic":"other worker"],now:f.now)}
    if mode=="cancel"{withUnsafeCurrentTask{$0?.cancel()}}
    if mode=="revoked"{let user=try f.db.get("Users",key:["id":.text(f.service.identity.id)])!;_ = try f.db.update(user,changes:["userStatus":.text("INACTIVE")],actor:"system")}
   }
   let worker=GoogleCalendarPushWorker(db:f.db,store:f.store,request:{r in requests+=1;return try f.response(r)},clock:{f.now})
   let task=Task{try await worker.runNext()};let ran=try await task.value;try check(ran,"worker claimed refresh job")
   f.store.afterSave=nil;let fresh=f.store.saved.last!
   try check(f.store.saved.count==count+1&&requests==1,"one refresh save and no event request after fence failure")
   try check(try f.current()["refreshTokenEncrypted"]==old&&f.store.values[String(old.string.dropFirst(GoogleCalendarStorage.prefix.count))] != nil,"failed refresh retains original published key")
   let receipts=try NativeFreshCredentialPublication.receipts(db:f.db,purpose:.google)
   #if BASELINE
   try check(receipts[fresh]==nil,"baseline refresh failure has no durable receipt")
   if mode=="revoked"{try check(f.store.values[fresh]==nil,"baseline cleanup ignores revoked current actor")}else{try check(f.store.values[fresh] != nil,"baseline failed removal leaks unreferenced key")}
   #else
   try check(receipts[fresh] != nil,"candidate refresh failure remains recorded")
   try check(f.store.values[fresh] != nil,"failed cleanup or revoked authority retains recoverable key")
   if mode != "revoked"{
    f.store.failRemove=false;let cleanup=try f.service.cleanupFailedGoogleCredentials(store:f.store)
    try check(cleanup.removed==1&&f.store.values[fresh]==nil,"actual failed refresh receipt explicitly retried")
   }else{try check(f.store.removed.isEmpty,"revoked current actor performs no key removal")}
   #endif
   if mode=="lease"{try check(try f.db.job(id:f.job)?.result["synthetic"]=="other worker","expired worker cannot overwrite another terminal result")}
  }
  // Expiry, GET 401, and mutation 401 still refresh and commit exactly one push.
  for trigger in ["expired","GET","POST"] {
   let success=try Fixture(native,root,"success-"+trigger);var calls=0,refreshes=0,posts=0,rejected=false
   if trigger != "expired" {
    let item=GoogleCalendarStorage.itemID(try success.current()["refreshTokenEncrypted"])!,old=try success.service.googleCalendarGrant(success.current(),store:success.store)
    let grant=GoogleCalendarGrant(accountEmail:old.grant.accountEmail,accessToken:old.grant.accessToken,refreshToken:old.grant.refreshToken,expiresAt:success.now.addingTimeInterval(3600),grantedScopes:old.grant.grantedScopes)
    success.store.values[item]=try JSONEncoder().encode(GoogleCalendarStoredGrant(connectionID:old.connectionID,userID:old.userID,client:old.client,grant:grant))
   }
   let worker=GoogleCalendarPushWorker(db:success.db,store:success.store,request:{r in
    calls+=1
    if r.url?.host=="oauth2.googleapis.com"{refreshes+=1}
    if trigger != "expired",r.httpMethod==trigger,!rejected{rejected=true;return(Data("{\"error\":{}}".utf8),HTTPURLResponse(url:r.url!,statusCode:401,httpVersion:nil,headerFields:nil)!)}
    if r.httpMethod=="POST",r.url?.host != "oauth2.googleapis.com"{posts+=1};return try success.response(r)
   },clock:{success.now})
   let ran=try await worker.runNext();try check(ran,"successful outbound worker")
   try check(try success.db.job(id:success.job)?.status=="done"&&refreshes==1&&posts==1,"normal refresh then exactly one provider mutation "+trigger)
   try check(try success.db.calendarOutboundMapping(activityID:success.activity) != nil,"remote confirmation publishes mapping")
   try check(try success.service.googleCalendarGrant(success.current(),store:success.store).grant.accessToken=="synthetic-new-access"&&success.store.values.count==2,"new grant readable and old key retired per existing policy")
   try check(try NativeFreshCredentialPublication.receipts(db:success.db,purpose:.google).isEmpty,"successful refresh leaves no receipt")
   try check(try !String(describing:success.db.job(id:success.job)!).contains("synthetic-new-access"),"job excludes credential bytes")
  }
  // Lost lease immediately after HTTP response is caught by existing heartbeat.
  let early=try Fixture(native,root,"heartbeat"),initial=early.store.saved.count
  let earlyWorker=GoogleCalendarPushWorker(db:early.db,store:early.store,request:{r in try early.db.finishJob(early.db.job(id:early.job)!,result:["synthetic":"finished before save"],now:early.now);return try early.response(r)},clock:{early.now})
  let earlyRan=try await earlyWorker.runNext();try check(earlyRan,"heartbeat fence worker")
  try check(early.store.saved.count==initial,"post-response heartbeat prevents credential save")
  let other=try Fixture(native,root,"other-actor"),otherUser=try other.db.insert("Users",values:["name":.text("別利用者"),"email":.text("other@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:"system")
  _ = try other.db.update(other.current(),changes:["userId":otherUser["id"]],actor:"system");var otherCalls=0
  let otherWorker=GoogleCalendarPushWorker(db:other.db,store:other.store,request:{r in otherCalls+=1;return try other.response(r)},clock:{other.now})
  let otherRan=try await otherWorker.runNext();try check(otherRan,"changed owner job checked")
  try check(otherCalls==0&&other.store.saved.count==2,"another owner cannot refresh or access provider")
  #if BASELINE
  let mode="baseline"
  #else
  let mode="candidate"
  #endif
  print(String(decoding:try JSONSerialization.data(withJSONObject:["checks":checks,"mode":mode,"normalData":false,"network":false,"realKeychain":false],options:.sortedKeys),as:UTF8.self))
 }
}
