// EXPERIMENT ONLY. Independent of the frozen production avatar implementation.
import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import Darwin

enum AvatarPrototypeError: Error { case invalid, limit, io }
enum AvatarPrototypeBytes {
    static let inputLimit=4*1024*1024, pixelLimit=16_777_216, dimensionLimit=16_384
    static func u(_ d:Data,_ p:Int,_ n:Int)throws->Int {
        guard p>=0 && n>=0 && n<=4 && p<=d.count-n else { throw AvatarPrototypeError.invalid }
        var result=0;for i in 0..<n { result |= Int(d[p+i]) << (i*8) };return result
    }
    static func tag(_ d:Data,_ p:Int)throws->String {
        guard p>=0 && p<=d.count-4 else { throw AvatarPrototypeError.invalid }
        return String(bytes:d[p..<(p+4)],encoding:.ascii) ?? ""
    }
    static func bytes(_ n:Int,_ count:Int)->Data { Data((0..<count).map { UInt8((n >> ($0*8))&255) }) }
    static func size(_ w:Int,_ h:Int)throws {
        guard w>0 && h>0 && w<=dimensionLimit && h<=dimensionLimit && w<=pixelLimit/h else { throw AvatarPrototypeError.limit }
    }
}

/// One cursor plus current/previous descriptor. No per-frame metadata array.
final class AvatarPrototypeWebPIndex {
    struct Frame { let x:Int,y:Int,w:Int,h:Int,delay:Double,dispose:Bool,replace:Bool,payload:Range<Int>,alpha:Bool }
    let data:Data,width:Int,height:Int,count:Int,iterations:Int?,orientation:Int
    let profile:Range<Int>?
    private let end:Int
    private var offset=12
    private(set) var index=0
    init(_ original:Data)throws {
        guard original.count<=AvatarPrototypeBytes.inputLimit else { throw AvatarPrototypeError.limit }
        let d=original.startIndex==0 ? original:Data(original);guard d.count>=30,try AvatarPrototypeBytes.tag(d,0)=="RIFF",try AvatarPrototypeBytes.tag(d,8)=="WEBP" else { throw AvatarPrototypeError.invalid }
        let end=try AvatarPrototypeBytes.u(d,4,4)+8;guard end<=d.count && end>=30 else { throw AvatarPrototypeError.invalid }
        var p=12,w=0,h=0,loop:Int?,count=0,profile:Range<Int>?,orientation=1
        while p<end {
            try Task.checkCancellation()
            let (kind,body,stop,next)=try Self.chunk(d,p,end)
            switch kind {
            case "VP8X":
                guard p==12 && stop-body==10 && d[body]&2 != 0 && d[body]&0xc1==0 else { throw AvatarPrototypeError.invalid }
                guard try AvatarPrototypeBytes.u(d,body+1,3)==0 else { throw AvatarPrototypeError.invalid }
                w=try AvatarPrototypeBytes.u(d,body+4,3)+1;h=try AvatarPrototypeBytes.u(d,body+7,3)+1;try AvatarPrototypeBytes.size(w,h)
            case "ANIM":
                guard w>0 && loop==nil && count==0 && stop-body==6 else { throw AvatarPrototypeError.invalid };loop=try AvatarPrototypeBytes.u(d,body+4,2)
            case "ANMF":
                guard loop != nil else { throw AvatarPrototypeError.invalid }
                _ = try Self.frame(d,body,stop,w,h);count += 1
            case "ICCP":
                guard profile==nil && count==0 else { throw AvatarPrototypeError.invalid };profile=p..<next
            case "EXIF": orientation=try Self.exifOrientation(d,body..<stop)
            default: break // RIFF unknown chunks are bounded and skipped.
            }
            p=next
        }
        guard count>0,let loop else { throw AvatarPrototypeError.invalid }
        data=d;self.width=w;self.height=h;self.count=count;self.iterations=loop==0 ? nil:loop
        self.end=end;self.profile=profile;self.orientation=orientation
    }
    private static func chunk(_ d:Data,_ p:Int,_ end:Int)throws->(String,Int,Int,Int) {
        guard end-p>=8 else { throw AvatarPrototypeError.invalid }
        let n=try AvatarPrototypeBytes.u(d,p+4,4),start=p+8
        guard n<=end-start && n+n%2<=end-start else { throw AvatarPrototypeError.invalid }
        return (try AvatarPrototypeBytes.tag(d,p),start,start+n,start+n+n%2)
    }
    private static func frame(_ d:Data,_ start:Int,_ stop:Int,_ w:Int,_ h:Int)throws->Frame {
        guard stop-start>=16 else { throw AvatarPrototypeError.invalid }
        let x=try AvatarPrototypeBytes.u(d,start,3)*2,y=try AvatarPrototypeBytes.u(d,start+3,3)*2
        let fw=try AvatarPrototypeBytes.u(d,start+6,3)+1,fh=try AvatarPrototypeBytes.u(d,start+9,3)+1,flags=d[start+15]
        guard x<w && y<h && fw<=w-x && fh<=h-y && flags&0xfc==0 else { throw AvatarPrototypeError.invalid }
        var p=start+16,pixels=false,alpha=false
        while p<stop {
            let (kind,body,end,next)=try chunk(d,p,stop)
            if kind=="ALPH" { guard !pixels && !alpha && end>body else { throw AvatarPrototypeError.invalid };alpha=true }
            else if kind=="VP8 " || kind=="VP8L" {
                guard !pixels && end>body && !(kind=="VP8L" && alpha) else { throw AvatarPrototypeError.invalid };pixels=true
                if kind=="VP8L" && end-body>=5 { alpha=d[body+4]&0x10 != 0 }
            }
            p=next
        }
        guard pixels else { throw AvatarPrototypeError.invalid }
        return Frame(x:x,y:y,w:fw,h:fh,delay:Double(try AvatarPrototypeBytes.u(d,start+12,3))/1000,dispose:flags&1 != 0,replace:flags&2 != 0,payload:(start+16)..<stop,alpha:alpha)
    }
    private static func exifOrientation(_ d:Data,_ range:Range<Int>)throws->Int {
        var base=range.lowerBound
        if range.count>=6 && Array(d[base..<(base+6)])==[69,120,105,102,0,0] { base += 6 }
        guard range.upperBound-base>=8 else { throw AvatarPrototypeError.invalid }
        let little=d[base]==73 && d[base+1]==73,big=d[base]==77 && d[base+1]==77
        guard little || big else { throw AvatarPrototypeError.invalid }
        func number(_ p:Int,_ n:Int)throws->Int {
            guard p>=base && p<=range.upperBound-n else { throw AvatarPrototypeError.invalid }
            if little { return try AvatarPrototypeBytes.u(d,p,n) }
            var result=0;for i in 0..<n { result=(result<<8)|Int(d[p+i]) };return result
        }
        guard try number(base+2,2)==42 else { throw AvatarPrototypeError.invalid }
        let ifd=try number(base+4,4)+base,count=try number(ifd,2)
        guard count<=(range.upperBound-ifd-2)/12 else { throw AvatarPrototypeError.invalid }
        for i in 0..<count {
            let p=ifd+2+i*12
            if try number(p,2)==0x112 {
                guard try number(p+2,2)==3 && number(p+4,4)==1 else { throw AvatarPrototypeError.invalid }
                let orientation=try number(p+8,2);guard (1...8).contains(orientation) else { throw AvatarPrototypeError.invalid };return orientation
            }
        }
        return 1
    }
    func rewind() { offset=12;index=0 }
    func next()throws->Frame? {
        while offset<end {
            try Task.checkCancellation()
            let (kind,body,stop,next)=try Self.chunk(data,offset,end);offset=next
            if kind=="ANMF" { index += 1;return try Self.frame(data,body,stop,width,height) }
        }
        return nil
    }
    func still(_ f:Frame)->Data {
        var result=Data("RIFF".utf8);result.append(AvatarPrototypeBytes.bytes(4+18+(profile?.count ?? 0)+f.payload.count,4));result.append(Data("WEBPVP8X".utf8))
        result.append(AvatarPrototypeBytes.bytes(10,4));result.append(contentsOf:[UInt8((f.alpha ? 16:0)|(profile != nil ? 32:0)),0,0,0]);result.append(AvatarPrototypeBytes.bytes(f.w-1,3));result.append(AvatarPrototypeBytes.bytes(f.h-1,3))
        if let profile { result.append(data[profile]) };result.append(data[f.payload]);return result
    }
}

