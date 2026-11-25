import Foundation
import SQLite3
import Darwin
private final class PluginFake:NativePluginCredentialBacking {
 var values:[String:Data]=[:],removed:[String]=[],fail=false,loads=0,saves=0
 func load(_ reference:String)throws->Data?{loads+=1;return values[reference]}
 func save(_ reference:String,data:Data)throws{saves+=1;values[reference]=data}
 func remove(_ reference:String)throws{removed.append(reference);if fail{throw NativeDBError.conflict};values.removeValue(forKey:reference)}
}
private final class MCPFake:NativeMCPSecretStore {
 var values:[String:Data]=[:],removed:[String]=[],fail=false,loads=0,saves=0
 func load(id:String)throws->Data?{loads+=1;return values[id]}
 func save(id:String,data:Data)throws{saves+=1;values[id]=data}
 func remove(id:String)throws{removed.append(id);if fail{throw NativeDBError.conflict};values.removeValue(forKey:id)}
}
@main enum NativeCredentialLifecycleReadOnlyTests {
 static var checks=0
 static func check(_ condition:@autoclosure()throws->Bool,_ label:String)throws{guard try condition() else{throw NativeDBError.message("FAIL: "+label)};checks+=1}
 static func main(){do{try run()}catch{fputs("Lifecycle: \(error)\n",stderr);exit(1)}}
 static func run()throws{
  umask(0o077);let native=URL(fileURLWithPath:CommandLine.arguments[1]),root=URL(fileURLWithPath:CommandLine.arguments[2]),now=Date(timeIntervalSince1970:1_800_000_000)
  let db=try NativeDatabase(url:root.appendingPathComponent("source/crm.sqlite"),schemaURL:native.appendingPathComponent("schema.json"),sqlURL:native.appendingPathComponent("schema.sql"))
  let p=NativePluginCredentialVault.prefix,pdue=p+UUID().uuidString.lowercased(),pcurrent=p+UUID().uuidString.lowercased(),pfuture=p+UUID().uuidString.lowercased(),punknown=p+UUID().uuidString.lowercased()
  let mdue=UUID().uuidString.lowercased(),mcurrent=UUID().uuidString.lowercased(),mfuture=UUID().uuidString.lowercased(),munknown=UUID().uuidString.lowercased()
  func metadata(_ key:String,_ value:[String:Double])throws{try db.setMetadata(key,value:String(decoding:JSONEncoder().encode(value),as:UTF8.self))}
  let deadlines=[pdue:now.timeIntervalSince1970-1,pcurrent:now.timeIntervalSince1970-1,pfuture:now.timeIntervalSince1970+1],mdeadlines=[mdue:now.timeIntervalSince1970-1,mcurrent:now.timeIntervalSince1970-1,mfuture:now.timeIntervalSince1970+1]
  try metadata(NativePluginCredentialVault.cleanupKey,deadlines);try metadata(NativeMCPSettingsStore.cleanupKey,mdeadlines)
  _ = try db.insert("InstalledPlugin",values:["id":.text("synthetic"),"version":.text("1"),"secrets":.text(pcurrent)],actor:"system")
  var settings=NativeMCPSettings();settings.credentialID=mcurrent;try db.setMetadata(NativeMCPSettingsStore.metadataKey,value:String(decoding:JSONEncoder().encode(settings),as:UTF8.self))
  let sealed=root.appendingPathComponent("sealed.sqlite");var source:OpaquePointer?,destination:OpaquePointer?
  guard sqlite3_open_v2(db.url.path,&source,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,sqlite3_open(sealed.path,&destination)==SQLITE_OK,let copy=sqlite3_backup_init(destination,"main",source,"main") else{throw NativeDBError.conflict}
  let result=sqlite3_backup_step(copy,-1);sqlite3_backup_finish(copy);sqlite3_close(source);sqlite3_close(destination);try check(result==SQLITE_DONE,"actual SQLite sealed backup")
  let ro=try NativeDatabase(readOnlyURL:sealed,schemaURL:native.appendingPathComponent("schema.json")),before=try Data(contentsOf:sealed)
  let ps=PluginFake(),ms=MCPFake();for id in [pdue,pcurrent,pfuture,punknown]{ps.values[id]=Data([1])};for id in [mdue,mcurrent,mfuture,munknown]{ms.values[id]=Data([2])}
  // A due referenced entry may sort before due disposable; isolate to prove erase-before-write deterministically.
  // The readonly snapshot uses the full map. The plugin cleanup may fail on pruning referenced first, so use a separate sealed db with due only below.
  let sourceRaw=try db.metadata(NativePluginCredentialVault.cleanupKey)!
  try metadata(NativePluginCredentialVault.cleanupKey,[pdue:now.timeIntervalSince1970-1]);try metadata(NativeMCPSettingsStore.cleanupKey,[mdue:now.timeIntervalSince1970-1])
  let focused=root.appendingPathComponent("focused.sqlite");source=nil;destination=nil
  guard sqlite3_open_v2(db.url.path,&source,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,sqlite3_open(focused.path,&destination)==SQLITE_OK,let second=sqlite3_backup_init(destination,"main",source,"main") else{throw NativeDBError.conflict}
  let copied=sqlite3_backup_step(second,-1);sqlite3_backup_finish(second);sqlite3_close(source);sqlite3_close(destination);try check(copied==SQLITE_DONE,"focused actual backup")
  let focusedRO=try NativeDatabase(readOnlyURL:focused,schemaURL:native.appendingPathComponent("schema.json")),focusedBefore=try Data(contentsOf:focused)
  var failures=0
  do{_ = try NativePluginCredentialVault(db:focusedRO,backing:ps,clock:{now}).cleanup()}catch{failures+=1}
  do{_ = try NativeMCPSettingsStore.cleanup(db:focusedRO,secretStore:ms,now:now)}catch{failures+=1}
  try check(failures==2,"readonly both operations refuse")
  try check(ps.removed.isEmpty&&ms.removed.isEmpty,"readonly rejects before fake removal")
  try check(ps.values[pdue] != nil&&ms.values[mdue] != nil,"readonly fake secrets retained")
  try check(ps.loads==0&&ps.saves==0&&ms.loads==0&&ms.saves==0,"cleanup no load/save")
  try check(try Data(contentsOf:focused)==focusedBefore&&Data(contentsOf:sealed)==before,"sealed DB exact bytes unchanged")
  for url in [sealed,focused]{for suffix in ["-wal","-shm","-journal"]{try check(!FileManager.default.fileExists(atPath:url.path+suffix),"readonly sidecar absent")}}
  try check(try focusedRO.metadata(NativePluginCredentialVault.cleanupKey) != nil&&focusedRO.metadata(NativeMCPSettingsStore.cleanupKey) != nil,"readonly pending remains")
  try db.setMetadata(NativePluginCredentialVault.cleanupKey,value:sourceRaw);try metadata(NativeMCPSettingsStore.cleanupKey,mdeadlines)
  let pw=PluginFake(),mw=MCPFake();for id in [pdue,pcurrent,pfuture,punknown]{pw.values[id]=Data([3])};for id in [mdue,mcurrent,mfuture,munknown]{mw.values[id]=Data([4])}
  let pr=try NativePluginCredentialVault(db:db,backing:pw,clock:{now}).cleanup(),mr=try NativeMCPSettingsStore.cleanup(db:db,secretStore:mw,now:now)
  try check(pr.removed==1&&pw.removed==[pdue],"writable plugin removes only expired disposable")
  try check(mr.removed==1&&mw.removed==[mdue],"writable MCP removes only expired disposable")
  try check(pw.values[pcurrent] != nil&&mw.values[mcurrent] != nil,"current referenced keys retained")
  try check(pw.values[pfuture] != nil&&mw.values[mfuture] != nil,"future reservation retained")
  try check(pw.values[punknown] != nil&&mw.values[munknown] != nil,"keys outside explicit queue untouched")
  pw.fail=true;mw.fail=true;let later=now.addingTimeInterval(2)
  let pf=try NativePluginCredentialVault(db:db,backing:pw,clock:{later}).cleanup(),mf=try NativeMCPSettingsStore.cleanup(db:db,secretStore:mw,now:later)
  try check(pf.removed==0&&pf.pending==1&&pw.values[pfuture] != nil,"plugin failed cleanup stays pending")
  try check(mf.removed==0&&mf.pending==2&&mw.values[mfuture] != nil,"MCP failed cleanup stays pending")
  pw.fail=false;mw.fail=false
  let againP=try NativePluginCredentialVault(db:db,backing:pw,clock:{later}).cleanup(),againM=try NativeMCPSettingsStore.cleanup(db:db,secretStore:mw,now:later)
  try check(againP.removed==1&&againP.pending==0,"plugin retry succeeds")
  try check(againM.removed==1&&againM.pending==1,"MCP retry succeeds current reservation remains")
  try check(try Data(contentsOf:sealed)==before&&Data(contentsOf:focused)==focusedBefore,"writable controls do not touch sealed files")
  print(String(decoding:try JSONSerialization.data(withJSONObject:["checks":checks,"readonlyPluginRemovals":ps.removed.count,"readonlyMCPRemovals":ms.removed.count,"normalData":false,"realKeychain":false,"network":false],options:.sortedKeys),as:UTF8.self))
 }
}
