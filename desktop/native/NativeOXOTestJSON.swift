import Foundation

/// JSONDecoder retains a leading U+FEFF inside JSON strings. Foundation's
/// JSONSerialization bridges those strings through NSString and removes it.
struct NativeOXOTestJSON:Decodable {
    let value:Any
    init(from decoder:Decoder) throws {
        let c=try decoder.singleValueContainer()
        if c.decodeNil(){value=NSNull()}
        else if let b=try? c.decode(Bool.self){value=b}
        else if let s=try? c.decode(String.self){value=s}
        else if let n=try? c.decode(Int64.self){value=n}
        else if let n=try? c.decode(Double.self){value=n}
        else if let a=try? c.decode([NativeOXOTestJSON].self){value=a.map(\.value)}
        else{value=try c.decode([String:NativeOXOTestJSON].self).mapValues(\.value)}
    }
    static func parse(_ data:Data) throws -> Any { try JSONDecoder().decode(Self.self,from:data).value }
}
