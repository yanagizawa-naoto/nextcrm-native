import Foundation

enum ProductCSVEncoding: String, CaseIterable {
    case utf8 = "UTF-8", shiftJIS = "Shift JIS"
    var value: String.Encoding { self == .utf8 ? .utf8 : .shiftJIS }
}

/// RFC-style quoted records, bounded to one 1 MiB record plus a 16 KiB read buffer.
/// Structural/encoding errors abort the whole import; no replacement characters or partial writes.
final class ProductCSVReader {
    private let stream: InputStream
    private let encoding: String.Encoding
    private var buffer = [UInt8](repeating:0,count:16384)
    private var position = 0; private var length = 0; private var pending: [UInt8] = []; private var atStart = true
    private(set) var recordNumber = 0
    init(url: URL, encoding: ProductCSVEncoding) throws {
        guard let stream = InputStream(url:url) else { throw NativeDBError.message("CSVファイルを開けません。") }
        self.stream = stream; self.encoding = encoding.value; stream.open()
    }
    deinit { stream.close() }
    private func byte() throws -> UInt8? {
        if !pending.isEmpty { return pending.removeFirst() }
        if atStart {
            atStart = false
            guard let first = try rawByte() else { return nil }
            if first == 239 && encoding == .utf8 {
                if let second = try rawByte() { pending.append(second) }; if let third = try rawByte() { pending.append(third) }
                if pending == [187,191] { pending.removeAll(); return try rawByte() }
            }
            return first
        }
        return try rawByte()
    }
    private func rawByte() throws -> UInt8? {
        if position == length {
            length = stream.read(&buffer,maxLength:buffer.count); position = 0
            if length < 0 { throw stream.streamError ?? NativeDBError.message("CSVファイルを読み込めません。") }
            if length == 0 { return nil }
        }
        defer { position += 1 }; return buffer[position]
    }
    func next() throws -> [String]? {
        while true {
            var fields: [String] = []; var bytes = Data(); var state = 0; var size = 0; var started = false; var ended = false
            func finish() throws {
                guard fields.count < 64, let text = String(data:bytes,encoding:encoding), !text.contains("\0") else { throw NativeDBError.message("CSVの文字コードまたは列数が正しくありません。") }
                fields.append(text); bytes.removeAll(keepingCapacity:true)
            }
            while let b = try byte() {
                started = true; size += 1
                guard size <= 1_048_576 else { throw NativeDBError.message("CSVの1行は1 MiB以内にしてください。") }
                if state == 1 {
                    if b == 34 { state = 2 } else { bytes.append(b) }; continue
                }
                if b == 34 {
                    if state == 2 { bytes.append(b); state = 1 }
                    else if bytes.isEmpty { state = 1 }
                    else { throw NativeDBError.message("CSVの引用符が正しくありません。") }
                } else if b == 44 { try finish(); state = 0 }
                else if b == 10 || b == 13 {
                    if b == 13, let next = try byte(), next != 10 { pending.insert(next,at:0) }
                    try finish(); ended = true; break
                } else {
                    guard state != 2 else { throw NativeDBError.message("CSVの閉じ引用符の後に不要な文字があります。") }
                    bytes.append(b)
                }
            }
            if !started { return nil }
            guard state != 1 else { throw NativeDBError.message("CSVの引用符が閉じていません。") }
            if !ended { try finish() }
            recordNumber += 1
            if fields.count == 1 && fields[0].isEmpty { continue }
            return fields
        }
    }
}

struct ProductCSVPreview { let count: Int; let rows: [[String:String]] }
struct ProductCSVResult { var imported = 0; var errors: [String] = []; var skipped: Int { errors.count } }
private struct ProductCSVRowError: LocalizedError { let text: String; var errorDescription: String? { text } }

