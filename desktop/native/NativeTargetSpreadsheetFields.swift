import Foundation

struct NativeTargetSpreadsheetFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum NativeTargetSpreadsheetFields {
    struct Field { let key: String; let title: String; let sourceTitle: String }
    static let all: [Field] = [
        .init(key: "last_name", title: "姓", sourceTitle: "Last Name"),
        .init(key: "first_name", title: "名", sourceTitle: "First Name"),
        .init(key: "email", title: "メールアドレス", sourceTitle: "メールアドレス"),
        .init(key: "mobile_phone", title: "携帯電話", sourceTitle: "Mobile Phone"),
        .init(key: "office_phone", title: "勤務先電話", sourceTitle: "Office Phone"),
        .init(key: "company", title: "会社名", sourceTitle: "会社名"),
        .init(key: "position", title: "部署・役職", sourceTitle: "部署・役職"),
        .init(key: "company_website", title: "会社のWebサイト", sourceTitle: "Company Website"),
        .init(key: "personal_website", title: "個人のWebサイト", sourceTitle: "Personal Website"),
        .init(key: "social_linkedin", title: "LinkedIn", sourceTitle: "LinkedIn"),
        .init(key: "social_x", title: "X / Twitter", sourceTitle: "X / Twitter"),
        .init(key: "social_instagram", title: "Instagram", sourceTitle: "Instagram"),
        .init(key: "social_facebook", title: "Facebook", sourceTitle: "Facebook"),
        .init(key: "personal_email", title: "個人メールアドレス", sourceTitle: "個人メールアドレス"),
        .init(key: "company_email", title: "会社メールアドレス", sourceTitle: "会社メールアドレス"),
        .init(key: "company_phone", title: "会社電話番号", sourceTitle: "会社電話番号"),
        .init(key: "city", title: "市区町村", sourceTitle: "市区町村"),
        .init(key: "country", title: "国", sourceTitle: "国"),
        .init(key: "industry", title: "業種", sourceTitle: "業種"),
        .init(key: "employees", title: "従業員数", sourceTitle: "従業員"),
        .init(key: "description", title: "説明", sourceTitle: "品名・内容"),
    ]
    static let keys = all.map(\.key)
    // JS trim(), deliberately not Foundation's broader whitespace set.
    static let whitespace = CharacterSet(charactersIn: "\u{0009}\u{000a}\u{000b}\u{000c}\u{000d}\u{0020}\u{00a0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}")
    static func trim(_ value: String) -> String { value.trimmingCharacters(in: whitespace) }
    // NSString/ICU applies Unicode contextual lowercasing (including final Σ),
    // unlike Swift String.lowercased(), which would miss a global suppression.
    static func lower(_ value: String) -> String { value.lowercased(with: Locale(identifier: "en_US_POSIX")) }
    static func same(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
}

struct NativeTargetSpreadsheetRow: Codable {
    struct Entry: Codable {
        let name: String
        let text: String?
        let extra: [String]?
        init(_ name: String, _ text: String) { self.name = name; self.text = text; extra = nil }
        init(extra: [String]) { name = "__parsed_extra"; text = nil; self.extra = extra }
    }
    let entries: [Entry]
    func value(_ header: String) -> Entry? { entries.last { NativeTargetSpreadsheetFields.same($0.name, header) } }
}