/// The canvas is the only persistent pixel buffer. File mode uses an unlinked,
/// private temporary file and at most one 64-row patch stripe in process memory.
final class AvatarPrototypeCanvas {
    enum Mode:String { case ram, diskCG="disk-cg", diskArea="disk-area", diskCGUncached="disk-cg-uncached" }
    let width:Int,height:Int,mode:Mode
    private let pointer:UnsafeMutableRawPointer?,fd:Int32
    var bytes:Int { width*height*4 }
    private(set) var ioReadBytes=0,ioWriteBytes=0
    private(set) var largestProviderRequest=0
    init(width:Int,height:Int,mode:Mode)throws {
        try AvatarPrototypeBytes.size(width,height);self.width=width;self.height=height;self.mode=mode
        if mode == .ram {
            guard let p=calloc(width*height,4) else { throw AvatarPrototypeError.io };pointer=p;fd = -1
        } else {
            var path=Array((NSTemporaryDirectory()+"avatar-stream-XXXXXX").utf8CString)
            let fd=mkstemp(&path);guard fd>=0 else { throw AvatarPrototypeError.io }
            guard unlink(path)==0 && fchmod(fd,0o600)==0 && ftruncate(fd,off_t(width*height*4))==0 else { close(fd);throw AvatarPrototypeError.io }
            if mode == .diskCGUncached { guard fcntl(fd,F_NOCACHE,1)==0 && fcntl(fd,F_RDAHEAD,0)==0 else { close(fd);throw AvatarPrototypeError.io } }
            self.fd=fd;pointer=nil
        }
    }
    deinit { if let pointer { free(pointer) };if fd>=0 { close(fd) } }
    private func read(_ p:UnsafeMutableRawPointer,_ count:Int,_ offset:Int)throws {
        guard offset>=0 && count>=0 && offset<=bytes-count else { throw AvatarPrototypeError.io }
        if let pointer { memcpy(p,pointer.advanced(by:offset),count);return }
        var done=0;while done<count { let n=pread(fd,p.advanced(by:done),count-done,off_t(offset+done));if n<0 && errno==EINTR { continue };guard n>0 else { throw AvatarPrototypeError.io };done += n };ioReadBytes += count
    }
    private func write(_ p:UnsafeRawPointer,_ count:Int,_ offset:Int)throws {
        if let pointer { memcpy(pointer.advanced(by:offset),p,count);return }
        var done=0;while done<count { let n=pwrite(fd,p.advanced(by:done),count-done,off_t(offset+done));if n<0 && errno==EINTR { continue };guard n>0 else { throw AvatarPrototypeError.io };done += n };ioWriteBytes += count
    }
    func clear(x:Int,y:Int,w:Int,h:Int)throws {
        let zero=Data(repeating:0,count:w*4)
        try zero.withUnsafeBytes { p in for row in y..<(y+h) { try write(p.baseAddress!,w*4,(row*width+x)*4) } }
    }
    func blend(_ image:CGImage,_ f:AvatarPrototypeWebPIndex.Frame)throws {
        if let pointer {
            guard let c=CGContext(data:pointer,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AvatarPrototypeError.io }
            let rect=CGRect(x:f.x,y:height-f.y-f.h,width:f.w,height:f.h)
            if f.replace { c.clear(rect) };c.interpolationQuality = .none;c.draw(image,in:rect);return
        }
        for y in stride(from:0,to:f.h,by:64) {
            try Task.checkCancellation()
            try autoreleasepool {
                let h=min(64,f.h-y);var stripe=Data(repeating:0,count:f.w*h*4)
                try stripe.withUnsafeMutableBytes { p in
                    if !f.replace { for row in 0..<h { try read(p.baseAddress!.advanced(by:row*f.w*4),f.w*4,((f.y+y+row)*width+f.x)*4) } }
                    guard let c=CGContext(data:p.baseAddress,width:f.w,height:h,bitsPerComponent:8,bytesPerRow:f.w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AvatarPrototypeError.io }
                    c.interpolationQuality = .none;c.draw(image,in:CGRect(x:0,y:y+h-f.h,width:f.w,height:f.h))
                    for row in 0..<h { try write(p.baseAddress!.advanced(by:row*f.w*4),f.w*4,((f.y+y+row)*width+f.x)*4) }
                }
            }
        }
    }
    func hash()throws->String {
        var digest=SHA256(),chunk=Data(repeating:0,count:min(bytes,256*1024)),offset=0
        while offset<bytes { let n=min(chunk.count,bytes-offset);try chunk.withUnsafeMutableBytes { try read($0.baseAddress!,n,offset) };digest.update(data:chunk.prefix(n));offset += n }
        return digest.finalize().map { String(format:"%02x",$0) }.joined()
    }
    func preview(side:Int=256,orientation:Int=1)throws->Data {
        let side=min(side,width,height)
        var pixels:Data
        if mode == .diskArea { pixels=try area(side) }
        else {
            var callbacks=CGDataProviderDirectCallbacks(version:0,getBytePointer:{ info in
                guard let info else { return nil };return Unmanaged<AvatarPrototypeCanvas>.fromOpaque(info).takeUnretainedValue().pointer.map(UnsafeRawPointer.init)
            },releaseBytePointer:{ _,_ in },getBytesAtPosition:{ info,out,position,count in
                guard let info else { return 0 };let canvas=Unmanaged<AvatarPrototypeCanvas>.fromOpaque(info).takeUnretainedValue()
                canvas.largestProviderRequest=max(canvas.largestProviderRequest,count)
                do { let n=min(count,canvas.bytes-Int(position));guard n>0 else { return 0 };try canvas.read(out,n,Int(position));return n } catch { return 0 }
            },releaseInfo:nil)
            guard let provider=CGDataProvider(directInfo:Unmanaged.passUnretained(self).toOpaque(),size:off_t(bytes),callbacks:&callbacks),
                let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { throw AvatarPrototypeError.io }
            pixels=Data(repeating:0,count:side*side*4)
            try pixels.withUnsafeMutableBytes { p in
                guard let c=CGContext(data:p.baseAddress,width:side,height:side,bitsPerComponent:8,bytesPerRow:side*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AvatarPrototypeError.io }
                let scale=Double(side)/Double(min(width,height)),w=Double(width)*scale,h=Double(height)*scale
                c.interpolationQuality = .high;c.draw(image,in:CGRect(x:(Double(side)-w)/2,y:(Double(side)-h)/2,width:w,height:h))
            }
        }
        guard orientation != 1 else { return pixels }
        var result=Data(repeating:0,count:pixels.count)
        for y in 0..<side { for x in 0..<side {
            let point:(Int,Int)
            switch orientation {case 2:point=(side-1-x,y);case 3:point=(side-1-x,side-1-y);case 4:point=(x,side-1-y);case 5:point=(y,x);case 6:point=(side-1-y,x);case 7:point=(side-1-y,side-1-x);case 8:point=(y,side-1-x);default:point=(x,y)}
            for c in 0..<4 { result[(point.1*side+point.0)*4+c]=pixels[(y*side+x)*4+c] }
        } };return result
    }
    private func area(_ side:Int)throws->Data {
        // Post-composition area resampling. It preserves full-resolution alpha
        // state, but its kernel differs from CoreGraphics' high-quality filter.
        let crop=min(width,height),x0=(width-crop)/2,y0=(height-crop)/2
        var sums=[UInt64](repeating:0,count:side*side*4),row=Data(repeating:0,count:crop*4)
        for y in 0..<crop {
            try Task.checkCancellation();try row.withUnsafeMutableBytes { try read($0.baseAddress!,crop*4,((y+y0)*width+x0)*4) }
            let firstY=y*side/crop,lastY=min(side-1,((y+1)*side-1)/crop)
            for x in 0..<crop {
                let firstX=x*side/crop,lastX=min(side-1,((x+1)*side-1)/crop)
                for oy in firstY...lastY { let wy=min((y+1)*side,(oy+1)*crop)-max(y*side,oy*crop)
                    for ox in firstX...lastX { let weight=UInt64(wy*(min((x+1)*side,(ox+1)*crop)-max(x*side,ox*crop)))
                        for c in 0..<4 { sums[(oy*side+ox)*4+c] += UInt64(row[x*4+c])*weight }
                    }
                }
            }
        }
        let divisor=UInt64(crop*crop);return Data(sums.map { UInt8(min(255,($0+divisor/2)/divisor)) })
    }
}

