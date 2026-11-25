import Foundation

/// Action-level provider selection follows the source account form: country
/// restrictions govern company lookup, but any VAT provider can verify VAT.
struct NativeCompanyRegistry {
    struct Provider {
        let countries: [String]
        let lookup: (String, String) async throws -> NativePluginRecord?
        var validateVat: ((String) async throws -> Bool)? = nil
    }
    enum VatResult: String { case valid, invalid, unavailable, noProvider, noPrefix }
    let authenticate: () throws -> Void
    let providers: () throws -> [Provider]
    var log: (String) -> Void = { _ in }
    func countries() throws -> [String] {
        try authenticate()
        return Array(Set(try providers().flatMap(\.countries))).sorted()
    }
    func canValidateVat() throws -> Bool {
        try authenticate()
        return try providers().contains { $0.validateVat != nil }
    }
    func lookup(country: String, number: String) async throws -> NativePluginRecord? {
        try authenticate()
        let cc = country.trimmingCharacters(in: NativeAres.whitespace).uppercased()
        guard let provider = try providers().first(where: { $0.countries.contains(cc) }) else { return nil }
        do { return try await provider.lookup(number.trimmingCharacters(in: NativeAres.whitespace), cc) }
        catch is CancellationError { throw CancellationError() }
        catch { log("Registry lookup failed: " + error.localizedDescription); return nil }
    }
    func validateVat(_ vat: String) async throws -> VatResult {
        try authenticate()
        let value = NativeAres.removeWhitespace(vat)
        let prefix = Array(value.utf8.prefix(2))
        guard prefix.count == 2, prefix.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else { return .noPrefix }
        guard let provider = try providers().first(where: { $0.validateVat != nil }), let validate = provider.validateVat else { return .noProvider }
        do { return try await validate(value) ? .valid : .invalid }
        catch is CancellationError { throw CancellationError() }
        catch { log("VAT validation failed: " + error.localizedDescription); return .unavailable }
    }
}
