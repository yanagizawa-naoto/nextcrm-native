import Foundation

/// The original ARES/VIES provider. HTTP permission, redirects, response bounds
/// and cancellation belong to the shared plugin context's transport.
enum NativeAres {
    typealias Fetch = (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let address = "https://ares.gov.cz/ekonomicke-subjekty-v-be/rest/ekonomicke-subjekty/"
    static let vatAddress = "https://ec.europa.eu/taxation_customs/vies/rest-api/check-vat-number"
    // ECMAScript whitespace deliberately excludes U+0085 and U+180E.
    static let whitespace = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
    static let countries = Set("AT BE BG CY CZ DE DK EE EL GR ES FI FR HR HU IE IT LT LU LV MT NL PL PT RO SE SI SK XI".split(separator: " ").map(String.init))

    static func removeWhitespace(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { !whitespace.contains($0) }))
    }
    static func normalizeIco(_ input: String) -> String? {
        let digits = Array(removeWhitespace(input).utf8)
        guard (1...8).contains(digits.count), digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let values = Array(repeating: 0, count: 8 - digits.count) + digits.map { Int($0) - 48 }
        let sum = (0..<7).reduce(0) { $0 + values[$1] * (8 - $1) }
        guard (11 - sum % 11) % 10 == values[7] else { return nil }
        return values.map(String.init).joined()
    }
    static func map(_ subject: Any, ico: String) throws -> NativePluginRecord {
        guard !(subject is NSNull) else { throw NativePluginError(message: "ARES returned a null subject") }
        let subject = subject as? NativePluginRecord ?? [:]
        let a = subject["sidlo"] as? NativePluginRecord ?? [:]
        let orientation = a["cisloOrientacni"].map { "/" + NativePluginJSON.string($0) + NativePluginJSON.string(nonnull(a["cisloOrientacniPismeno"]) ?? "") } ?? ""
        let house = a["cisloDomovni"].map { NativePluginJSON.string($0) + orientation } ?? ""
        let streetName = nonnull(a["nazevUlice"]) ?? a["nazevCastiObce"]
        let street = [streetName, house].compactMap { $0 }.filter(NativePluginJSON.truthy).map(NativePluginJSON.string).joined(separator: " ")
        var output: NativePluginRecord = ["registrationNumber": ico, "country": "CZ"]
        output["name"] = subject["obchodniJmeno"]
        if NativePluginJSON.truthy(subject["dic"]) { output["vat"] = subject["dic"] }
        if !street.isEmpty { output["street"] = street }
        if NativePluginJSON.truthy(a["nazevObce"]) { output["city"] = a["nazevObce"] }
        if let postal = a["psc"] { output["postalCode"] = NativePluginJSON.string(postal) }
        return output
    }
    private static func nonnull(_ value: Any?) -> Any? { value is NSNull ? nil : value }

    static func lookup(_ number: String, fetch: Fetch) async throws -> NativePluginRecord? {
        guard let ico = normalizeIco(number) else { return nil }
        var request = URLRequest(url: URL(string: address + ico)!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try Task.checkCancellation()
        let (body, response) = try await fetch(request)
        try Task.checkCancellation()
        if response.statusCode == 404 { return nil }
        guard (200..<300).contains(response.statusCode) else { throw NativePluginError(message: "ARES responded \(response.statusCode)") }
        return try map(JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]), ico: ico)
    }

    static func validateVat(_ vat: String, fetch: Fetch) async throws -> Bool {
        let value = removeWhitespace(vat).replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "-", with: "").uppercased()
        let units = Array(value.utf16)
        let prefix = String(decoding: units.prefix(2), as: UTF16.self)
        let number = String(decoding: units.dropFirst(2), as: UTF16.self)
        guard prefix.utf8.count == 2, prefix.utf8.allSatisfy({ (65...90).contains($0) }), !number.isEmpty else { return false }
        guard countries.contains(prefix) else { throw NativePluginError(message: "VIES does not cover " + prefix) }
        var request = URLRequest(url: URL(string: vatAddress)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try NativePluginJSON.data(["countryCode": prefix == "GR" ? "EL" : prefix, "vatNumber": number])
        try Task.checkCancellation()
        let (body, response) = try await fetch(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else { throw NativePluginError(message: "VIES responded \(response.statusCode)") }
        let raw = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        guard !(raw is NSNull) else { throw NativePluginError(message: "VIES returned a null result") }
        let reply = raw as? NativePluginRecord ?? [:]
        if let valid = NativePluginJSON.boolean(reply["valid"]) { return valid }
        let errors = reply["errorWrappers"]
        let first = (errors as? [Any])?.first ?? (errors as? NativePluginRecord)?["0"]
        let code = nonnull((first as? NativePluginRecord)?["error"]) ?? "UNKNOWN"
        if code as? String == "INVALID_INPUT" { return false }
        throw NativePluginError(message: "VIES unavailable: " + NativePluginJSON.string(code))
    }
}
