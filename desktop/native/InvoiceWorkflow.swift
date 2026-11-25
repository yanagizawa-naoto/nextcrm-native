import Foundation

enum InvoiceWorkflow {
    static let statuses = ["DRAFT","ISSUED","SENT","PARTIALLY_PAID","PAID","OVERDUE","CANCELLED","DISPUTED","REFUNDED","WRITTEN_OFF"]
    static let types = ["INVOICE","CREDIT_NOTE","PROFORMA"]
    static func can(status: String, creator: String, action: String, actorID: String, role: String) -> Bool {
        let owner = ["admin","manager"].contains(role) || role == "user" && creator == actorID
        guard owner else { return false }
        switch action {
        case "read","duplicate": return true
        case "edit","issue","cancel": return status == "DRAFT"
        case "payment": return ["ISSUED","SENT","PARTIALLY_PAID","OVERDUE"].contains(status)
        case "pdf","email": return status != "DRAFT"
        default: return false
        }
    }
}

struct InvoiceLineInput: Codable {
    var productID: String?; var description: String; var quantity: String; var unitPrice: String
    var discountPercent: String; var taxRateID: String?
    func math(rate: String) -> InvoiceMath.Input { .init(quantity:quantity,unitPrice:unitPrice,discountPercent:discountPercent,taxRate:rate) }
    static func from(_ row: NativeRecord) -> Self {
        .init(productID:row["productId"] == .null ? nil : row["productId"].string,description:row["description"].string,quantity:row["quantity"].string,unitPrice:row["unitPrice"].string,discountPercent:row["discountPercent"].string,taxRateID:row["taxRateId"] == .null ? nil : row["taxRateId"].string)
    }
}
struct InvoiceLineQuote: Codable {
    let rate: String; let amounts: InvoiceMath.Line
    var lineID: String? = nil
    func values(_ input: InvoiceLineInput, snapshot: Bool = false) -> [String:SQLValue] {
        ["productId":input.productID.map(SQLValue.text) ?? .null,"description":.text(input.description),"quantity":.text(input.quantity),"unitPrice":.text(input.unitPrice),"discountPercent":.text(input.discountPercent),"taxRateId":input.taxRateID.map(SQLValue.text) ?? .null,"taxRateSnapshot":snapshot && input.taxRateID != nil ? .text(rate) : .null,"lineSubtotal":.text(amounts.lineSubtotal),"lineVat":.text(amounts.lineVat),"lineTotal":.text(amounts.lineTotal)]
    }
}
struct InvoiceDraftRow: Codable { let id: String; let input: InvoiceLineInput; let quote: InvoiceLineQuote }

/// Network work may happen before issuance. Bind the result to both currencies and the
/// settings revision so a concurrent settings edit cannot silently change its meaning.
struct InvoiceFXQuote {
    let from: String; let to: String; let rate: String; let settingsRevision: Int64
}
