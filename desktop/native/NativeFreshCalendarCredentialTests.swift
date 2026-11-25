import Foundation
import CryptoKit
import SQLite3
import Darwin
private final class GoogleFake:GoogleCalendarSecretStore {
 var data:[String:Data]=[:],saved:[String]=[],removed:[String]=[],failRemove=false,afterSave:((String)throws->Void)?
 func load(id:String,interactive:Bool)throws->Data?{data[id]}
 func save(id:String,data:Data)throws{saved.append(id);self.data[id]=data;try afterSave?(id)}
 func remove(id:String)throws{removed.append(id);if failRemove{throw NativeDBError.conflict};data[id]=nil}
}
private final class CalendlyFake:CalendlySecretStore {
 var data:[String:Data]=[:],saved:[String]=[],removed:[String]=[],failRemove=false,afterSave:((String)throws->Void)?
 func load(id:String,interactive:Bool)throws->Data?{data[id]}
 func save(id:String,data:Data)throws{saved.append(id);self.data[id]=data;try afterSave?(id)}
 func remove(id:String)throws{removed.append(id);if failRemove{throw NativeDBError.conflict};data[id]=nil}
}
@main enum NativeFreshCalendarCredentialTests {
 static var checks=0
 static func check(_ c:@autoclosure()throws->Bool,_ s:String)throws{guard try c() else{throw NativeDBError.message("FAIL: "+s)};checks+=1}
 static func reject(_ s:String,_ f:()throws->Void)throws{var failed=false;do{try f()}catch{failed=true};try check(failed,s)}
 static func rejectAsync(_ s:String,_ f:()async throws->Void)async throws{var failed=false;do{try await f()}catch{failed=true};try check(failed,s)}
 static func main()async{do{try await run()}catch{fputs("Calendar fresh: \(error)\n",stderr);exit(1)}}
 static func run()async throws {
  umask(0o077);let native=URL(fileURLWithPath:CommandLine.arguments[1]),root=URL(fileURLWithPath:CommandLine.arguments[2]),db=try NativeDatabase(url:root.appendingPathComponent("source/crm.sqlite"),schemaURL:native.appendingPathComponent("schema.json"),sqlURL:native.appendingPathComponent("schema.sql"))
  let user=try db.insert("Users",values:["name":.text("合成管理者"),"email":.text("synthetic@example.invalid"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:"system"),identity=CRMIdentity(id:user["id"].string,role:"admin",partnerAccountID:nil),service=CRMService(db:db,identity:identity),gs=GoogleFake(),cs=CalendlyFake()
  // Google client save: after external save, another setting revision wins.
  let other=GoogleCalendarClientReference(id:UUID().uuidString.lowercased(),clientID:"other.apps.googleusercontent.com")
  gs.failRemove=true;gs.afterSave={_ in try db.setMetadata(GoogleCalendarStorage.clientKey,value:String(decoding:JSONEncoder().encode(other),as:UTF8.self))}
  try reject("google client CAS failure"){try service.saveGoogleCalendarClient(clientID:"synthetic.apps.googleusercontent.com",clientSecret:"synthetic",store:gs)}
  gs.afterSave=nil;let failedClient=gs.saved.last!
  try check(try NativeFreshCredentialPublication.receipts(db:db,purpose:.google)[failedClient]?.state=="failed","Google client failed receipt")
  try check(gs.data[failedClient] != nil,"Google failed remove retains fake key")
  gs.failRemove=false;try check(try service.cleanupFailedGoogleCredentials(store:gs).removed==1&&gs.data[failedClient]==nil,"Google client explicit retry")
  try service.saveGoogleCalendarClient(clientID:"synthetic.apps.googleusercontent.com",clientSecret:"synthetic",store:gs)
  try check(try NativeFreshCredentialPublication.receipts(db:db,purpose:.google).isEmpty,"Google success consumes receipt")
  let ticket=try service.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:gs),grant=GoogleCalendarGrant(accountEmail:"synthetic@example.invalid",accessToken:"synthetic-access",refreshToken:"synthetic-refresh",expiresAt:nil,grantedScopes:GoogleCalendarScope.read)
  gs.failRemove=true;gs.afterSave={_ in try db.setMetadata(GoogleCalendarStorage.pendingKey(identity.id),value:UUID().uuidString.lowercased())}
  try reject("Google authorization ticket replaced"){_ = try service.completeGoogleCalendarAuthorization(ticket,grant:grant,store:gs)}
  gs.afterSave=nil;let failedGrant=gs.saved.last!
  try check(try NativeFreshCredentialPublication.receipts(db:db,purpose:.google)[failedGrant]?.state=="failed","Google grant failed receipt")
  gs.failRemove=false;try check(try service.cleanupFailedGoogleCredentials(store:gs).removed==1&&gs.data[failedGrant]==nil,"Google grant retry")
  try check(try service.googleCalendarConnections().total==0,"Google failed grant not published")
  let successful=try service.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:gs),connection=try service.completeGoogleCalendarAuthorization(successful,grant:grant,store:gs)
  try check(try service.googleCalendarGrant(connection,store:gs).grant==grant,"Google successful credential still readable")
  // Calendly real service with authenticated synthetic relay responses, no socket.
  let instance=UUID().uuidString.lowercased(),key=Data(repeating:7,count:32),auth=key.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"");var requests=0
  let request:CalendlyRelayClient.Request={r in
   requests+=1;let cid=try CalendlyRelayBinding.clientID(db:db),body=try JSONSerialization.data(withJSONObject:["version":1,"instanceId":instance,"clientId":cid,"head":0],options:.sortedKeys),nonce=r.value(forHTTPHeaderField:"X-NextCRM-Nonce")!
   var signed=Data(("nextcrm-calendar-v1-response\n"+nonce+"\n200\n").utf8);signed.append(body)
   let sig=Data(HMAC<SHA256>.authenticationCode(for:signed,using:SymmetricKey(data:key))).base64EncodedString()
   return(body,HTTPURLResponse(url:r.url!,statusCode:200,httpVersion:nil,headerFields:["X-NextCRM-Signature":sig])!)
  }
  cs.failRemove=true;cs.afterSave={_ in let old=try CalendlyControlState.load(db);var changed=old;try changed.save(db,expected:old)}
  try await rejectAsync("Calendly save CAS failure"){try await service.saveCalendlySettings(publicURL:"https://relay.example.invalid",authKey:auth,apiToken:"synthetic-token",signingKey:"synthetic-signing",store:cs,request:request)}
  cs.afterSave=nil;let failedCalendly=cs.saved.last!
  try check(try NativeFreshCredentialPublication.receipts(db:db,purpose:.calendly)[failedCalendly]?.state=="failed","Calendly save failed receipt")
  cs.failRemove=false;try check(try service.cleanupFailedCalendlyCredentials(store:cs).removed==1&&cs.data[failedCalendly]==nil,"Calendly fresh failure retry")
  try await service.saveCalendlySettings(publicURL:"https://relay.example.invalid",authKey:auth,apiToken:"synthetic-token",signingKey:"synthetic-signing",store:cs,request:request)
  let oldControl=try service.calendlyControl(),oldID=oldControl.credentialID!
  cs.failRemove=true;cs.afterSave={_ in let old=try CalendlyControlState.load(db);var changed=old;try changed.save(db,expected:old)}
  try reject("Calendly renew CAS failure"){try service.replaceCalendlyAPIToken("new-synthetic-token",store:cs)}
  cs.afterSave=nil;let failedRenew=cs.saved.last!
  try check(try NativeFreshCredentialPublication.receipts(db:db,purpose:.calendly)[failedRenew]?.state=="failed","Calendly renewal failed receipt")
  cs.failRemove=false;try check(try service.cleanupFailedCalendlyCredentials(store:cs).removed==1&&cs.data[failedRenew]==nil,"Calendly renewal retry")
  try check(try service.calendlyControl().credentialID==oldID&&cs.data[oldID] != nil,"Calendly old published key retained after failure")
  try check(requests==4,"only synthetic health/bind calls")
  // Current actor revocation stops failed cleanup without losing its receipt.
  let failed=UUID().uuidString.lowercased(),receipt=NativeFreshCredentialPublication.Receipt(version:1,namespace:NativeFreshCredentialPublication.namespace(db),ownerID:identity.id,state:"failed")
  try db.setMetadata(NativeFreshCredentialPublication.key(.google),value:String(decoding:JSONEncoder().encode([failed:receipt]),as:UTF8.self));gs.data[failed]=Data([1])
  let currentUser=try db.get("Users",key:["id":.text(identity.id)])!,revoked=try db.update(currentUser,changes:["userStatus":.text("INACTIVE")],actor:"system")
  let removals=gs.removed.count;try reject("revoked cleanup"){_ = try service.cleanupFailedGoogleCredentials(store:gs)}
  try check(gs.removed.count==removals&&gs.data[failed] != nil,"revoked cleanup no store removal")
  _ = try db.update(revoked,changes:["userStatus":.text("ACTIVE")],actor:"system");try check(try service.cleanupFailedGoogleCredentials(store:gs).removed==1,"reauthorized cleanup resumes")
  // Cancellation after an external save never publishes and keeps a retryable
  // failed receipt if the store's deletion is temporarily unavailable.
  var cancelledID="",cancelledKeys=Set<String>(),published=0
  let cancelledTask=Task { () throws -> Void in
   let _:Int = try NativeFreshCredentialPublication.perform(db:db,purpose:.google,ownerID:identity.id,authorize:service.authenticated,referenced:{_ in false},save:{id in cancelledID=id;cancelledKeys.insert(id);withUnsafeCurrentTask{$0?.cancel()}},remove:{_ in throw NativeDBError.conflict},publish:{_ in published+=1;return 1})
  }
  try await rejectAsync("cancel after save"){try await cancelledTask.value}
  try check(published==0&&cancelledKeys.count==1,"cancel does not publish or lose retry material")
  try check(try NativeFreshCredentialPublication.receipts(db:db,purpose:.google)[cancelledID]?.state=="failed","cancelled uncommitted key has failed receipt")
  // A later new operation cleans definitely failed IDs, never waiting or live IDs.
  var cleanupIDs=[String]()
  let value:Int=try NativeFreshCredentialPublication.perform(db:db,purpose:.google,ownerID:identity.id,authorize:service.authenticated,referenced:{_ in false},save:{_ in},remove:{cleanupIDs.append($0);cancelledKeys.remove($0)},publish:{_ in 7})
  try check(value==7&&cleanupIDs==[cancelledID]&&cancelledKeys.isEmpty,"next save retries only definitely failed prior key")
  try check(try NativeFreshCredentialPublication.receipts(db:db,purpose:.google).isEmpty,"next successful save consumes own reservation")
  // Readonly original op consumes no new secret; async Calendly blocks network too.
  let sealed=root.appendingPathComponent("sealed.sqlite");var src:OpaquePointer?,dst:OpaquePointer?
  guard sqlite3_open_v2(db.url.path,&src,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,sqlite3_open(sealed.path,&dst)==SQLITE_OK,let copy=sqlite3_backup_init(dst,"main",src,"main") else{throw NativeDBError.conflict};let status=sqlite3_backup_step(copy,-1);sqlite3_backup_finish(copy);sqlite3_close(src);sqlite3_close(dst);try check(status==SQLITE_DONE,"sealed SQLite")
  let ro=try NativeDatabase(readOnlyURL:sealed,schemaURL:native.appendingPathComponent("schema.json")),rs=CRMService(db:ro,identity:identity),gsCount=gs.saved.count,csCount=cs.saved.count,requestCount=requests,before=try Data(contentsOf:sealed)
  try reject("readonly Google save"){try rs.saveGoogleCalendarClient(clientID:"synthetic.apps.googleusercontent.com",clientSecret:"synthetic",store:gs)}
  try reject("readonly Calendly renewal"){try rs.replaceCalendlyAPIToken("new-synthetic",store:cs)}
  try await rejectAsync("readonly Calendly save"){try await rs.saveCalendlySettings(publicURL:"https://relay.example.invalid",authKey:auth,apiToken:"synthetic-token",signingKey:"synthetic-signing",store:cs,request:request)}
  try check(gs.saved.count==gsCount&&cs.saved.count==csCount&&requests==requestCount,"readonly blocks saves and external request callback")
  try check(try Data(contentsOf:sealed)==before,"readonly bytes unchanged")
  print(String(decoding:try JSONSerialization.data(withJSONObject:["checks":checks,"syntheticRelayRequests":requests,"realKeychain":false,"network":false],options:.sortedKeys),as:UTF8.self))
 }
}
