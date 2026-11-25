import Foundation
import ImageIO
import UniformTypeIdentifiers

extension NativeOperationalAssets {
    static func document(_ row:NativeRecord,db:NativeDatabase)throws->NativeDocumentResolvedFile? {
        for field in ["key","document_file_url"] {
            if let map=try load(row,field:field,db:db),map.contentBinding==documentBinding(row){_ = try NativeDocumentFiles.fileName(for:map.local);return .init(logicalKey:row["key"].string,bucket:"migration-archive",fileKey:map.local,contentType:map.mime,bytes:map.bytes,sha256:map.sha256,mappingRevision:1)}
        };return nil
    }
    static func thumbnail(_ row:NativeRecord,db:NativeDatabase)throws->Data? {
        let bucket=try db.metadata("document.storage.bucket") ?? ""
        if try db.documentObject(bucket:bucket,key:row["key"].string) != nil{return nil}
        guard let map=try load(row,field:"thumbnail_url",db:db),map.contentBinding==documentBinding(row) else{return nil}
        guard map.bytes<=4*1024*1024 else{throw NativeDBError.message("移行した文書プレビューは4 MiBを超えています。原本は移行添付から確認できます。")}
        let url=try NativeDocumentFiles(dataRoot:db.url.deletingLastPathComponent()).verifiedURL(key:map.local,bytes:map.bytes,sha256:map.sha256)
        let bytes=try Data(contentsOf:url)
        guard let source=CGImageSourceCreateWithData(bytes as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let w=props[kCGImagePropertyPixelWidth] as? NSNumber,let h=props[kCGImagePropertyPixelHeight] as? NSNumber,w.intValue>0,h.intValue>0,w.intValue<=16384,h.intValue<=16384,w.intValue<=16_777_216/h.intValue else{throw NativeDBError.message("移行した文書プレビューの画像形式を確認してください。")}
        guard let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:512,kCGImageSourceShouldCache:false] as CFDictionary) else{throw NativeDBError.conflict}
        let output=NSMutableData();guard let target=CGImageDestinationCreateWithData(output,UTType.png.identifier as CFString,1,nil)else{throw NativeDBError.conflict};CGImageDestinationAddImage(target,image,[: ] as CFDictionary);guard CGImageDestinationFinalize(target),output.length<=1024*1024 else{throw NativeDBError.conflict};return output as Data
    }
}