final class AvatarPrototypeWebPPlayer {
    let stream:AvatarPrototypeWebPIndex,canvas:AvatarPrototypeCanvas
    var phase:((String)->Void)?
    private let honorOrientation:Bool
    private var previous:AvatarPrototypeWebPIndex.Frame?
    init(_ data:Data,mode:AvatarPrototypeCanvas.Mode,honorOrientation:Bool=true)throws {
        stream=try AvatarPrototypeWebPIndex(data);canvas=try AvatarPrototypeCanvas(width:stream.width,height:stream.height,mode:mode)
        self.honorOrientation=honorOrientation
    }
    func next()throws->Data? {
        guard let f=try stream.next() else { return nil }
        if let previous,previous.dispose { try canvas.clear(x:previous.x,y:previous.y,w:previous.w,h:previous.h) }
        try autoreleasepool {
            phase?("before-decode")
            let encoded=stream.still(f)
            guard let source=CGImageSourceCreateWithData(encoded as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:false] as CFDictionary),image.width==f.w && image.height==f.h else { throw AvatarPrototypeError.invalid }
            phase?("lazy-image-created")
            try canvas.blend(image,f)
            phase?("after-blend")
        }
        phase?("patch-released")
        previous=f;let result=try canvas.preview(orientation:honorOrientation ? stream.orientation:1)
        phase?("after-preview");return result
    }
}

