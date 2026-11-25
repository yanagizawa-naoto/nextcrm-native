#if PERSONAL_APP_QA
import Foundation
import Darwin

/// Compiled only into private QA packages. The nonce prevents an exec loop; it
/// does not prove isolation. Every continuation also queries the live policy.
enum NativePersonalQAStartup {
    private static var fixturePath:String {
        guard let path=Bundle.main.object(forInfoDictionaryKey:"NextCRMQADataRoot") as? String else {exit(78)}
        let pieces=path.split(separator:"/",omittingEmptySubsequences:false)
        guard pieces.count==5,pieces[0].isEmpty,pieces[1]=="private",pieces[2]=="tmp",pieces[4]=="workspace",
              pieces[3].hasPrefix("NextCRMPersonalAppQA-"),pieces[3].count>"NextCRMPersonalAppQA-".count,
              pieces[3].utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||$0==45||$0==95}) else {exit(78)}
        let parent="/private/tmp/"+pieces[3]
        var info=stat()
        guard lstat(parent,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==geteuid(),info.st_mode&0o777==0o700 else {exit(78)}
        // Only this build's existing private parent is accepted. Never create a
        // replacement or follow a fixture/control symlink after cleanup.
        for child in [path,path+"-control"] {
            var childInfo=stat()
            if lstat(child,&childInfo)==0 {
                guard childInfo.st_mode&S_IFMT==S_IFDIR,childInfo.st_uid==geteuid(),childInfo.st_mode&0o077==0 else {exit(78)}
            } else if errno != ENOENT {exit(78)}
        }
        return path
    }
    static var fixture:URL {URL(fileURLWithPath:fixturePath,isDirectory:true)}
    private static func validateArguments(_ root:String) {
        let args=Array(CommandLine.arguments.dropFirst())
        if args.first=="--personal-restore-helper" || args.first=="--personal-restore-child" {
            guard args.count==3,args[1]==root,args[2]==root+"-control" else {exit(78)}
        }
    }
    static func enter() {
        let root=fixturePath
        validateArguments(root)
        guard let token=Bundle.main.object(forInfoDictionaryKey:"NextCRMQASandboxToken") as? String,
              UUID(uuidString:token) != nil,let executable=Bundle.main.executableURL,
              let profile=Bundle.main.resourceURL?.appendingPathComponent("QA-sandbox.sb") else {exit(78)}
        let inherited=ProcessInfo.processInfo.environment["NEXTCRM_PRIVATE_QA_SANDBOX"]==token
        setenv("NEXTCRM_NATIVE_DATA_DIR",root,1)
        setenv("NEXTCRM_NATIVE_MAIL_TEST_MODE","success",1)
        setenv("NEXTCRM_NATIVE_INHERITED_SANDBOX","1",1)
        setenv("NEXTCRM_PRIVATE_QA_SANDBOX",token,1)
        if inherited {
            let home=NSHomeDirectory()
            let status=native_personal_qa_policy(URL(fileURLWithPath:root).deletingLastPathComponent().path,
                home+"/Library/Application Support/NextCRMNative",
                home+"/Library/Application Support/NextCRM",
                home+"/Library/Keychains")
            guard status==0 else {exit(78)}
            return
        }
        let values=["/usr/bin/sandbox-exec","-f",profile.path,executable.path]+Array(CommandLine.arguments.dropFirst())
        var arguments=values.map{strdup($0)}+[nil]
        arguments.withUnsafeMutableBufferPointer{buffer in _ = execv(values[0],buffer.baseAddress!)}
        exit(71)
    }
    static func markFixture(_ root:URL)throws {
        guard root.standardizedFileURL==fixture.standardizedFileURL else {throw NativeRestoreActivationFailure("qa.wrongRoot")}
        let marker=root.appendingPathComponent(".native-mail-test")
        if !FileManager.default.fileExists(atPath:marker.path) {
            try Data("NextCRM isolated mail QA\n".utf8).write(to:marker,options:.withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:marker.path)
        }
    }
}
#endif
