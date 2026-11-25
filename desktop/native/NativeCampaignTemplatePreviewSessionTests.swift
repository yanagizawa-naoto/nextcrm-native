import Foundation
import Darwin

@main enum NativeCampaignTemplatePreviewSessionTests {
    static var checks=0
    static func check(_ value:@autoclosure ()->Bool,_ label:String)throws{guard value()else{throw NativeMailHTMLError.unavailable};checks+=1}
    static func wait(_ seconds:Double,_ predicate:()->Bool)throws{let end=Date().addingTimeInterval(seconds);while Date()<end{if predicate(){return};RunLoop.current.run(until:Date().addingTimeInterval(0.01))};throw NativeMailHTMLError.unavailable}
    static func main(){do{try run()}catch{FileHandle.standardError.write(Data("NativeCampaignTemplatePreviewSessionTests: \(error)\n".utf8));exit(1)}}
    static func run()throws{
        let folder=URL(fileURLWithPath:CommandLine.arguments[1])
        let rows=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("documents.json"))) as! [[String:String]]
        let html=rows.first{$0["id"]=="table"}!["html"]!,visual=CommandLine.arguments.contains("--visual")
        var owned:[Int32]=[],failureCalls=0
        for index in 0..<3 {
            // The second run closes while a bounded large input can still be
            // queued/writing, exercising broken-pipe + process join together.
            let value=index==1 ? "<!doctype html><p>"+String(repeating:"a",count:4_000_000)+"</p>" : html
            let document=try NativeMailHTMLDocument(subject:"合成テンプレートのプレビュー検証",html:value)
            let session=try NativeMailHTMLSession(document:document){failureCalls+=1}
            let pid=session.testProcessID;owned.append(pid)
            try check(pid>1 && session.testProcessRunning,"owned helper launched")
            if index != 1 {
                let end=Date().addingTimeInterval(visual && index==0 ? 120 : 1.2)
                FileHandle.standardOutput.write(Data("VIEWER_READY \(pid)\n".utf8))
                while Date()<end {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
            }
            var first=false,second=false
            session.closeAndDrain{first=true};session.closeAndDrain{second=true}
            try wait(12){first && second}
            try check(first && second && !session.testProcessRunning,"all drains await child termination")
            errno=0;let alive=kill(pid,0)
            try check(alive == -1 && errno == ESRCH,"owned PID reaped before drain returns")
        }
        try check(failureCalls==0,"intentional closure is not reported as failed preview")
        let proof:[String:Any]=["checks":checks,"ownedPIDs":owned,"allExited":true,"brokenPipeLargeInputBytes":4_000_000,"normalData":false,"remoteContentOptIn":false,"scope":"Actual private helper compiled from current production Mail Viewer sources, launched through candidate NativeMailHTMLSession. Process/pipe drain verified separately from fake UI lifecycle and renderer DOM tests. No user-close-button, visual-pixel or provider assertion."]
        try JSONSerialization.data(withJSONObject:proof,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("session-results.json"))
        print("CampaignTemplateSession: \(checks) checks passed")
    }
}
