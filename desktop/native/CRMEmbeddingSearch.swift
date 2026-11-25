import Foundation

extension CRMService {
    /// Apply parent permissions before ranking, so inaccessible nearest matches
    /// cannot consume the result limit. Recheck current permissions at return.
    func semanticMatches(_ kind: NativeEmbeddingKind, query: NativeEmbeddingVector, limit: Int = 10, minimumSimilarity: Double? = nil) throws -> NativeEmbeddingMatches {
        try authenticated()
        let index = NativeEmbeddingIndex(db: db)
        let matches = try index.nearest(kind, query: query, parentScope: scope(kind.parent), limit: limit, minimumSimilarity: minimumSimilarity, validate: { try self.authenticated() })
        return try db.transaction {
            try authenticated()
            var visible: [NativeEmbeddingHit] = []
            for hit in matches.hits {
                let currentScope = RecordFilter.every([scope(kind.parent), kind.visibleParent, .equal("id", .text(hit.id))])
                if try !db.keysetPage(kind.parent, fields: [], filter: currentScope, limit: 1).isEmpty { visible.append(hit) }
            }
            return NativeEmbeddingMatches(hits: visible, scanned: matches.scanned, malformed: matches.malformed)
        }
    }
}
