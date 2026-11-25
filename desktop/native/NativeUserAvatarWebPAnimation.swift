import Foundation
import CoreGraphics
import ImageIO

/// ImageIO's animated WebP path on the tested macOS version renders disposed
/// regions opaque black. Decode individual still-WebP frame payloads and perform
/// the two WebP blend/disposal operations in one bounded RGBA canvas instead.
final class NativeUserAvatarWebPAnimation {
    struct Descriptor {
        let x: Int, y: Int, width: Int, height: Int
        let delay: Double, dispose: Bool, replace: Bool, payload: Range<Int>, alpha: Bool
    }
    private let data: Data
    private let canvas: CGContext
    private let profile: Range<Int>?
    let width: Int, height: Int, iterations: Int?
    let frameCount: Int
    private let end: Int
    private var offset = 12, nextIndex = 0
    private var previous: Descriptor?
    private(set) var currentDelay: Double = 0.1

    init(data: Data) throws {
        typealias E = NativeUserAvatarAnimation.Failure
        guard data.count<=NativeUserAvatarAnimation.maximumInputBytes else { throw E.inputLimit }
        let data=data.startIndex == 0 ? data : Data(data)
        guard data.count >= 30, Self.tag(data,0) == "RIFF", Self.tag(data,8) == "WEBP" else { throw E.invalid }
        let end=Self.integer(data,4,4)+8
        guard end <= data.count && end >= 30 else { throw E.invalid }
        var offset=12, dimensions:(Int,Int)?, loop:Int?, profile:Range<Int>?, count=0
        while offset < end {
            try Task.checkCancellation()
            guard end-offset>=8 else { throw E.invalid }
            let tag=Self.tag(data,offset),size=Self.integer(data,offset+4,4),start=offset+8
            guard size<=end-start && size+size%2<=end-start else { throw E.invalid }
            let finish=start+size
            switch tag {
            case "VP8X":
                guard offset==12 && size==10 && dimensions==nil,
                      data[start]&0x02 != 0, data[start]&0xc1==0,
                      Self.integer(data,start+1,3)==0 else { throw E.invalid }
                let w=Self.integer(data,start+4,3)+1,h=Self.integer(data,start+7,3)+1
                guard w<=NativeUserAvatarAnimation.maximumDimension && h<=NativeUserAvatarAnimation.maximumDimension && w*h<=NativeUserAvatarAnimation.maximumCanvasPixels else { throw E.canvasLimit }
                dimensions=(w,h)
            case "ANIM":
                guard size==6 && dimensions != nil && loop==nil && count==0 else { throw E.invalid }
                loop=Self.integer(data,start+4,2)
                // Browser/libwebp compositing clears to transparent, independent
                // of the optional suggested ANIM background color.
            case "ICCP":
                guard profile==nil && dimensions != nil && count==0 else { throw E.invalid }
                profile=offset..<(finish+size%2)
            case "ANMF":
                guard size>=16,let (w,h)=dimensions,loop != nil else { throw E.invalid }
                _ = try Self.descriptor(data,start,finish,w,h);count += 1
            case "EXIF":
                break // Source Chromium ignores EXIF on animated WebP; RIFF bounds are checked above.
            default: break // Bounded unknown RIFF metadata chunks are skippable.
            }
            offset=finish+size%2
        }
        guard let (w,h)=dimensions,let loop, count>0,
              let canvas=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw E.invalid }
        self.data=data;self.width=w;self.height=h;self.frameCount=count;self.profile=profile;self.canvas=canvas;self.end=end
        iterations=loop==0 ? nil:loop;canvas.clear(CGRect(x:0,y:0,width:w,height:h))
    }
    private static func tag(_ data:Data,_ offset:Int)->String { String(bytes:data[offset..<(offset+4)],encoding:.ascii) ?? "" }
    private static func integer(_ data:Data,_ offset:Int,_ count:Int)->Int {
        var value=0;for i in 0..<count { value |= Int(data[offset+i]) << (i*8) };return value
    }
    private static func integer(_ value:Int,_ count:Int)->Data { Data((0..<count).map { UInt8((value >> ($0*8))&255) }) }
    private func rectangle(_ f:Descriptor)->CGRect { CGRect(x:f.x,y:height-f.y-f.height,width:f.width,height:f.height) }

    /// Validation scans the bounded input once, retaining no frame array. Each
    /// playback pass reads descriptors again and keeps only the previous one.
    private static func descriptor(_ data:Data,_ start:Int,_ finish:Int,_ w:Int,_ h:Int)throws->Descriptor {
        typealias E = NativeUserAvatarAnimation.Failure
        guard finish-start>=16 else { throw E.invalid }
        let x=integer(data,start,3)*2,y=integer(data,start+3,3)*2
        let fw=integer(data,start+6,3)+1,fh=integer(data,start+9,3)+1,flags=data[start+15]
        guard x<w && y<h && fw<=w-x && fh<=h-y && flags&0xfc==0 else { throw E.invalid }
        var chunk=start+16,hasPixels=false,alpha=false
        while chunk<finish {
            try Task.checkCancellation()
            guard finish-chunk>=8 else { throw E.invalid }
            let kind=tag(data,chunk),length=integer(data,chunk+4,4),body=chunk+8
            guard length<=finish-body && length+length%2<=finish-body else { throw E.invalid }
            if kind=="ALPH" { guard !alpha && !hasPixels && length>0 else { throw E.invalid };alpha=true }
            else if kind=="VP8 " || kind=="VP8L" {
                guard !hasPixels && length>0 && !(kind=="VP8L" && alpha) else { throw E.invalid };hasPixels=true
                if kind=="VP8L" && length>=5 { alpha=data[body+4]&0x10 != 0 }
            } else { throw E.invalid }
            chunk=body+length+length%2
        }
        guard hasPixels else { throw E.invalid }
        return Descriptor(x:x,y:y,width:fw,height:fh,delay:Double(integer(data,start+12,3))/1000,
            dispose:flags&1 != 0,replace:flags&2 != 0,payload:(start+16)..<finish,alpha:alpha)
    }
    private static func orientation(_ data:Data,_ range:Range<Int>)throws->Int {
        typealias E = NativeUserAvatarAnimation.Failure
        var base=range.lowerBound
        if range.count>=6 && Array(data[base..<(base+6)])==[69,120,105,102,0,0] { base += 6 }
        guard range.upperBound-base>=8 else { throw E.invalid }
        let little=data[base]==73 && data[base+1]==73,big=data[base]==77 && data[base+1]==77
        guard little || big else { throw E.invalid }
        func number(_ p:Int,_ n:Int)throws->Int {
            guard p>=base && p<=range.upperBound-n else { throw E.invalid }
            if little { return integer(data,p,n) }
            var result=0;for i in 0..<n { result=(result<<8)|Int(data[p+i]) };return result
        }
        guard try number(base+2,2)==42 else { throw E.invalid }
        let ifd=try number(base+4,4)+base,count=try number(ifd,2)
        guard count<=(range.upperBound-ifd-2)/12 else { throw E.invalid }
        for i in 0..<count { let p=ifd+2+i*12
            if try number(p,2)==0x112 {
                guard try number(p+2,2)==3 && number(p+4,4)==1 else { throw E.invalid }
                let value=try number(p+8,2);guard (1...8).contains(value) else { throw E.invalid };return value
            }
        }
        return 1
    }
    private func nextDescriptor()throws->Descriptor {
        while offset<end {
            try Task.checkCancellation()
            guard end-offset>=8 else { throw NativeUserAvatarAnimation.Failure.invalid }
            let kind=Self.tag(data,offset),size=Self.integer(data,offset+4,4),start=offset+8
            guard size<=end-start && size+size%2<=end-start else { throw NativeUserAvatarAnimation.Failure.invalid }
            offset=start+size+size%2
            if kind=="ANMF" { return try Self.descriptor(data,start,start+size,width,height) }
        }
        throw NativeUserAvatarAnimation.Failure.invalid
    }

    func image(at index:Int)throws->CGImage {
        typealias E = NativeUserAvatarAnimation.Failure
        try Task.checkCancellation()
        guard index>=0 && index<frameCount else { throw E.invalid }
        if index==0 { offset=12;nextIndex=0;previous=nil;canvas.clear(CGRect(x:0,y:0,width:width,height:height)) }
        guard index==nextIndex else { throw E.invalid }
        let frame=try nextDescriptor()
        if let previous,previous.dispose { canvas.clear(rectangle(previous)) }
        let profileBytes=profile.map { $0.count } ?? 0
        var encoded=Data("RIFF".utf8)
        encoded.append(Self.integer(4+18+profileBytes+frame.payload.count,4));encoded.append(Data("WEBPVP8X".utf8))
        encoded.append(Self.integer(10,4));encoded.append(contentsOf:[UInt8((frame.alpha ? 16:0)|(profile != nil ? 32:0)),0,0,0])
        encoded.append(Self.integer(frame.width-1,3));encoded.append(Self.integer(frame.height-1,3))
        if let profile { encoded.append(data[profile]) };encoded.append(data[frame.payload])
        guard let source=CGImageSourceCreateWithData(encoded as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:false,kCGImageSourceShouldAllowFloat:false] as CFDictionary),
              image.width==frame.width && image.height==frame.height else { throw E.invalid }
        try Task.checkCancellation()
        let rect=rectangle(frame)
        if frame.replace { canvas.clear(rect) }
        canvas.interpolationQuality = .none;canvas.draw(image,in:rect)
        guard let composed=canvas.makeImage() else { throw E.invalid }
        previous=frame;nextIndex += 1;currentDelay=frame.delay
        return composed
    }
}
