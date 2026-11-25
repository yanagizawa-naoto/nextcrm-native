import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Disposable SVG renderer. The parent launches this executable in a filesystem
/// and network sandbox; only its input and system font/framework resources are readable.
@main enum NativeDocumentSVGWorker {
    static func main() {
        do {
            guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--parent",
                  let parent = Int32(CommandLine.arguments[2]), parent > 1, getppid() == parent else { exit(3) }
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            let watch = DispatchSource.makeTimerSource(queue:DispatchQueue.global(qos:.utility))
            watch.schedule(deadline:.now()+0.1,repeating:0.1)
            watch.setEventHandler { if getppid() != parent || ProcessInfo.processInfo.systemUptime >= deadline { _exit(3) } }
            watch.resume();defer { watch.cancel() }
            var statbuf = stat()
            guard fstat(STDIN_FILENO, &statbuf) == 0, statbuf.st_mode & S_IFMT == S_IFREG,
                  statbuf.st_size > 0, statbuf.st_size <= 256 * 1024 * 1024 else { exit(2) }
            let bytes = try FileHandle.standardInput.readToEnd() ?? Data()
            guard bytes.count == statbuf.st_size else { exit(2) }
            let forbidden = ["<!DOCTYPE","<!ENTITY"].flatMap { word in
                [String.Encoding.utf8,.utf16LittleEndian,.utf16BigEndian,.utf32LittleEndian,.utf32BigEndian].map { word.data(using:$0)! }
            }
            guard !forbidden.contains(where:{ bytes.range(of:$0) != nil }) else { exit(2) }
            guard let image = NSImage(data: bytes), image.size.width.isFinite,
                  image.size.height.isFinite, image.size.width > 0, image.size.height > 0 else { exit(2) }
            image.cacheMode = .never
            guard let context = CGContext(data:nil,width:200,height:200,bitsPerComponent:8,
                                          bytesPerRow:800,space:CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(2) }
            let scale = max(200/image.size.width,200/image.size.height)
            let width = image.size.width * scale, height = image.size.height * scale
            guard width.isFinite, height.isFinite else { exit(2) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
            image.draw(in:NSRect(x:(200-width)/2,y:(200-height)/2,width:width,height:height),
                       from:.zero,operation:.copy,fraction:1,respectFlipped:false,
                       hints:[.interpolation:NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
            guard let rendered=context.makeImage() else { exit(2) }
            let output=NSMutableData()
            guard let destination=CGImageDestinationCreateWithData(output,UTType.png.identifier as CFString,1,nil) else { exit(2) }
            CGImageDestinationAddImage(destination,rendered,nil)
            guard CGImageDestinationFinalize(destination),output.length <= 1024*1024 else { exit(2) }
            try FileHandle.standardOutput.write(contentsOf:output as Data)
        } catch { exit(2) }
    }
}
