import Foundation
import CoreGraphics
import CryptoKit

@main enum NativeUserAvatarGIFCompositionTests {
    struct Failure:Error {let text:String}
    static func sha(_ image:CGImage)->String {
        var bytes=[UInt8](repeating:0,count:image.width*image.height*4)
        bytes.withUnsafeMutableBytes{p in let c=CGContext(data:p.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))}
        return SHA256.hash(data:Data(bytes)).map{String(format:"%02x",$0)}.joined()
    }
    static func main()throws {
        let native=URL(fileURLWithPath:CommandLine.arguments[1]),reference=try JSONSerialization.jsonObject(with:Data(contentsOf:native.appendingPathComponent("build/user-avatar-gif-frame-reference.json"))) as! [String:Any]
        var checks=0
        for c in reference["browserCases"] as! [[String:Any]] {
            let name=c["name"] as! String,expected=c["nativeFrames"] as! [String],data=try Data(contentsOf:native.appendingPathComponent("build/avatar-gif-frame/"+name+".gif"))
            let decoder=try NativeUserAvatarAnimation(data:data)
            guard decoder.frameCount==expected.count else{throw Failure(text:name+" frame count")};checks += 1
            for index in expected.indices {try autoreleasepool {
                guard let f=try decoder.nextFrame(),f.index==index,sha(f.image)==expected[index]else{throw Failure(text:name+" full RGBA frame \(index)")};checks += 1
            }}
            guard try decoder.nextFrame()==nil else{throw Failure(text:name+" end")};checks += 1
        }
        let report:[String:Any]=["checks":checks,"cases":(reference["browserCases"] as! [Any]).count,"scope":"Current production NativeUserAvatarAnimation, full center-cropped RGBA against installed Chrome ImageDecoder; disposal 0/1/2/3/7, transparent/partial/local palette/interlace, no GCE." ]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:native.appendingPathComponent("build/user-avatar-gif-composition-native.json"));print("GIF composition: \(checks) checks passed")
    }
}
