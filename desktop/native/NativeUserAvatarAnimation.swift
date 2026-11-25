import Foundation
import CoreGraphics
import ImageIO

/// A serial, pull-based decoder. It never builds an array of decoded frames.
/// Call from one task only; cancellation is checked around each ImageIO call.
/// ImageIO's private composition buffers are not a hard process-memory budget.
final class NativeUserAvatarAnimation {
    static let maximumInputBytes = 4 * 1024 * 1024
    #if AVATAR_DECODER_WORKER
    static let maximumCanvasPixels = 16_777_216
    static let maximumDimension = 16_384
    #else
    static let maximumCanvasPixels = 1_048_576
    static let maximumDimension = 1024
    #endif
    static let outputSide = 256

    enum Failure: Error, LocalizedError, Equatable {
        case invalid, inputLimit, canvasLimit, metadataLimit, unsupported, orientation
        var errorDescription: String? {
            switch self {
            case .invalid: return "動く写真を読み込めないため、静止画を表示しています。"
            case .inputLimit: return "写真が4 MiBを超えるため、静止画を表示しています。"
            case .canvasLimit: return "動く写真は1024×1024ピクセル以内に対応しています。元画像を保持し、静止画を表示しています。"
            case .metadataLimit: return "写真の色情報が大きすぎるため、元画像を保持して静止画を表示しています。"
            case .unsupported: return "この画像形式は静止画で表示しています。"
            case .orientation: return "回転情報付きの動くWebPは静止画で表示しています。元画像は保持しています。"
            }
        }
    }
    struct Frame {
        let image: CGImage
        let index: Int
        let delay: TimeInterval
    }
    private let source: CGImageSource?
    private var gif: NativeUserAvatarGIFFrameDecoder?
    private var webP: NativeUserAvatarWebPAnimation?
    private var apng: NativeUserAvatarAPNGAnimation?
    /// APNG may contain a default PNG poster that is not an animation frame.
    /// Even a single-frame animation must replace that poster once visible.
    /// Animated WebP also draws once: ImageIO may have oriented its static
    /// thumbnail, while the source browser ignores EXIF for this format.
    var requiresInitialFrameDisplay:Bool {webP != nil || (apng.map{!$0.defaultIsFirstFrame} ?? false)}
    let frameCount: Int
    /// nil means infinite. GIF's stored repeat count is converted to total
    /// passes; WebP already stores total passes.
    let iterations: Int?
    let compressedBytes: Int
    private(set) var decodedFrameCount = 0
    private var index = 0, completedIterations = 0

    init(data: Data) throws {
        try Task.checkCancellation()
        guard data.count <= Self.maximumInputBytes else { throw Failure.inputLimit }
        compressedBytes = data.count
        let header=Array(data.prefix(21)),signature=String(bytes:header.prefix(6),encoding:.ascii)
        if header.count>=21 && String(bytes:header.prefix(4),encoding:.ascii)=="RIFF"
            && String(bytes:header[8..<12],encoding:.ascii)=="WEBP"
            && String(bytes:header[12..<16],encoding:.ascii)=="VP8X" && header[20]&2 != 0 {
            // Do not create a whole-animation ImageIO source for WebP. Its
            // global properties include a FrameInfo array for every frame.
            let decoder=try NativeUserAvatarWebPAnimation(data:data)
            webP=decoder;source=nil;frameCount=decoder.frameCount;iterations=decoder.iterations
            return
        }
        if signature=="GIF89a" || signature=="GIF87a" {
            let decoder=try NativeUserAvatarGIFFrameDecoder(data:data)
            gif=decoder;source=nil;frameCount=decoder.frameCount;iterations=decoder.iterations
            return
        }
        if header.starts(with:[137,80,78,71,13,10,26,10]) {
            do {
                let decoder=try NativeUserAvatarAPNGAnimation(data:data)
                apng=decoder;source=nil;frameCount=decoder.frameCount;iterations=decoder.iterations
                return
            } catch let error as NativeUserAvatarAPNGAnimation.Failure {
                switch error {
                case .inputLimit:throw Failure.inputLimit
                case .canvasLimit:throw Failure.canvasLimit
                case .metadataLimit:throw Failure.metadataLimit
                case .staticPNG,.unsupported:throw Failure.unsupported
                case .invalid:throw Failure.invalid
                }
            }
        }
        guard !data.isEmpty,let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,let type=CGImageSourceGetType(source) as String? else { throw Failure.invalid }
        guard type=="org.webmproject.webp" else { throw Failure.unsupported }
        self.source=source
        let count=CGImageSourceGetCount(source)
        // A still WebP needs only its sole image's metadata, not FrameInfo.
        guard count==1,let p=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any],
              let w=p[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let h=p[kCGImagePropertyPixelHeight as String] as? NSNumber else { throw Failure.invalid }
        try Self.validateSize(w.intValue,h.intValue);frameCount=1;iterations=1
    }

