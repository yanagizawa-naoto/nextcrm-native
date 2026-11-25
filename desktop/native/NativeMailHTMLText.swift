import Foundation
import Darwin

/// Text-only incoming-email projection. The OS SAX parser never executes or
/// fetches markup. Only the resulting text is retained; list counts spill into
/// the existing owned mail temporary file instead of keeping one object per li.
enum NativeMailHTMLText {
    private static let whitespace=Set(" \t\r\n\u{0c}\u{200b}".unicodeScalars)
    private struct Frame {
        var tag:String, attributes:[String:String]=[:], suppressed=false
        var synthetic=false, start=0, trailing=0, pre=false, heading=false, anchorText=false
        var listID:Int?=nil, count=0, next:Double=1, maxPrefix=0, nested=false
        var itemPrefix="", itemIndent=0
    }
    private final class Counter {
        let temporaryRoot:URL
        init(temporaryRoot:URL){self.temporaryRoot=temporaryRoot}
        var stack:[Frame]=[], nextID=0, attribute="", file:NativeMailResponseFile?, error:Error?
        func event(_ kind:Int32,_ value:String)throws {
            switch kind {
            case 1:
                if value=="li",let i=stack.indices.last,["ul","ol"].contains(stack[i].tag){stack[i].count += 1}
                var frame=Frame(tag:value)
                if ["ol","ul"].contains(value){frame.listID=nextID;nextID += 1;if file==nil{file=try NativeMailResponseFile(temporaryRoot:temporaryRoot)}}
                stack.append(frame)
            case 6:
                guard let frame=stack.popLast() else{return}
                if let id=frame.listID,let file {var count=UInt64(frame.count).littleEndian;try file.withDescriptor{fd in try withUnsafeBytes(of:&count){bytes in guard pwrite(fd,bytes.baseAddress,bytes.count,off_t(id*8))==bytes.count else{throw NativeMailResponseFile.fileError}}}}
            default:break
            }
        }
        func count(_ id:Int)throws->Int {guard let file else{return 0};var count:UInt64=0;try file.withDescriptor{fd in try withUnsafeMutableBytes(of:&count){bytes in guard pread(fd,bytes.baseAddress,bytes.count,off_t(id*8))==bytes.count else{throw NativeMailResponseFile.fileError}}};guard count<=UInt64(Int.max) else{throw NativeMailFailure.tooLarge};return Int(UInt64(littleEndian:count))}
    }
    private final class Renderer {
        let counter:Counter,onlyBody:Bool,maximum:Int
        var stack:[Frame]=[],attribute="", nextList=0, insideBody=false,error:Error?,syntheticStarts=0
        let output=NSMutableString();var bytes=0,word="",space=false,opportunity=false,pending=0,line=0,preDepth=0,headingDepth=0
        init(counter:Counter,onlyBody:Bool,maximum:Int){self.counter=counter;self.onlyBody=onlyBody;self.maximum=maximum;syntheticStarts=onlyBody ? 0 : 3}
        func append(_ value:String)throws{let size=value.utf8.count;guard size<=maximum-bytes else{throw NativeMailFailure.tooLarge};autoreleasepool{output.append(value)};bytes += size;if let last=value.lastIndex(of:"\n"){line=value[value.index(after:last)...].utf16.count}else{line += value.utf16.count}}
        func flushBreaks()throws{if pending>0{if output.length>0{try append(String(repeating:"\n",count:pending))};pending=0;space=false;opportunity=false}}
        func flushWord()throws {
            guard !word.isEmpty else{return};try flushBreaks()
            let value=word;word=""
            if (space || opportunity) && line>0 {if line+(space ? 1:0)+value.utf16.count>max(1,80-stack.reduce(0){$0+($1.tag=="blockquote" ? 2:0)+$1.itemIndent}) {try append("\n")}else if space{try append(" ")}}
            try append(value);space=false;opportunity=false
        }
        func inline(_ value:String,transform:Bool=true)throws{
            if preDepth>0{try flushWord();try flushBreaks();try append(value);return}
            for scalar in value.unicodeScalars {
                if NativeMailHTMLText.whitespace.contains(scalar){try flushWord();space=true}
                else {let part=String(scalar);word += transform && headingDepth>0 ? part.uppercased() : part;guard word.utf8.count<=maximum else{throw NativeMailFailure.tooLarge}}
            }
            if value.unicodeScalars.contains(where:{!NativeMailHTMLText.whitespace.contains($0)}) {for i in stack.indices where stack[i].tag=="a" {stack[i].anchorText=true}}
        }
        func block(_ leading:Int)throws{try flushWord();pending=max(pending,leading);try flushBreaks()}
        func replace(from start:Int,with value:String)throws {
            let old=output.substring(from:start);let updated=bytes-old.utf8.count+value.utf8.count;guard updated<=maximum else{throw NativeMailFailure.tooLarge};output.replaceCharacters(in:NSRange(location:start,length:output.length-start),with:value);bytes=updated
            let newline=output.range(of:"\n",options:.backwards);line=newline.location==NSNotFound ? output.length : output.length-newline.location-1
        }
        func event(_ kind:Int32,_ value:String)throws {
            switch kind {
            case 1:
                var f=Frame(tag:value);f.synthetic=syntheticStarts>0;syntheticStarts=max(0,syntheticStarts-1);f.suppressed=stack.last?.suppressed==true || ["script","style"].contains(value)
                if value=="body"{insideBody=true}
                if onlyBody && !insideBody {f.suppressed=true}
                if value=="body" && onlyBody {f.suppressed=false}
                stack.append(f)
            case 2:attribute=value
            case 3:
                guard let i=stack.indices.last else{return}
                if ["href","src","alt","start","type"].contains(attribute){stack[i].attributes[attribute]=value}
            case 4:
                guard let i=stack.indices.last else{return};let tag=stack[i].tag
                if ["ol","ul"].contains(tag){stack[i].listID=nextList;nextList += 1}
                if stack[i].suppressed || stack[i].synthetic{return}
                let blocks=["article","aside","div","footer","form","header","main","nav","section"]
                if blocks.contains(tag){try block(1);stack[i].trailing=1}
                if ["p","table","pre","blockquote","ol","ul","hr"].contains(tag){try block(["ol","ul"].contains(tag) ? 1 : 2);stack[i].trailing=2}
                if ["h1","h2","h3","h4","h5","h6"].contains(tag){try block(["h1","h2","h3"].contains(tag) ? 3 : 2);stack[i].trailing=2;stack[i].heading=true;headingDepth += 1}
                stack[i].start=output.length
                if tag=="pre"{preDepth += 1;stack[i].pre=true}
                if tag=="br"{try flushWord();try flushBreaks();try append("\n")}
                if tag=="wbr"{try flushWord();opportunity=true}
                if tag=="hr"{try inline(String(repeating:"-",count:80));try flushWord()}
                if tag=="img"{let alt=stack[i].attributes["alt"] ?? "",src=stack[i].attributes["src"] ?? "";try inline(src.isEmpty ? alt : alt.isEmpty ? "["+src+"]" : alt+" ["+src+"]",transform:false)}
                if ["ol","ul"].contains(tag){
                    stack[i].nested=i>0 && stack[i-1].tag=="li";let n=try counter.count(stack[i].listID!);let start=Double(stack[i].attributes["start"] ?? "1") ?? .nan;stack[i].next=start
                    for offset in 0..<n {if offset % 256 == 0{try Task.checkCancellation()};stack[i].maxPrefix=max(stack[i].maxPrefix,prefix(tag:tag,type:stack[i].attributes["type"] ?? "1",number:start+Double(offset),nested:stack[i].nested).utf16.count)}
                }
                if tag=="li",i>0,["ul","ol"].contains(stack[i-1].tag){
                    let j=i-1;try flushWord();if stack[j].count>0{pending=max(pending,1);try flushBreaks()}
                    let prefix=prefix(tag:stack[j].tag,type:stack[j].attributes["type"] ?? "1",number:stack[j].next,nested:stack[j].nested);stack[j].next += 1;stack[j].count += 1
                    stack[i].start=output.length;stack[i].itemPrefix=prefix+String(repeating:" ",count:max(0,stack[j].maxPrefix-prefix.utf16.count));stack[i].itemIndent=stack[j].maxPrefix
                }
            case 5:if stack.last?.suppressed != true{try inline(value)}
            case 6:
                guard let f=stack.popLast() else{return};if f.suppressed || f.synthetic{return}
                if f.tag=="a",var href=f.attributes["href"],!href.isEmpty,!href.hasPrefix("#") {
                    if href.hasPrefix("mailto:"){href=String(href.dropFirst(7))}
                    try inline(f.anchorText ? " ["+href+"]" : href,transform:false)
                }
                if f.pre{preDepth -= 1};if f.heading{headingDepth -= 1}
                if f.tag=="blockquote"{try flushWord();pending=0;let part=output.substring(from:f.start).trimmingCharacters(in:CharacterSet(charactersIn:"\n"));try replace(from:f.start,with:part.components(separatedBy:"\n").map{"> "+$0}.joined(separator:"\n"))}
                if f.tag=="li",!f.itemPrefix.isEmpty{try flushWord();pending=0;let part=output.substring(from:f.start);let lines=part.components(separatedBy:"\n");try replace(from:f.start,with:lines.enumerated().map{($0.offset==0 ? f.itemPrefix : String(repeating:" ",count:f.itemIndent))+$0.element}.joined(separator:"\n"))}
                if f.trailing>0{try flushWord();pending=max(pending,f.nested ? 1 : f.trailing)}
                if f.tag=="body"{insideBody=false}
            default:break
            }
        }
        func prefix(tag:String,type:String,number:Double,nested:Bool)->String {
            let label:String
            if tag=="ul"{label="*"}
            else if number.isFinite,number>=1,number.rounded()==number,["a","A"].contains(type){var n=number,s="";while n>=1{n -= 1;s=String(UnicodeScalar(65+Int(n.truncatingRemainder(dividingBy:26)))!)+s;n=(n/26).rounded(.down)};label=(type=="a" ? s.lowercased() : s)+"."}
            else if number.isFinite,number>=1,number<=3999,["i","I"].contains(type){var n=Int(number),s="";for (v,t) in [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),(50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")]{while n>=v{s += t;n -= v}};label=(type=="i" ? s.lowercased() : s)+"."}
            else {label=(number.isNaN ? "NaN" : String(format:"%.0f",number))+"."}
            return (nested ? "" : " ")+label+" "
        }
        func finish()throws->String{try flushWord();var text=output as String;text.makeContiguousUTF8();return text}
    }
    private static func parse(_ html:String,wrapped:Bool,_ handler:@escaping(Int32,String)throws->Void)throws {
        final class Box {let handler:(Int32,String)throws->Void;var error:Error?;init(_ h:@escaping(Int32,String)throws->Void){handler=h}}
        let box=Box(handler)
        guard let parser=nextcrm_html_create(Unmanaged.passUnretained(box).toOpaque(),{context,kind,bytes,count in guard let context else{return 0};let b=Unmanaged<Box>.fromOpaque(context).takeUnretainedValue();do{try b.handler(kind,bytes.map{String(decoding:UnsafeRawBufferPointer(start:$0,count:count),as:UTF8.self)} ?? "");return 1}catch{b.error=error;return 0}}) else{throw NativeMailFailure.malformed}
        defer{nextcrm_html_destroy(parser)}
        var chunk=Data();chunk.reserveCapacity(32768)
        func flush(_ final:Bool=false)throws{try Task.checkCancellation();let code=autoreleasepool{chunk.withUnsafeBytes{nextcrm_html_feed(parser,$0.baseAddress?.assumingMemoryBound(to:UInt8.self),$0.count,final ? 1:0)}};chunk.removeAll(keepingCapacity:true);if let error=box.error{throw error};guard code==0 else{throw NativeMailFailure.malformed}}
        if wrapped { chunk.append(Data("<html><body><div>".utf8));try flush() }
        var entity:[UInt8]=[],inTag=false,quote:UInt8?
        func emit(_ byte:UInt8)throws{
            if let q=quote {if byte==q{quote=nil}}
            else if inTag && (byte==34 || byte==39){quote=byte}
            else if byte==60{inTag=true}else if byte==62{inTag=false}
            chunk.append(byte);if chunk.count>=32768{try flush()}
        }
        func entityEnd(next:UInt8?,semicolon:Bool=false)throws {
            let candidate=Array(entity.dropFirst())+(semicolon ? [59]:[])
            var matched=false
            if !candidate.isEmpty {
                for length in stride(from:candidate.count,through:1,by:-1){
                    guard let numeric=candidate.withUnsafeBufferPointer({nextcrm_html_entity($0.baseAddress,length)}) else{continue}
                    let following=length<candidate.count ? candidate[length] : next
                    if inTag,candidate[length-1] != 59,let following,((65...90).contains(following)||(97...122).contains(following)||(48...57).contains(following)||following==61){break}
                    for b in String(cString:numeric).utf8{try emit(b)}
                    for b in candidate.dropFirst(length){try emit(b)}
                    matched=true;break
                }
            }
            if !matched{for b in entity{try emit(b)};if semicolon{try emit(59)}}
            entity=[]
        }
        for byte in html.utf8 {
            if !entity.isEmpty {
                if byte==59 {try entityEnd(next:nil,semicolon:true);continue}
                if entity.count<64,((65...90).contains(byte)||(97...122).contains(byte)||(48...57).contains(byte)){entity.append(byte);continue}
                try entityEnd(next:byte)
            }
            if byte==38{entity=[byte]}else{try emit(byte)}
        }
        if !entity.isEmpty{try entityEnd(next:nil)};if wrapped{chunk.append(Data("</div></body></html>".utf8))};try flush(true)
    }
    /// Detect a real body element without mistaking comments, raw text or
    /// attribute values for document structure. No list of tag matches is built.
    private static func explicitBody(_ html:String)->Bool {
        let bytes=html.utf8;var i=bytes.startIndex;var raw:String?
        func lower(_ b:UInt8)->UInt8{(65...90).contains(b) ? b+32:b}
        func starts(_ value:String,at index:String.UTF8View.Index)->Bool {let suffix=bytes[index...];return zip(suffix,value.utf8).allSatisfy{lower($0)==$1} && suffix.prefix(value.utf8.count).count==value.utf8.count}
        while i<bytes.endIndex {
            if bytes[i] != 60{i=bytes.index(after:i);continue}
            if let raw,!starts("</"+raw,at:i){i=bytes.index(after:i);continue}
            if starts("<!--",at:i){i=bytes.index(i,offsetBy:4);while i<bytes.endIndex && !starts("-->",at:i){i=bytes.index(after:i)};if i<bytes.endIndex{i=bytes.index(i,offsetBy:3)};continue}
            i=bytes.index(after:i);if i==bytes.endIndex{break};let closing=bytes[i]==47;if closing{i=bytes.index(after:i)}
            var name="",length=0
            while i<bytes.endIndex,(65...90).contains(bytes[i]) || (97...122).contains(bytes[i]) || (48...57).contains(bytes[i]){if length<32{name.append(Character(UnicodeScalar(lower(bytes[i]))))};length += 1;i=bytes.index(after:i)}
            if length==4,name=="body",!closing,i<bytes.endIndex,[9,10,12,13,32,47,62].contains(bytes[i]){return true}
            var quote:UInt8?
            while i<bytes.endIndex {let b=bytes[i];i=bytes.index(after:i);if let q=quote{if b==q{quote=nil}}else if b==34 || b==39{quote=b}else if b==62{break}}
            if closing && name==raw{raw=nil}else if !closing,["script","style","textarea","title","xmp"].contains(name){raw=name}
        }
        return false
    }
    static func convert(_ html:String,maximumBytes:Int=Int.max,temporaryRoot:URL=FileManager.default.temporaryDirectory)throws->String {
        guard maximumBytes>0 else{throw NativeMailFailure.tooLarge}
        return try autoreleasepool {
            // The installed html-to-text default limits its *input* to 2^24
            // UTF-16 units. Preserve that source contract without imposing a
            // narrower byte cap on the derived result or the retained HTML.
            let input=html.utf16.count>16_777_216 ? String(decoding:html.utf16.prefix(16_777_216),as:UTF16.self) : html
            let onlyBody=explicitBody(input)
            let counter=Counter(temporaryRoot:temporaryRoot);try parse(input,wrapped:!onlyBody){try counter.event($0,$1)}
            let renderer=Renderer(counter:counter,onlyBody:onlyBody,maximum:maximumBytes);try parse(input,wrapped:!onlyBody){try renderer.event($0,$1)};return try renderer.finish()
        }
    }
}
