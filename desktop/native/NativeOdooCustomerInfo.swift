import Foundation

enum NativeOdooCustomerInfo {
    typealias Row = NativePluginRecord
    typealias M = NativeOdooMap
    static let invoiceFields=["name","move_type","commercial_partner_id","invoice_date","invoice_date_due","currency_id","amount_total","amount_residual"]
    static func round2(_ n:Double)->Double { let scaled=n*100,down=floor(scaled);return (scaled-down>=0.5 ? down+1:down)/100 }
    static func sync(_ ctx:NativePluginContext,_ client:NativeOdooClient,dry:Bool,now:Date,linked:[(Double,String)],orders:[Row],commercial:[Double:Double]) async throws {
        if dry || linked.isEmpty { return }
        let rows=try await client.rows("account.move","search_read",["domain":[["move_type","in",["out_invoice","out_refund"]],["state","=","posted"],["payment_state","in",["not_paid","partial"]],["commercial_partner_id","in",linked.map(\.0)]],"fields":invoiceFields,"order":"invoice_date_due asc, id asc"])
        var invoices:[Double:[Row]]=[:]
        for row in rows { let p=M.id(row["commercial_partner_id"]) ?? 0
            invoices[p,default:[]].append(["number":row["name"] ?? NSNull(),"type":row["move_type"] ?? NSNull(),"date":M.or(row["invoice_date"],NSNull()),"due":M.or(row["invoice_date_due"],NSNull()),"currency":M.label(row["currency_id"]) ?? "","amount":row["amount_total"] ?? NSNull(),"residual":row["amount_residual"] ?? NSNull()])
        }
        let from=NativePluginJSON.civilDay(Int(floor(now.timeIntervalSince1970/86400))).year-1
        var totals:[Double:[String:Double]]=[:]
        for row in orders { let year=M.number(String(M.string(row["date_order"]).prefix(4)));if year<Double(from) { continue };guard let partner=M.id(row["partner_id"]) else { continue }
            let owner=commercial[partner] ?? partner,key=M.string(year)+"|"+M.string(M.label(row["currency_id"]) ?? "")
            totals[owner,default:[:]][key,default:0] += M.number(row["amount_untaxed"])
        }
        for (partner,account) in linked {
            let amounts:[Row]=(totals[partner] ?? [:]).map { key,value in let parts=key.components(separatedBy:"|");return ["year":M.number(parts[0]),"currency":parts.count>1 ? parts[1]:"","amount":round2(value)] }.sorted {
                let a=M.number($0["year"]),b=M.number($1["year"]);if a != b { return a>b };return M.string($0["currency"]).compare(M.string($1["currency"]),locale:Locale(identifier:"en")) == .orderedAscending
            }
            try ctx.store.set(NativeOdooSupport.key("customer",account),["at":NativePluginJSON.stamp(now),"invoices":invoices[partner] ?? [],"totals":amounts])
        }
    }
}
