import Foundation
import CoreGraphics
import ImageIO
import zlib

/// Independent APNG prototype. Not linked to the production avatar path.
/// Metadata is scanned once for validation and again while pulling frames.
/// Each ImageIO source contains one static PNG, never the whole animation.
final class NativeUserAvatarAPNGPrototype {
    enum Failure:Error {case invalid,staticPNG,inputLimit,canvasLimit,metadataLimit,unsupported}
    struct Frame {let image:CGImage,index:Int,delay:Double}
    struct Control {let width:Int,height:Int,x:Int,y:Int,delay:Double,dispose:Int,blend:Int}
    struct Chunk {let kind:String,start:Int,body:Range<Int>,end:Int}
    static let maximumInputBytes=4*1024*1024,maximumDimension=1024,maximumCanvasPixels=1_048_576
    private static let signature=Data([137,80,78,71,13,10,26,10])
    private static let crcTable:[UInt32]=(0..<256).map { value in var v=UInt32(value);for _ in 0..<8 {v=(v>>1) ^ (v&1==0 ? 0:0xedb88320)};return v }
    private let data:Data,header:Data,shared:Data,canvas:CGContext
    let width:Int,height:Int,frameCount:Int,iterations:Int?,defaultIsFirstFrame:Bool
    private var cursor=33,index=0,passes=0,previous:Control?,restore:CGImage?
    private(set)var decodedFrameCount=0

