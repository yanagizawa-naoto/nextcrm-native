import Foundation

struct NativeTargetSpreadsheetMapping: Codable {
    struct Column: Codable { let header: String; var field: String? }
    var columns: [Column]
    static func fallback(_ headers: [String], japanese: Bool = true) -> Self {
        .init(columns: headers.map { .init(header: $0, field: fuzzy($0, japanese: japanese)) })
    }
    static func fuzzy(_ header: String, japanese: Bool = true) -> String? {
        let normalized = String(NativeTargetSpreadsheetFields.lower(header).unicodeScalars.filter { !NativeTargetSpreadsheetFields.whitespace.contains($0) && $0 != "_" && $0 != "-" })
        if let field = NativeTargetSpreadsheetFields.all.first(where: { $0.key.replacingOccurrences(of: "_", with: "") == normalized }) { return field.key }
        let aliases: [String:[String]] = [
            "last_name":["lastname","surname","familyname"], "first_name":["firstname","givenname","name"],
            "email":["mail","emailaddress"], "mobile_phone":["phone","mobile","cellphone","mobilephone"],
            "office_phone":["officephone","workphone","businessphone"], "company":["companyname","organization","organisation"],
            "position":["jobtitle","title","role"], "company_website":["website","companywebsite"], "personal_website":["personalwebsite"],
            "social_linkedin":["linkedin","linkedinurl"], "social_x":["twitter","x","x/twitter"], "social_instagram":["instagram"], "social_facebook":["facebook"],
            "personal_email":["personalemail","directemail","myemail"], "company_email":["companyemail","infoemail","contactemail","genericemail"],
            "company_phone":["companyphone","mainphone","switchboard","hqphone"], "city":["hqcity","headquarterscity"], "country":["hqcountry","nation"],
            "industry":["sector","vertical","businesstype"], "employees":["headcount","numemployees","teamsize","companysize"], "description":["about","bio","summary","companydescription"]
        ]
        if let field = aliases.first(where: { $0.value.contains(normalized) })?.key { return field }
        // Explicit Japanese-product addition: the original fuzzy matcher only
        // has English aliases. Both localized and original export labels work.
        if japanese {
            for field in NativeTargetSpreadsheetFields.all {
                for label in [field.title,field.sourceTitle] {
                    let normalizedLabel = String(NativeTargetSpreadsheetFields.lower(label).unicodeScalars.filter { !NativeTargetSpreadsheetFields.whitespace.contains($0) && $0 != "_" && $0 != "-" })
                    if NativeTargetSpreadsheetFields.same(normalizedLabel,normalized) { return field.key }
                }
            }
        }
        return nil
    }
    static func fromAI(_ content: String, headers: [String]) throws -> Self {
        // Keep the Foundation object, rather than a Swift Dictionary whose
        // String equality would collapse canonically equivalent header names.
        let parsed = try JSONSerialization.jsonObject(with: Data(content.utf8), options: [.fragmentsAllowed])
        guard !(parsed is NSNull) else { throw NativeTargetSpreadsheetFailure(message:"AIの列対応が空です。") }
        let object = parsed as? NSDictionary
        let array = parsed as? NSArray
        return .init(columns: headers.map { header in
            let element: Any?
            if let array,let index = Int(header),index >= 0,index < array.count,String(index) == header { element = array[index] } else { element = object?.object(forKey: header as NSString) }
            let suggestion = element as? String
            return .init(header: header, field: suggestion.flatMap { NativeTargetSpreadsheetFields.keys.contains($0) ? $0 : nil })
        })
    }
    func values(_ row: NativeTargetSpreadsheetRow) throws -> [String:String] {
        var result: [String:String] = [:]
        if columns.isEmpty {
            for field in NativeTargetSpreadsheetFields.keys {
                if let value = row.value(field) {
                    guard let text = value.text else { throw NativeTargetSpreadsheetFailure(message: "文字列以外の値が割り当てられています。列の対応を確認してください。") }
                    result[field] = text
                }
            }
        } else {
            for column in columns {
                guard let field = column.field, NativeTargetSpreadsheetFields.keys.contains(field), let value = row.value(column.header) else { continue }
                guard let text = value.text else { throw NativeTargetSpreadsheetFailure(message: "文字列以外の値が割り当てられています。列の対応を確認してください。") }
                result[field] = text
            }
        }
        return result
    }
}