/// GIF descriptor scan avoids CGImageSourceCopyProperties's whole FrameInfo
/// array; only requested frames use CopyPropertiesAtIndex / thumbnail decode.
final class AvatarPrototypeGIFPlayer {
    let data:Data,width:Int,height:Int,count:Int,iterations:Int?
    private let source:CGImageSource
    private var index=0
    init(_ original:Data)throws {
        guard original.count<=AvatarPrototypeBytes.inputLimit else { throw AvatarPrototypeError.limit }
        let d=original.startIndex==0 ? original:Data(original);guard d.count>=13,String(bytes:d.prefix(6),encoding:.ascii).map({$0=="GIF89a" || $0=="GIF87a"})==true else { throw AvatarPrototypeError.invalid }
        let w=try AvatarPrototypeBytes.u(d,6,2),h=try AvatarPrototypeBytes.u(d,8,2);try AvatarPrototypeBytes.size(w,h)
        var p=13+(d[10]&128 != 0 ? 3*(1<<(Int(d[10]&7)+1)):0),count=0,loops:Int?
        func blocks()throws {
            while true { guard p<d.count else { throw AvatarPrototypeError.invalid };let size=Int(d[p]);p += 1;guard size<=d.count-p else { throw AvatarPrototypeError.invalid };p += size;if size==0 { return } }
        }
        while p<d.count {
            try Task.checkCancellation();let marker=d[p];p += 1
            if marker==0x3b { break }
            if marker==0x21 {
                guard p<d.count else { throw AvatarPrototypeError.invalid };let label=d[p];p += 1
                if label==0xff && p+17<=d.count && d[p]==11 && String(bytes:d[(p+1)..<(p+12)],encoding:.ascii)=="NETSCAPE2.0" && d[p+12]==3 && d[p+13]==1 { loops=try AvatarPrototypeBytes.u(d,p+14,2) }
                try blocks()
            } else if marker==0x2c {
                guard p+9<d.count else { throw AvatarPrototypeError.invalid }
                let x=try AvatarPrototypeBytes.u(d,p,2),y=try AvatarPrototypeBytes.u(d,p+2,2),fw=try AvatarPrototypeBytes.u(d,p+4,2),fh=try AvatarPrototypeBytes.u(d,p+6,2),packed=d[p+8]
                guard fw>0 && fh>0 && x<w && y<h && fw<=w-x && fh<=h-y else { throw AvatarPrototypeError.invalid }
                p += 9+(packed&128 != 0 ? 3*(1<<(Int(packed&7)+1)):0)
                guard p<d.count else { throw AvatarPrototypeError.invalid };p += 1;try blocks();count += 1
            } else { throw AvatarPrototypeError.invalid }
        }
        guard count>0,let source=CGImageSourceCreateWithData(d as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),CGImageSourceGetCount(source)==count else { throw AvatarPrototypeError.invalid }
        data=d;width=w;height=h;self.count=count;iterations=loops.map { $0==0 ? nil:$0+1 } ?? 1;self.source=source
    }
    func next()throws->CGImage? {
        guard index<count else { return nil };try Task.checkCancellation()
        defer { CGImageSourceRemoveCacheAtIndex(source,index);index += 1 }
        return CGImageSourceCreateThumbnailAtIndex(source,index,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:256,kCGImageSourceShouldCache:false] as CFDictionary)
    }
}