    private static func validateSize(_ width: Int, _ height: Int) throws {
        guard width > 0 && height > 0 else { throw Failure.invalid }
        guard width <= maximumDimension, height <= maximumDimension,
              width * height <= maximumCanvasPixels else { throw Failure.canvasLimit }
    }

    /// Browser-like protection against zero/sub-11ms frame spins. Encoded long
    /// delays are retained (GIF/WebP's maximum representable delay is < 24h).
    static func delay(_ raw: Double?) -> TimeInterval {
        guard let value = raw, value.isFinite, value >= 0.011 else { return 0.1 }
        return min(value, 86400)
    }

    func nextFrame() throws -> Frame? {
        try Task.checkCancellation()
        guard iterations.map({ completedIterations < $0 }) ?? true else { return nil }
        if let webP {
            let frameIndex=index,composed=try webP.image(at:frameIndex),image=try Self.rasterize(composed)
            try Task.checkCancellation();advance()
            return Frame(image:image,index:frameIndex,delay:Self.delay(webP.currentDelay))
        }
        if let gif {
            let frameIndex=index,composed=try gif.image(at:frameIndex),image=try Self.rasterize(composed)
            try Task.checkCancellation();advance()
            return Frame(image:image,index:frameIndex,delay:Self.delay(gif.delay))
        }
        if let apng {
            do {
                guard let frame=try apng.nextFrame()else{return nil}
                let image=try Self.rasterize(frame.image)
                try Task.checkCancellation();advance()
                return Frame(image:image,index:frame.index,delay:Self.delay(frame.delay))
            }catch let error as NativeUserAvatarAPNGAnimation.Failure {
                if case .metadataLimit=error{throw Failure.metadataLimit}
                throw Failure.invalid
            }
        }
        guard let source,CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
              let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] else { throw Failure.invalid }
        let dictionary = props[kCGImagePropertyWebPDictionary as String] as? [String: Any] ?? [:]
        let raw = (dictionary[kCGImagePropertyWebPUnclampedDelayTime as String] as? NSNumber)
            ?? (dictionary[kCGImagePropertyWebPDelayTime as String] as? NSNumber)
        let frameIndex = index
        defer { CGImageSourceRemoveCacheAtIndex(source, frameIndex) }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.outputSide * 2,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: false
        ] as CFDictionary) else { throw Failure.invalid }
        try Task.checkCancellation()
        // Force a small independent bitmap; the displayed CGImage cannot retain
        // the source decoder, a full canvas, or a lazy decode provider.
        let image=try Self.rasterize(thumbnail)
        try Task.checkCancellation();advance()
        return Frame(image: image, index: frameIndex, delay: Self.delay(raw?.doubleValue))
    }
    private func advance() {
        decodedFrameCount += 1
        index += 1
        if index == frameCount { index = 0;if iterations != nil { completedIterations += 1 } }
    }
    private static func rasterize(_ thumbnail:CGImage)throws->CGImage {
        let side = min(Self.outputSide, thumbnail.width, thumbnail.height)
        guard side > 0, let context = CGContext(data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.invalid }
        let scale = max(CGFloat(side) / CGFloat(thumbnail.width), CGFloat(side) / CGFloat(thumbnail.height))
        let w = CGFloat(thumbnail.width) * scale, h = CGFloat(thumbnail.height) * scale
        context.interpolationQuality = .high
        context.draw(thumbnail, in: CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h))
        guard let image = context.makeImage() else { throw Failure.invalid }
        return image
    }
}

