import AppKit
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let bounds = NSRect(x: 52, y: 52, width: 920, height: 920)
NSColor(calibratedRed: 0.45, green: 0.20, blue: 0.91, alpha: 1).setFill()
NSBezierPath(roundedRect: bounds, xRadius: 210, yRadius: 210).fill()
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 580, weight: .bold),
    .foregroundColor: NSColor.white, .paragraphStyle: paragraph
]
("N" as NSString).draw(in: NSRect(x: 52, y: 188, width: 920, height: 700), withAttributes: attrs)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