extension CRMService {
    static let productCSVColumns = ["name","sku","type","category","description","unit_price","unit_cost","currency","tax_rate","unit","is_recurring","billing_period"]
    static let productCSVTemplate = "\u{feff}"+productCSVColumns.joined(separator:",")+"\r\n日本語サポート,JP-SUPPORT,SERVICE,,導入支援,10000,5000,JPY,10,件,false,\r\n"
    private func productCSVRows(url: URL, encoding: ProductCSVEncoding, _ body: ([String:String],Int) throws -> Void) throws -> Int {
        let reader = try ProductCSVReader(url:url,encoding:encoding)
        guard var header = try reader.next() else { throw NativeDBError.message("CSVファイルが空です。") }
        if header[0].hasPrefix("\u{feff}") { header[0].removeFirst() }
        header = header.map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }
        guard Set(header).count == header.count, !header.contains("") else { throw NativeDBError.message("CSVの列名が空か重複しています。") }
        let missing = ["name","type","unit_price","currency"].filter { !header.contains($0) }
        guard missing.isEmpty else { throw NativeDBError.message("必須の列がありません："+missing.joined(separator:"、")) }
        var count = 0
        while let row = try reader.next() {
            count += 1; guard count <= 500 else { throw NativeDBError.message("一度に取り込めるのは500行までです。何も保存していません。") }
            guard row.count <= header.count else { throw NativeDBError.message("\(count+1)行目の列数が見出しと一致しません。") }
            try autoreleasepool { try body(Dictionary(uniqueKeysWithValues:header.enumerated().map { ($0.element, $0.offset < row.count ? row[$0.offset] : "") }),count+1) }
        }
        return count
    }
    func previewProductsCSV(url: URL, encoding: ProductCSVEncoding) throws -> ProductCSVPreview {
        try catalogWrite("crm_Products",original:nil)
        var preview: [[String:String]] = []
        let count = try productCSVRows(url:url,encoding:encoding) { row,_ in
            if preview.count < 5 { preview.append(row.mapValues { String($0.prefix(160)) }) }
        }
        return ProductCSVPreview(count:count,rows:preview)
    }
    func importProductsCSV(url: URL, encoding: ProductCSVEncoding) throws -> ProductCSVResult {
        try catalogWrite("crm_Products",original:nil)
        return try db.withProductImportIndex { hasSKU,addSKU,category in
            var result = ProductCSVResult()
            _ = try productCSVRows(url:url,encoding:encoding) { row,line in
                var values: [String:SQLValue]
                do {
                    func error(_ message: String) -> ProductCSVRowError { ProductCSVRowError(text:message) }
                    func value(_ key: String) -> String { (row[key] ?? "").trimmingCharacters(in:.whitespacesAndNewlines) }
                    func optional(_ key: String) -> SQLValue { value(key).isEmpty ? .null : .text(value(key)) }
                    func decimal(_ key: String, required: Bool = false) throws -> SQLValue {
                        let text = value(key); if text.isEmpty && !required { return .null }
                        let label = ["unit_price":"単価","unit_cost":"原価","tax_rate":"税率"][key] ?? key
                        guard let number = try? PriceDecimal.parse(text), number >= 0 else { throw error("\(label)（\(key)）は0以上の数値で入力してください。") }
                        guard key != "tax_rate" || number <= 100 else { throw error("税率（tax_rate）は100以下にしてください。") }; return .text(text)
                    }
                    guard !value("name").isEmpty, value("name").count <= 255 else { throw error("商品名は1〜255文字で入力してください。") }
                    let type = value("type").uppercased(); guard ["PRODUCT","SERVICE"].contains(type) else { throw error("typeはPRODUCTまたはSERVICEにしてください。") }
                    let currency = value("currency").uppercased()
                    guard try db.get("Currency",key:["code":.text(currency)])?["isEnabled"] == .integer(1) else { throw error("有効な通貨コードを指定してください。") }
                    let sku = value("sku"); guard sku.count <= 100, value("unit").count <= 50 else { throw error("商品コードは100文字、単位は50文字以内です。") }
                    if !sku.isEmpty, try hasSKU(sku) { throw error("商品コード「\(sku)」が既存商品またはCSV内で重複しています。") }
                    var categoryID: SQLValue = .null
                    if !value("category").isEmpty { guard let id = try category(value("category")) else { throw error("有効な商品カテゴリが見つかりません。") }; categoryID = id }
                    let recurring = value("is_recurring").lowercased() == "true"; let period = value("billing_period").uppercased()
                    if recurring && !["MONTHLY","QUARTERLY","ANNUALLY","ONE_TIME"].contains(period) { throw error("継続課金には有効なbilling_periodが必要です。") }
                    values = ["name":.text(value("name")),"sku":optional("sku"),"type":.text(type),"status":.text("DRAFT"),"description":optional("description"),"categoryId":categoryID,"unit_price":try decimal("unit_price",required:true),"unit_cost":try decimal("unit_cost"),"currency":.text(currency),"tax_rate":try decimal("tax_rate"),"unit":optional("unit"),"is_recurring":.integer(recurring ? 1 : 0),"billing_period":recurring ? .text(period) : .null]
                    do { try db.validateFieldValues("crm_Products",values) } catch let e { throw error(e.localizedDescription) }
                } catch let e as ProductCSVRowError { result.errors.append("\(line)行目："+e.text); return }
                // DB/permission/audit failures must roll back the entire import, not masquerade as row errors.
                _ = try saveCatalog(CRMModule.find("crm_Products")!,original:nil,input:values,linkedTo:nil)
                if let sku = values["sku"], sku != .null { try addSKU(sku.string) }
                result.imported += 1
            }
            return result
        }
    }
}
