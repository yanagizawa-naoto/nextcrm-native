import Foundation
import ImageIO

@main enum Probe {
    static func main() throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        if CommandLine.arguments.count == 3, CommandLine.arguments[2] == "parent-death" {
            _ = try NativeDocumentProcessing.extract(url:root.appendingPathComponent("fixtures/parent-death.svg"),mimeType:"image/svg+xml",svgWorker:root.appendingPathComponent("NextCRMDocumentSVG"))
            return
        }
        let inputs = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("fixtures/inputs.json"))) as! [[String:String]]
        var results = [[String:Any]]()
        for input in inputs {
            var item:[String:Any] = ["name":input["name"]!]
            do {
                let result = try NativeDocumentProcessing.extract(url:URL(fileURLWithPath:input["path"]!),mimeType:input["mime"]!,svgWorker:root.appendingPathComponent("NextCRMDocumentSVG"))
                var text="";try result.text.forEachChunk { text += $0 };item["text"]=text;item["note"]=result.note
                if let data=result.thumbnail {
                    let image=CGImageSourceCreateWithData(data as CFData,nil)!
                    let p=CGImageSourceCopyPropertiesAtIndex(image,0,nil)! as NSDictionary
                    item["thumbnail"]=["width":p[kCGImagePropertyPixelWidth]!,"height":p[kCGImagePropertyPixelHeight]!]
                    try data.write(to:root.appendingPathComponent("fixtures/"+input["name"]!+".native.png"))
                }
            } catch { item["error"]=error.localizedDescription }
            results.append(item)
        }
        try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("native.json"))
        print("Compared \(results.count) document formats")
    }
}
