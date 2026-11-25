import AppKit

// Run by the benchmark driver, independently of the measured app's window-info
// permission context. Only this synthetic app's window metadata is emitted.
let pid = Int(CommandLine.arguments[1])!
let info = CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] ?? []
let ours = info.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.intValue == pid }
let keys = [kCGWindowNumber,kCGWindowOwnerPID,kCGWindowBounds,kCGWindowMemoryUsage,kCGWindowIsOnscreen,kCGWindowLayer,kCGWindowAlpha]
let safe = ours.map { row in Dictionary(uniqueKeysWithValues:keys.compactMap { key -> (String,Any)? in row[key as String].map { (key as String,$0) } }) }
let data = try JSONSerialization.data(withJSONObject:["pid":pid,"totalWindowCount":info.count,"ours":safe],options:[.sortedKeys])
print(String(decoding:data,as:UTF8.self))
