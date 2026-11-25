import Foundation
import CoreGraphics
import ImageIO

@main enum NativeUserAvatarOrientationTests {
    static func pixels(_ image:CGImage)throws->[String:Any]{var d=Data(count:image.width*image.height*4);try d.withUnsafeMutableBytes{raw in guard let c=CGContext(data:raw.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{throw NativeUserAvatarAnimation.Failure.invalid};c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))};return["width":image.width,"height":image.height,"rgba":d.base64EncodedString()]}
    static func main()throws{
        let dir=URL(fileURLWithPath:CommandLine.arguments[1]),reference=try JSONSerialization.jsonObject(with:Data(contentsOf:dir.appendingPathComponent("reference.json")))as! [String:Any];var results:[[String:Any]]=[]
        for value in reference["cases"]as! [[String:Any]] {try autoreleasepool{
            let data=try Data(contentsOf:dir.appendingPathComponent(value["file"]as! String));var result:[String:Any]=["name":value["name"]!]
            if let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false]as CFDictionary) {
                let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil)as? [CFString:Any] ?? [:];result["imageIO"]=["count":CGImageSourceGetCount(source),"orientation":props[kCGImagePropertyOrientation] ?? NSNull(),"width":props[kCGImagePropertyPixelWidth] ?? NSNull(),"height":props[kCGImagePropertyPixelHeight] ?? NSNull()]
                if let untransformed=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:false,kCGImageSourceThumbnailMaxPixelSize:512,kCGImageSourceShouldCacheImmediately:true,kCGImageSourceShouldCache:false]as CFDictionary){result["untransformedThumbnail"]=try pixels(untransformed)}
                if let thumb=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:512,kCGImageSourceShouldCacheImmediately:true,kCGImageSourceShouldCache:false]as CFDictionary) {
                    result["thumbnail"]=try pixels(thumb)
                    let side=min(thumb.width,thumb.height),target=min(256,side)
                    if let cropped=thumb.cropping(to:CGRect(x:(thumb.width-side)/2,y:(thumb.height-side)/2,width:side,height:side)),let context=CGContext(data:nil,width:target,height:target,bitsPerComponent:8,bytesPerRow:target*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue){context.interpolationQuality = .high;context.draw(cropped,in:CGRect(x:0,y:0,width:target,height:target));if let image=context.makeImage(){result["canonicalThumbnail"]=try pixels(image)}}
                }
            }
            do{let decoder=try NativeUserAvatarWebPAnimation(data:data);var frames:[[String:Any]]=[];for i in 0..<decoder.frameCount{var frame=try pixels(decoder.image(at:i));frame["index"]=i;frame["delay"]=decoder.currentDelay;frames.append(frame)};result["nativeCanvas"]=["width":decoder.width,"height":decoder.height,"frames":frames,"count":decoder.frameCount]}
            catch{result["nativeCanvasError"]=String(describing:error)}
            do{let decoder=try NativeUserAvatarAnimation(data:data);var frames:[[String:Any]]=[];while let f=try decoder.nextFrame(){var frame=try pixels(f.image);frame["index"]=f.index;frame["delay"]=f.delay;frames.append(frame)};result["nativePlayback"]=["frames":frames,"count":decoder.frameCount,"requiresInitialFrameDisplay":decoder.requiresInitialFrameDisplay]}
            catch{result["nativePlaybackError"]=String(describing:error)}
            results.append(result)
        }}
        try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:dir.appendingPathComponent("native.json"));print("Orientation probe: \(results.count) cases")
    }
}
