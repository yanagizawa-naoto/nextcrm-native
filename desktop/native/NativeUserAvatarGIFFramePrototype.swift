import Foundation
import CoreGraphics
import ImageIO

/// Isolated prototype: only one compressed GIF image reaches ImageIO.
final class NativeUserAvatarGIFFramePrototype {
    enum Failure:Error {case invalid,limit}
    struct Descriptor {let x:Int,y:Int,width:Int,height:Int,range:Range<Int>,control:Range<Int>?,disposal:Int,delay:Double}
    private let data:Data,headerEnd:Int,canvas:CGContext
    let width:Int,height:Int,frameCount:Int,iterations:Int?
    private var cursor:Int,previous:Descriptor?,restore:CGImage?,nextIndex=0
    private(set)var delay=0.1
    init(data:Data)throws {
        let d=data.startIndex==0 ? data:Data(data)
        guard d.count>=13,d.count<=4194304,["GIF89a","GIF87a"].contains(String(bytes:d.prefix(6),encoding:.ascii) ?? "")else{throw Failure.invalid}
        let w=Self.word(d,6),h=Self.word(d,8),end=13+(d[10]&128 != 0 ? 3*(1<<(Int(d[10]&7)+1)):0)
        guard w>0,h>0,w<=1024,h<=1024,end<=d.count else{throw Failure.limit}
        var p=end,count=0,loop:Int?,trailer=false
        while p<d.count {
            if d[p]==0x3b {trailer=true;break}
            if let _ = try Self.next(d,&p,w,h,&loop) {count += 1}else{trailer=true;break}
        }
        guard trailer,count>0,let canvas=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{throw Failure.invalid}
        self.data=d;headerEnd=end;cursor=end;width=w;height=h;frameCount=count;iterations=loop.map{$0==0 ? nil:$0+1} ?? 1;self.canvas=canvas
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
