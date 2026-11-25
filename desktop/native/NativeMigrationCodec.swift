import Foundation
import CryptoKit

enum NativeMigrationCodec {
    static func hash(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    static func matches(_ pattern:String,_ value:String)->Bool { value.range(of:pattern,options:.regularExpression) != nil }
    static func groups(_ pattern:String,_ value:String)->[String]? {
        guard let regex=try? NSRegularExpression(pattern:pattern),let match=regex.firstMatch(in:value,range:NSRange(value.startIndex...,in:value)) else {return nil}
        return (1..<match.numberOfRanges).map { Range(match.range(at:$0),in:value).map{String(value[$0])} ?? "" }
    }
    static func names(_ text:String)->[String] { text.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) } }
    static func fields(in directive:String)->[String]? { groups(#"\[([^\]]+)\]"#,directive).map {names($0[0])} }
    static func validHash(_ text:String)->Bool { matches(#"\A[0-9a-f]{64}\z"#,text) }
    static func date(_ text:String,dateOnly:Bool)->Bool {
        let pattern=dateOnly ? #"\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z"# : #"\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,6}))?Z\z"#
        guard let parts=groups(pattern,text),let y=Int(parts[0]),let m=Int(parts[1]),let d=Int(parts[2]),(1...9999).contains(y),(1...12).contains(m) else {return false}
        let days=[31,(y%4==0 && (y%100 != 0 || y%400==0)) ? 29:28,31,30,31,30,31,31,30,31,30,31]
        guard (1...days[m-1]).contains(d) else {return false}
        return dateOnly || (Int(parts[3])!<24 && Int(parts[4])!<60 && Int(parts[5])!<60)
    }
    static func cell(_ value:NativeMigrationJSON,field:NativeMigrationSchema.Field,enums:[String:[String]]) throws -> Data? {
        if value.isNull { guard field.optional else {throw NativeMigrationFailure("cell.null","必須項目にSQL NULLがあります。")};return nil }
        if field.array {
            guard let values=value.array else {throw NativeMigrationFailure("cell.array","配列項目の形式が一致しません。")}
            let single=NativeMigrationSchema.Field(name:field.name,column:field.column,type:field.type,optional:false,array:false,attributes:field.attributes)
            return try tuple(values.map {try cell($0,field:single,enums:enums)!})
        }
        let failure=NativeMigrationFailure("cell.type","項目の型・値の範囲・保存形式が一致しません。")
        switch field.type {
        case "Boolean":guard let b=value.bool else {throw failure};return Data((b ? "b1":"b0").utf8)
        case "Int","BigInt":
            guard let s=value.string,matches(#"\A-?(?:0|[1-9][0-9]*)\z"#,s),let n=Int64(s),field.type != "Int" || (n>=Int64(Int32.min) && n<=Int64(Int32.max)) else {throw failure}
            return Data(("n"+String(n)).utf8)
        case "Decimal":
            guard let s=value.string,matches(#"\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z"#,s),let p=groups(#"@db.Decimal\(([0-9]+),\s*([0-9]+)\)"#,field.attributes),let precision=Int(p[0]),let scale=Int(p[1]) else {throw failure}
            let parts=s.replacingOccurrences(of:"-",with:"").split(separator:".",omittingEmptySubsequences:false)
            guard parts[0].drop(while:{$0=="0"}).count<=precision-scale,(parts.count==1 ? 0:parts[1].count)<=scale else {throw failure}
            var canonical=s;while canonical.contains(".") && canonical.last=="0" {canonical.removeLast()};if canonical.last=="." {canonical.removeLast()};if canonical=="-0"{canonical="0"}
            return Data(("d"+canonical).utf8)
        case "DateTime":
            guard let s=value.string,date(s,dateOnly:matches(#"@db.Date(?:\s|$)"#,field.attributes)) else {throw failure}
            var canonical=s
            if canonical.contains(".") {canonical.removeLast();while canonical.last=="0" {canonical.removeLast()};if canonical.last=="."{canonical.removeLast()};canonical+="Z"}
            return Data(("t"+canonical).utf8)
        case "Json":
            guard let o=value.object,o.count==1,let raw=o["json"]?.string else {throw failure}
            _ = try NativeMigrationJSON.parse(Data(raw.utf8),strictKeys:false)
            return Data(("j"+raw).utf8)
        case "Bytes", "Unsupported(\"vector(1536)\")":
            guard let o=value.object,o.count==1,let s=o["base64"]?.string,let data=Data(base64Encoded:s),data.base64EncodedString()==s else {throw failure}
            if field.type != "Bytes" {
                guard data.count==1536*4 else {throw failure}
                for i in stride(from:0,to:data.count,by:4) {let bits=UInt32(data[i]) | UInt32(data[i+1])<<8 | UInt32(data[i+2])<<16 | UInt32(data[i+3])<<24;guard Float(bitPattern:bits).isFinite else {throw failure}}
            }
            return Data([98])+data
        case "Float":
            guard let s=value.string,let n=Double(s),n.isFinite else {throw failure};return Data(("f"+String(n)).utf8)
        default:
            guard let s=value.string,!s.utf8.contains(0) else {throw failure}
            if let values=enums[field.type] {guard values.contains(where:{$0.utf8.elementsEqual(s.utf8)}) else {throw failure}}
            if field.attributes.contains("@db.Uuid") {
                guard matches(#"\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z"#,s) else {throw failure}
                return Data(("s"+s.lowercased()).utf8)
            }
            if let n=groups(#"@db.VarChar\(([0-9]+)\)"#,field.attributes).flatMap({Int($0[0])}),s.unicodeScalars.count>n {throw failure}
            return Data(("s"+s).utf8)
        }
    }
    static func tuple(_ values:[Data])->Data {
        var result=Data()
        for value in values {var length=UInt64(value.count).bigEndian;withUnsafeBytes(of:&length){result.append(contentsOf:$0)};result.append(value)}
        return result
    }
    static func namespace(_ model:String,_ fields:[String])->String {model+"/"+fields.joined(separator:",")}
    static func key(_ object:[String:NativeMigrationJSON],model:NativeMigrationSchema.Model,enums:[String:[String]]) throws -> Data {
        guard Set(object.keys)==Set(model.primaryKey) else {throw NativeMigrationFailure("reference.key","参照の主キー項目が一致しません。")}
        return try tuple(model.primaryKey.map { name in
            guard let field=model.fields.first(where:{$0.name==name}),let value=object[name],let cell=try cell(value,field:field,enums:enums) else {throw NativeMigrationFailure("reference.key","参照の主キーが不正です。")};return cell
        })
    }
}
