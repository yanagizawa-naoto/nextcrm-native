import Foundation
@main enum CampaignHTMLTests {
    struct Reference: Decodable { struct Row: Decodable { let id: String; let html: String; let expected: String }; let cases: [Row] }
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("CampaignHTMLTests: \(error)\n".utf8));exit(1) } }
    static func run() throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), reference = try JSONDecoder().decode(Reference.self,from:Data(contentsOf:root.appendingPathComponent("campaign-html-reference.json")))
        var result: [[String:String]] = []
        for item in reference.cases { var output = ""; do { try CampaignHTML.sanitize(item.html){output += $0}; result.append(["id":item.id,"actual":output]) } catch { result.append(["id":item.id,"error":error.localizedDescription]) } }
        try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.withoutEscapingSlashes]).write(to:root.appendingPathComponent("campaign-html-actual.json"))
        var rejected = false
        do { try CampaignHTML.sanitize(String(repeating:"<div>",count:130)+"深い"+String(repeating:"</div>",count:130)){_ in} } catch { rejected = true }
        guard rejected else { throw NativeDBError.message("excessive nesting accepted") }
        struct SinkFailure: Error {}
        var callbacks = 0; rejected = false
        do { try CampaignHTML.sanitize("<p>本文</p>"){_ in callbacks += 1; throw SinkFailure()} } catch is SinkFailure { rejected = true }
        guard rejected, callbacks == 1 else { throw NativeDBError.message("sink failure not propagated immediately") }
        print("CampaignHTMLTests: emitted \(result.count) sanitizer results")
    }
}
