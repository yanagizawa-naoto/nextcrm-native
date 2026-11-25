import Foundation

/// Raw editing values survive the lifetime of controls, including invalid/incomplete numbers.
enum FormRawValue: Equatable {
    case text(String), flag(Bool), date(Date,Bool), reference(SQLValue), choice(String)
    var text: String { if case let .text(value) = self { return value }; return "" }
}

final class FormDraft {
    let module: CRMModule; let schema: NativeSchema.Model
    private(set) var values: [String:FormRawValue] = [:]
    private(set) var options: [String:[(String,String)]] = [:]
    private var initial: [String:SQLValue] = [:]
    init(module: CRMModule, schema: NativeSchema.Model, input: [String:SQLValue], isNew: Bool, now: Date = Date()) throws {
        self.module = module; self.schema = schema
        let parser = ISO8601DateFormatter(); let fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
        for field in module.fields {
            let value = input[field.key] ?? .null
            switch field.kind {
            case .toggle: values[field.key] = .flag(value == .integer(1))
            case let .choice(all):
                var choices = module.model == "crm_AccountProducts" && field.key == "status" && isNew ? all.filter { ["ACTIVE","PENDING"].contains($0.0) } : all
                if schema.field(field.key)?.optional == true { choices.insert(("","未設定"),at:0) }
                if !value.string.isEmpty, !choices.contains(where: { $0.0 == value.string }) { choices.append((value.string,CRMModule.label(value.string))) }
                options[field.key] = choices
                values[field.key] = .choice(choices.contains { $0.0 == value.string } ? value.string : choices.first?.0 ?? "")
            case .relation: values[field.key] = .reference(value)
            case .date, .dateTime:
                let invoiceDay = ["Invoices","Invoice_Payments"].contains(module.model)
                let date = parser.date(from:value.string) ?? fractional.date(from:value.string) ?? (invoiceDay ? InvoiceCalendar.today(now) : now)
                values[field.key] = .date(invoiceDay ? InvoiceCalendar.canonical(date) : date,value != .null || field.required)
            case .lines:
                let strings = try? JSONDecoder().decode([String].self,from:Data(value.string.utf8))
                values[field.key] = .text(strings?.joined(separator:"\n") ?? value.string)
            default: values[field.key] = .text(value.string)
            }
        }
        initial = try normalized()
    }
    func set(_ key: String, _ value: FormRawValue) { precondition(values[key] != nil); values[key] = value }
    func setText(_ key: String, _ value: String) { if case .text? = values[key] { values[key] = .text(value) } }
    func setReference(_ key: String, _ value: SQLValue) { if case .reference? = values[key] { values[key] = .reference(value) } }
    func normalized(_ field: EditorField) throws -> SQLValue {
        guard let raw = values[field.key] else { throw NativeDBError.message("入力項目を確認できません。") }
        let optional = schema.field(field.key)?.optional == true
        switch raw {
        case let .flag(value): return .integer(value ? 1 : 0)
        case let .reference(value): return value
        case let .choice(value): return value.isEmpty ? .null : .text(value)
        case let .date(date,enabled):
            let day = ["Invoices","Invoice_Payments"].contains(module.model) ? InvoiceCalendar.canonical(date) : date
            return enabled ? .text(ISO8601DateFormatter().string(from:day)) : .null
        case let .text(value):
            switch field.kind {
            case .lines:
                let list = value.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
                return .text(String(decoding:try JSONEncoder().encode(list),as:UTF8.self))
            case .multiline: return value.isEmpty && optional ? .null : .text(value)
            default:
                let string = value.trimmingCharacters(in:.whitespacesAndNewlines)
                if string.isEmpty && optional { return .null }
                let numeric: Bool = { switch field.kind { case .number,.signedNumber: return true; default: return false } }()
                if !numeric || string.isEmpty { return .text(string) }
                let number = string.replacingOccurrences(of:",",with:"")
                if schema.field(field.key)?.type == "Int" {
                    guard let parsed = Int64(number), parsed >= 0 else { throw NativeDBError.message("\(field.label)は0以上の整数で入力してください。") }; return .integer(parsed)
                }
                let signed: Bool = { if case .signedNumber = field.kind { return true }; return false }()
                guard let parsed = try? PriceDecimal.parse(number), signed || parsed >= 0 else { throw NativeDBError.message("\(field.label)に正しい数値を入力してください。") }
                return .text(number)
            }
        }
    }
    func normalized() throws -> [String:SQLValue] {
        var output: [String:SQLValue] = [:]; for field in module.fields { output[field.key] = try normalized(field) }; return output
    }
    var hasChanges: Bool { (try? normalized()) != initial }
}