    init(data original:Data)throws {
        try Task.checkCancellation()
        guard original.count<=Self.maximumInputBytes else{throw Failure.inputLimit}
        let data=original.startIndex==0 ? original:Data(original)
        guard data.count>=33,data.prefix(8)==Self.signature else{throw Failure.invalid}
        let ihdr=try Self.chunk(data,8,crc:true)
        guard ihdr.kind=="IHDR",ihdr.body.count==13 else{throw Failure.invalid}
        let w=Self.int(data,16,4),h=Self.int(data,20,4),depth=Int(data[24]),color=Int(data[25])
        guard w>0,h>0 else{throw Failure.invalid}
        guard w<=Self.maximumDimension,h<=Self.maximumDimension,w*h<=Self.maximumCanvasPixels else{throw Failure.canvasLimit}
        let validDepths:[Int:[Int]]=[0:[1,2,4,8,16],2:[8,16],3:[1,2,4,8],4:[8,16],6:[8,16]]
        guard validDepths[color]?.contains(depth)==true,data[26]==0,data[27]==0,data[28]<=1 else{throw Failure.invalid}
        var p=33,declared:Int?,plays:Int?,seq=0,frames=0,hasIDAT=false,idatClosed=false,frameData=false,hasControl=false,firstIsIDAT=false,ended=false,shared=Data(),palette=false
        var seen:Set<String>=[]
        let inherited:Set<String>=["PLTE","tRNS","gAMA","cHRM","sRGB","iCCP","sBIT","cICP","mDCV","cLLI","pHYs","eXIf"]
        while p<data.count {
            try Task.checkCancellation();let c=try Self.chunk(data,p,crc:true);p=c.end
            if hasIDAT && c.kind != "IDAT" {idatClosed=true}
            switch c.kind {
            case "IHDR":throw Failure.invalid
            case "acTL":
                guard declared==nil,!hasIDAT,c.body.count==8 else{throw Failure.invalid}
                let count=Self.int(data,c.body.lowerBound,4);guard count>0 else{throw Failure.invalid};declared=count;plays=Self.int(data,c.body.lowerBound+4,4)
            case "fcTL":
                guard declared != nil,(!hasControl || frameData) else{throw Failure.invalid}
                let f=try Self.control(data,c,w,h)
                guard Self.int(data,c.body.lowerBound,4)==seq else{throw Failure.invalid};seq += 1
                if !hasIDAT {guard frames==0,f.x==0,f.y==0,f.width==w,f.height==h else{throw Failure.invalid};firstIsIDAT=true}
                frames += 1;hasControl=true;frameData=false
            case "IDAT":
                guard !idatClosed,(!hasControl || frames==1 && firstIsIDAT) else{throw Failure.invalid}
                hasIDAT=true;if hasControl && !c.body.isEmpty{frameData=true}
            case "fdAT":
                guard hasIDAT,hasControl,c.body.count>=4,!(frames==1 && firstIsIDAT),Self.int(data,c.body.lowerBound,4)==seq else{throw Failure.invalid}
                seq += 1;if c.body.count>4{frameData=true}
            case "IEND":
                guard c.body.isEmpty,hasIDAT,(!hasControl || frameData) else{throw Failure.invalid};ended=true
            default:
                if inherited.contains(c.kind) {
                    guard !hasIDAT,!seen.contains(c.kind)else{throw Failure.invalid};seen.insert(c.kind)
                    if c.kind=="PLTE" {guard !c.body.isEmpty,c.body.count<=768,c.body.count%3==0 else{throw Failure.invalid};palette=true}
                    if c.kind=="tRNS" && color==3 && !palette {throw Failure.invalid}
                    if c.kind=="iCCP" {try Self.validateProfile(data,c.body)}
                    shared.append(data[c.start..<c.end])
                }else if data[c.start+4]&32==0 {throw Failure.unsupported}
            }
            if ended {break}
        }
        guard ended,color != 3 || palette else{throw Failure.invalid}
        guard let declared,let plays else{throw Failure.staticPNG}
        guard frames==declared,frames>0,let canvas=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{throw Failure.invalid}
        self.data=data;header=Data(data[ihdr.body]);self.shared=shared;self.canvas=canvas;width=w;height=h;frameCount=frames;iterations=plays==0 ? nil:plays;defaultIsFirstFrame=firstIsIDAT
        canvas.clear(CGRect(x:0,y:0,width:w,height:h))
    }
    private static func int(_ data:Data,_ p:Int,_ count:Int)->Int {var v=0;for i in 0..<count{v=(v<<8)|Int(data[p+i])};return v}
    private static func bytes(_ value:Int,_ count:Int=4)->Data {Data((0..<count).map{UInt8((value>>((count-1-$0)*8))&255)})}
    private static func crc(_ data:Data,_ range:Range<Int>)->UInt32 {
        data.withUnsafeBytes {raw in let b=raw.bindMemory(to:UInt8.self);var v:UInt32=0xffffffff;for p in range{v=crcTable[Int((v ^ UInt32(b[p]))&255)] ^ (v>>8)};return v ^ 0xffffffff}
    }
    private static func chunk(_ data:Data,_ p:Int,crc check:Bool=false)throws->Chunk {
        guard p>=8,data.count-p>=12 else{throw Failure.invalid}
        let count=int(data,p,4);guard count<=0x7fffffff,count<=data.count-p-12 else{throw Failure.invalid}
        let type=data[(p+4)..<(p+8)];guard type.allSatisfy({(65...90).contains($0)||(97...122).contains($0)}),data[p+6]&32==0 else{throw Failure.invalid}
        let body=(p+8)..<(p+8+count)
        if check,crc(data,(p+4)..<body.upperBound) != UInt32(int(data,body.upperBound,4)){throw Failure.invalid}
        return Chunk(kind:String(bytes:type,encoding:.ascii)!,start:p,body:body,end:body.upperBound+4)
    }
    private static func control(_ data:Data,_ c:Chunk,_ w:Int,_ h:Int)throws->Control {
        guard c.body.count==26 else{throw Failure.invalid};let p=c.body.lowerBound
        let fw=int(data,p+4,4),fh=int(data,p+8,4),x=int(data,p+12,4),y=int(data,p+16,4),num=int(data,p+20,2),den=int(data,p+22,2),dispose=Int(data[p+24]),blend=Int(data[p+25])
        guard fw>0,fh>0,x<w,y<h,fw<=w-x,fh<=h-y,dispose<=2,blend<=1 else{throw Failure.invalid}
        // Chromium's PNG decoder truncates the rational delay to whole ms.
        // Keep that tested browser behavior, including its sub-11ms clamp.
        return Control(width:fw,height:fh,x:x,y:y,delay:Double(num*1000/(den==0 ? 100:den))/1000,dispose:dispose,blend:blend)
    }
    private static func encoded(_ kind:String,_ body:Data)->Data {var out=bytes(body.count);out.append(Data(kind.utf8));out.append(body);out.append(bytes(Int(crc(out,4..<out.count))));return out}
    private static func validateProfile(_ data:Data,_ range:Range<Int>)throws {
        guard let zero=data[range].firstIndex(of:0),zero>range.lowerBound,zero-range.lowerBound<=79,zero+2<range.upperBound,data[zero+1]==0 else{throw Failure.invalid}
        var stream=z_stream();guard inflateInit_(&stream,zlibVersion(),Int32(MemoryLayout<z_stream>.size))==Z_OK else{throw Failure.invalid};defer{inflateEnd(&stream)}
        var scratch=[UInt8](repeating:0,count:32768),total=0,ended=false
        try data.withUnsafeBytes{raw in
            stream.next_in=UnsafeMutablePointer(mutating:raw.bindMemory(to:UInt8.self).baseAddress!+zero+2);stream.avail_in=UInt32(range.upperBound-zero-2)
            while true {
                try Task.checkCancellation();let before=stream.avail_in
                let status=scratch.withUnsafeMutableBytes{out->Int32 in stream.next_out=out.bindMemory(to:UInt8.self).baseAddress!;stream.avail_out=UInt32(out.count);return inflate(&stream,Z_NO_FLUSH)}
                let produced=scratch.count-Int(stream.avail_out);total += produced
                guard total<=Self.maximumInputBytes else{throw Failure.metadataLimit}
                if status==Z_STREAM_END{ended=true;break}
                guard status==Z_OK,before != stream.avail_in || produced>0 else{throw Failure.invalid}
            }
        }
        guard ended else{throw Failure.invalid}
    }
    private func rectangle(_ f:Control)->CGRect {CGRect(x:f.x,y:height-f.y-f.height,width:f.width,height:f.height)}
    /// ImageIO can return a lazy CGImage for a damaged zlib stream. Validate
    /// the exact filtered byte count and zlib checksum with bounded scratch
    /// space before allowing ImageIO to allocate any pixel decode buffers.
    private func validatePixels(_ f:Control,_ range:Range<Int>)throws {
        let depth=Int(header[8]),color=Int(header[9]),channels=[0:1,2:3,3:1,4:2,6:4][color]!
        let passes=header[12]==0 ? [(0,0,1,1)]:[(0,0,8,8),(4,0,8,8),(0,4,4,8),(2,0,4,4),(0,2,2,4),(1,0,2,2),(0,1,1,2)]
        var expected=0,layout:[(stride:Int,rows:Int)]=[]
        for (x,y,dx,dy) in passes where x<f.width && y<f.height {let w=(f.width-x+dx-1)/dx,h=(f.height-y+dy-1)/dy,stride=1+(w*depth*channels+7)/8;expected += stride*h;layout.append((stride,h))}
        var stream=z_stream();guard inflateInit_(&stream,zlibVersion(),Int32(MemoryLayout<z_stream>.size))==Z_OK else{throw Failure.invalid};defer{inflateEnd(&stream)}
        var scratch=[UInt8](repeating:0,count:32768),total=0,ended=false,p=range.lowerBound,layoutIndex=0,rowsRemaining=layout[0].rows,filterOffset=0
        while p<range.upperBound {
            try Task.checkCancellation();let c=try Self.chunk(data,p);p=c.end
            guard c.kind=="IDAT" || c.kind=="fdAT" else{continue}
            let start=c.body.lowerBound+(c.kind=="fdAT" ? 4:0),count=c.body.upperBound-start
            guard !ended || count==0 else{throw Failure.invalid}
            try data.withUnsafeBytes{raw in
                stream.next_in=UnsafeMutablePointer(mutating:raw.bindMemory(to:UInt8.self).baseAddress!+start);stream.avail_in=UInt32(count)
                while count>0 {
                    try Task.checkCancellation();let before=stream.avail_in
                    let status=scratch.withUnsafeMutableBytes{out->Int32 in stream.next_out=out.bindMemory(to:UInt8.self).baseAddress!;stream.avail_out=UInt32(out.count);return inflate(&stream,Z_NO_FLUSH)}
                    let produced=scratch.count-Int(stream.avail_out)
                    guard total+produced<=expected else{throw Failure.invalid}
                    while filterOffset<total+produced {
                        guard scratch[filterOffset-total]<=4 else{throw Failure.invalid}
                        filterOffset += layout[layoutIndex].stride;rowsRemaining -= 1
                        if rowsRemaining==0{layoutIndex += 1;if layoutIndex<layout.count{rowsRemaining=layout[layoutIndex].rows}}
                    }
                    total += produced
                    if status==Z_STREAM_END{guard stream.avail_in==0 else{throw Failure.invalid};ended=true;break}
                    if status==Z_BUF_ERROR && stream.avail_in==0 && produced==0{break}
                    guard status==Z_OK,before != stream.avail_in || produced>0 else{throw Failure.invalid}
                    if stream.avail_in==0 && stream.avail_out>0{break}
                }
            }
        }
        guard ended,total==expected else{throw Failure.invalid}
    }
    func nextFrame()throws->Frame? {
        try Task.checkCancellation();guard iterations.map({passes<$0}) ?? true else{return nil}
        if index==0 {cursor=33;previous=nil;restore=nil;canvas.clear(CGRect(x:0,y:0,width:width,height:height))}
        var frame:Control?
        while cursor<data.count {let c=try Self.chunk(data,cursor);cursor=c.end;if c.kind=="fcTL"{frame=try Self.control(data,c,width,height);break}}
        guard let f=frame else{throw Failure.invalid}
        var ihdr=header;ihdr.replaceSubrange(0..<4,with:Self.bytes(f.width));ihdr.replaceSubrange(4..<8,with:Self.bytes(f.height))
        var encoded=Self.signature;encoded.append(Self.encoded("IHDR",ihdr));encoded.append(shared);var hasPixels=false
        let payloadStart=cursor
        while cursor<data.count {
            try Task.checkCancellation();let c=try Self.chunk(data,cursor)
            if c.kind=="fcTL" || c.kind=="IEND"{break};cursor=c.end
            if c.kind=="IDAT" {encoded.append(data[c.start..<c.end]);hasPixels=true}
            else if c.kind=="fdAT" {encoded.append(Self.encoded("IDAT",Data(data[(c.body.lowerBound+4)..<c.body.upperBound])));hasPixels=true}
        }
        guard hasPixels else{throw Failure.invalid};encoded.append(Self.encoded("IEND",Data()))
        try validatePixels(f,payloadStart..<cursor)
        guard let source=CGImageSourceCreateWithData(encoded as CFData,[kCGImageSourceShouldCache:false]as CFDictionary),let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:false,kCGImageSourceShouldCacheImmediately:true,kCGImageSourceShouldAllowFloat:false]as CFDictionary),image.width==f.width,image.height==f.height else{throw Failure.invalid}
        try Task.checkCancellation()
        if let previous {if previous.dispose==1{canvas.clear(rectangle(previous))}else if previous.dispose==2,let restore{canvas.setBlendMode(.copy);canvas.draw(restore,in:CGRect(x:0,y:0,width:width,height:height));canvas.setBlendMode(.normal)}}
        restore=nil;if f.dispose==2{restore=canvas.makeImage();guard restore != nil else{throw Failure.invalid}}
        if f.blend==0{canvas.clear(rectangle(f))};canvas.interpolationQuality = .none;canvas.draw(image,in:rectangle(f))
        guard let composed=canvas.makeImage()else{throw Failure.invalid};try Task.checkCancellation()
        let current=index;previous=f;index += 1;decodedFrameCount += 1
        if index==frameCount{index=0;if iterations != nil{passes += 1}}
        return Frame(image:composed,index:current,delay:f.delay<0.011 ? 0.1:f.delay)
    }
}