/// GIF image descriptors and GCE delays are scanned without retaining a frame
/// array. ImageIO sees only the current compressed image, so its private
/// per-frame metadata cannot accumulate across an arbitrarily long animation.
/// One canvas and an optional disposal-3 snapshot preserve browser composition.
private final class NativeUserAvatarGIFFrameDecoder {
    typealias Failure = NativeUserAvatarAnimation.Failure
    struct Descriptor {let x:Int,y:Int,width:Int,height:Int,range:Range<Int>,control:Range<Int>?,disposal:Int,delay:Double}
    private let data:Data,headerEnd:Int,canvas:CGContext
    let width:Int,height:Int,frameCount:Int,iterations:Int?
    private var cursor:Int,previous:Descriptor?,restore:CGImage?,nextIndex=0
    private(set)var delay=0.1
    init(data:Data)throws {
        let d=data.startIndex==0 ? data:Data(data)
        guard d.count>=13,d.count<=NativeUserAvatarAnimation.maximumInputBytes,["GIF89a","GIF87a"].contains(String(bytes:d.prefix(6),encoding:.ascii) ?? "")else{throw Failure.invalid}
        let w=Self.word(d,6),h=Self.word(d,8),end=13+(d[10]&128 != 0 ? 3*(1<<(Int(d[10]&7)+1)):0)
        guard w>0,h>0,end<=d.count else{throw Failure.invalid}
        guard w<=NativeUserAvatarAnimation.maximumDimension,h<=NativeUserAvatarAnimation.maximumDimension,
              w*h<=NativeUserAvatarAnimation.maximumCanvasPixels else{throw Failure.canvasLimit}
        var p=end,count=0,loop:Int?,trailer=false
        while p<d.count {
            if d[p]==0x3b {trailer=true;break}
            if let _ = try Self.next(d,&p,w,h,&loop) {count += 1}else{trailer=true;break}
        }
        guard trailer,count>0,let canvas=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{throw Failure.invalid}
        self.data=d;headerEnd=end;cursor=end;width=w;height=h;frameCount=count;iterations=loop == 0 ? nil:loop.map{$0+1} ?? 1;self.canvas=canvas
        canvas.clear(CGRect(x:0,y:0,width:w,height:h))
    }
    private static func word(_ d:Data,_ p:Int)->Int {Int(d[p])|Int(d[p+1])<<8}
    private static func blocks(_ d:Data,_ p:inout Int)throws {
        while true {try Task.checkCancellation();guard p<d.count else{throw Failure.invalid};let size=Int(d[p]);p += 1;guard size<=d.count-p else{throw Failure.invalid};p += size;if size==0{return}}
    }
    private static func next(_ d:Data,_ p:inout Int,_ w:Int,_ h:Int,_ loop:inout Int?)throws->Descriptor? {
        var control:Range<Int>?,disposal=0,delay=0.0
        while p<d.count {
            try Task.checkCancellation();let start=p,marker=d[p];p += 1
            if marker==0x3b{return nil}
            if marker==0x21 {
                guard p<d.count else{throw Failure.invalid};let label=d[p];p += 1
                if label==0xf9 {
                    guard p+6<=d.count,d[p]==4,d[p+5]==0 else{throw Failure.invalid}
                    control=start..<(p+6);disposal=Int((d[p+1]>>2)&7);delay=Double(word(d,p+2))/100
                }else if label==0xff && p+17<=d.count && d[p]==11 {
                    let app=String(bytes:d[(p+1)..<(p+12)],encoding:.ascii)
                    if (app=="NETSCAPE2.0" || app=="ANIMEXTS1.0") && d[p+12]==3 && d[p+13]==1 {loop=word(d,p+14)}
                }
                try blocks(d,&p)
            }else if marker==0x2c {
                guard p+9<d.count else{throw Failure.invalid}
                let x=word(d,p),y=word(d,p+2),fw=word(d,p+4),fh=word(d,p+6),packed=d[p+8]
                guard fw>0,fh>0,x<w,y<h,fw<=w-x,fh<=h-y else{throw Failure.invalid}
                p += 9+(packed&128 != 0 ? 3*(1<<(Int(packed&7)+1)):0)
                guard p<d.count else{throw Failure.invalid};p += 1;try blocks(d,&p)
                return Descriptor(x:x,y:y,width:fw,height:fh,range:start..<p,control:control,disposal:disposal,delay:delay)
            }else{throw Failure.invalid}
        }
        throw Failure.invalid
    }
    private func rect(_ d:Descriptor)->CGRect {CGRect(x:d.x,y:height-d.y-d.height,width:d.width,height:d.height)}
    func image(at index:Int)throws->CGImage {
        try Task.checkCancellation();guard index>=0,index<frameCount else{throw Failure.invalid}
        if index==0 {cursor=headerEnd;nextIndex=0;previous=nil;restore=nil;canvas.clear(CGRect(x:0,y:0,width:width,height:height))}
        guard index==nextIndex else{throw Failure.invalid}
        var unused:Int?;guard let f=try Self.next(data,&cursor,width,height,&unused)else{throw Failure.invalid}
        // Like the original browser, background disposal clears to transparent;
        // the logical-screen background color is not a canvas fill color.
        if let previous {
            if previous.disposal==2 {canvas.clear(rect(previous))}
            else if previous.disposal==3,let restore {canvas.setBlendMode(.copy);canvas.draw(restore,in:CGRect(x:0,y:0,width:width,height:height));canvas.setBlendMode(.normal)}
        }
        restore=nil
        if f.disposal==3 {restore=canvas.makeImage();guard restore != nil else{throw Failure.invalid}}
        var encoded=Data(data[..<headerEnd]);encoded[6]=UInt8(f.width&255);encoded[7]=UInt8(f.width>>8);encoded[8]=UInt8(f.height&255);encoded[9]=UInt8(f.height>>8)
        if let control=f.control {var c=Data(data[control]);c[3] &= 1;encoded.append(c)}
        let descriptorOffset=encoded.count;encoded.append(data[f.range]);for i in 1...4 {encoded[descriptorOffset+i]=0};encoded.append(0x3b)
        guard let source=CGImageSourceCreateWithData(encoded as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:false,kCGImageSourceShouldAllowFloat:false] as CFDictionary),image.width==f.width,image.height==f.height else{throw Failure.invalid}
        try Task.checkCancellation();canvas.interpolationQuality = .none;canvas.draw(image,in:rect(f));guard let composed=canvas.makeImage()else{throw Failure.invalid}
        previous=f;delay=f.delay;nextIndex += 1;return composed
    }
}
