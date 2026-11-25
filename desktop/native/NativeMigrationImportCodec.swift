import Foundation

enum NativeMigrationImportCodec {
    static func json(_ value:NativeMigrationJSON)throws->Data {
        switch value {
        case .null:return Data("null".utf8)
        case .bool(let b):return Data((b ? "true":"false").utf8)
        case .number(let n):return Data(n.utf8)
        case .string(let s):return try JSONEncoder().encode(s)
        case .array(let values):var output=Data([91]);for (i,value) in values.enumerated(){if i>0{output.append(44)};output.append(try json(value))};output.append(93);return output
        case .object(let values):var output=Data([123]);for (i,key) in values.keys.sorted(by:{$0.utf8.lexicographicallyPrecedes($1.utf8)}).enumerated(){if i>0{output.append(44)};output.append(try json(.string(key)));output.append(58);output.append(try json(values[key]!))};output.append(125);return output
        }
    }
    static func value(_ raw:NativeMigrationJSON,field:NativeMigrationSchema.Field,enums:[String:[String]],normalized:inout Int64)throws->NativeMigrationImportValue {
        _ = try NativeMigrationCodec.cell(raw,field:field,enums:enums)
        if raw.isNull{return .null}
        if field.array {
            var values=raw.array!
            if field.attributes.contains("@db.Uuid") {values=values.map{let s=$0.string!;if s != s.lowercased(){normalized+=1};return .string(s.lowercased())}}
            return .text(try json(.array(values)))
        }
        switch field.type {
        case "Boolean":return .integer(raw.bool! ? 1:0)
        case "Int","BigInt":return .integer(Int64(raw.string!)!)
        case "Float":return .real(Double(raw.string!)!)
        case "Json":return .text(Data(raw.object!["json"]!.string!.utf8))
        case "Bytes","Unsupported(\"vector(1536)\")":return .blob(Data(base64Encoded:raw.object!["base64"]!.string!)!)
        default:
            var text=raw.string!
            if field.attributes.contains("@db.Uuid"){let lower=text.lowercased();if text != lower{normalized+=1};text=lower}
            return .text(Data(text.utf8))
        }
    }
}
