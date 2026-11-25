import Foundation

/// A bounded syntax parser preserves arbitrary JSON number lexemes. It never
/// converts user JSON numbers through NSNumber/Double or serializes cell data.
indirect enum NativeMigrationJSON {
    case null, bool(Bool), number(String), string(String), array([NativeMigrationJSON]), object([String:NativeMigrationJSON])
    var object: [String:NativeMigrationJSON]? { if case let .object(v)=self { return v };return nil }
    var string: String? { if case let .string(v)=self { return v };return nil }
    var array: [NativeMigrationJSON]? { if case let .array(v)=self { return v };return nil }
    var bool: Bool? { if case let .bool(v)=self { return v };return nil }
    var integer: Int64? { if case let .number(v)=self { return Int64(v) };return nil }
    var isNull: Bool { if case .null=self { return true };return false }
    static func parse(_ data: Data, strictKeys: Bool = true) throws -> NativeMigrationJSON {
        var parser=Parser(bytes:Array(data),strictKeys:strictKeys)
        let result=try parser.value(0);parser.spaces()
        guard parser.at==parser.bytes.count else { throw parser.bad }
        return result
    }
    private struct Parser {
        let bytes:[UInt8];let strictKeys:Bool;var at=0
        var bad:NativeMigrationFailure { .init("json.syntax","JSONの形式・重複キー・文字コードを確認してください。") }
        mutating func spaces() { while at<bytes.count && [9,10,13,32].contains(bytes[at]) { at+=1 } }
        mutating func take(_ byte:UInt8)->Bool { if at<bytes.count && bytes[at]==byte { at+=1;return true };return false }
        mutating func word(_ word:String) throws { let b=Array(word.utf8);guard at+b.count<=bytes.count && bytes[at..<at+b.count].elementsEqual(b) else { throw bad };at+=b.count }
        mutating func text() throws -> String {
            let start=at;guard take(34) else { throw bad }
            while at<bytes.count {
                let b=bytes[at];at+=1
                if b==34 { guard let text=try? JSONDecoder().decode(String.self,from:Data(bytes[start..<at])) else { throw bad };return text }
                if b<32 { throw bad }
                if b==92 { guard at<bytes.count else { throw bad };at+=1 }
            }
            throw bad
        }
        mutating func value(_ depth:Int) throws -> NativeMigrationJSON {
            guard depth<=128 else { throw NativeMigrationFailure("json.depth","JSONの入れ子が検査上限を超えています。") }
            spaces();guard at<bytes.count else { throw bad }
            switch bytes[at] {
            case 110:try word("null");return .null
            case 116:try word("true");return .bool(true)
            case 102:try word("false");return .bool(false)
            case 34:return .string(try text())
            case 91:
                at+=1;spaces();if take(93) { return .array([]) };var values:[NativeMigrationJSON]=[]
                while true { values.append(try value(depth+1));spaces();if take(93){return .array(values)};guard take(44) else {throw bad} }
            case 123:
                at+=1;spaces();if take(125) {return .object([:])};var values:[String:NativeMigrationJSON]=[:];var seen=Set<Data>()
                while true {
                    spaces();let key=try text();let raw=Data(key.utf8)
                    if strictKeys && (!seen.insert(raw).inserted || values[key] != nil) {throw bad};seen.insert(raw)
                    spaces();guard take(58) else {throw bad};values[key]=try value(depth+1);spaces()
                    if take(125){return .object(values)};guard take(44) else {throw bad}
                }
            default:
                let start=at;_ = take(45)
                if !take(48) { guard at<bytes.count && (49...57).contains(bytes[at]) else {throw bad};repeat {at+=1} while at<bytes.count && (48...57).contains(bytes[at]) }
                if take(46) { let d=at;while at<bytes.count && (48...57).contains(bytes[at]){at+=1};guard at>d else {throw bad} }
                if take(101) || take(69) { _ = take(43) || take(45);let d=at;while at<bytes.count && (48...57).contains(bytes[at]){at+=1};guard at>d else {throw bad} }
                return .number(String(decoding:bytes[start..<at],as:UTF8.self))
            }
        }
    }
}
