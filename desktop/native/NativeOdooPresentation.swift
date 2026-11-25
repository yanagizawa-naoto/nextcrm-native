import Foundation

/// Read-only Odoo presentation. It deliberately never opens the secret store or
/// constructs the network-enabled host context used by background jobs.
enum NativeOdooPresentation {
    typealias Row = NativePluginRecord
    typealias P = NativePluginPresentation
    static func build(service:CRMService,host:NativePluginHost,location:NativePluginLocation)throws->P? {
        guard service.db === host.db else { throw NativeDBError.message("表示するCRMデータが一致しません。") }
        return try service.db.transaction {
            try service.authenticated()
            guard let definition=host.definition("odoo-connector"),let installed=try host.state(definition.id),installed["status"] == .text("ENABLED") else { return nil }
            let settings=definition.settings.stored(try NativePluginJSON.parse(installed["settings"].string)) { _,_ in }
            let context=NativePluginContext(definition:definition,actor:.init(type:.user,userId:service.identity.id,role:service.identity.role),locale:"ja",settings:settings,secrets:[:],store:NativePluginStore(db:service.db,pluginId:definition.id,clock:host.clock),data:NativePluginData(db:service.db,pluginId:definition.id,permissions:definition.permissions,clock:host.clock),clock:host.clock,logger:{ _,_,_ in },translator:{ key,params in host.translate(definition.id,key,params,"ja") },notification:{ _ in throw NativeDBError.message("表示中は通知を送信できません。") },transport:{ _ in throw NativeDBError.message("表示中は外部へ接続できません。") },persistAfterTransaction:{ _ in })
            let builder=Builder(service:service,definition:definition,context:context,secretReference:installed["secrets"].string)
            return try builder.build(location)
        }
    }
    private final class Builder {
        let service:CRMService,definition:NativePluginDefinition,ctx:NativePluginContext,secretReference:String
        var sections:[P.Section]=[]
        private let amountFormatter:NumberFormatter = {
            let formatter=NumberFormatter();formatter.locale=Locale(identifier:"ja_JP");formatter.numberStyle = .decimal;formatter.minimumFractionDigits=2;formatter.maximumFractionDigits=2;return formatter
        }()
        init(service:CRMService,definition:NativePluginDefinition,context:NativePluginContext,secretReference:String) { self.service=service;self.definition=definition;ctx=context;self.secretReference=secretReference }
        func visible(_ kind:NativePluginSlot.Kind,_ id:String="odoo")->Bool { definition.slots.contains { $0.kind==kind && $0.id==id && $0.roles.contains(service.identity.role) } }
        func allowed(_ yes:Bool)throws { guard yes else { throw NativeDBError.message("このOdoo連携情報を表示する権限がありません。") } }
        func build(_ location:NativePluginLocation)throws->P? {
            switch location {
            case .admin:
                try allowed(service.identity.role=="admin" && visible(.adminSection));try admin();return P(title:"Odoo連携の状況",sections:sections)
            case let .account(id):
                let panel=visible(.accountPanel),tab=visible(.accountTab);try allowed(panel || tab)
                try service.assertAccess("crm_Accounts",id:id)
                var found=false
                if panel,let data=try NativeOdooViews.accountPanel(ctx,id:id) { accountPanel(data);found=true }
                if tab,let data=try NativeOdooViews.accountTab(ctx,id:id,now:ctx.clock()) { try accountTab(data);found=true }
                return found ? P(title:"取引先のOdoo情報",sections:sections):nil
            case let .product(id):
                try allowed(visible(.productPanel));try service.assertAccess("crm_Products",id:id)
                guard let data=try NativeOdooViews.productPanel(ctx,id:id) else { return nil }
                add("Odooの商品",["項目","内容"],[[cell("商品"),cell("Odoo商品 #"+text(data["odooId"]),url:remote("/web#model=product.product&id="+identifier(data["odooId"])+"&view_type=form"))],[cell("最終同期"),cell(time(data["syncedAt"]))]])
                return P(title:"商品のOdoo情報",sections:sections)
            case let .order(id):
                try allowed(visible(.orderPanel));try service.assertAccess("crm_Orders",id:id)
                guard let order=try service.db.get("crm_Orders",key:["id":.text(id)]) else { return nil }
                try service.assertAccess("crm_Accounts",id:order["accountId"].string)
                if order["contactId"] != .null { try service.assertAccess("crm_Contacts",id:order["contactId"].string) }
                guard let data=try NativeOdooViews.orderPanel(ctx,id:id) else { return nil }
                orderPanel(data,currency:order["currency"].string);return P(title:"受注のOdoo情報",sections:sections)
            case let .page(path):
                guard path=="needs-owner" else { return nil };try allowed(visible(.page,path))
                var rows:[[P.Cell]]=[]
                for item in try NativeOdooViews.needsOwner(ctx) { guard let id=item["accountId"] as? String,canRead("crm_Accounts",id) else { continue };rows.append([record(text(item["name"]),"crm_Accounts",id),cell(text(item["salesperson"]))]) }
                add("担当者未設定の取引先",["取引先","Odooの営業担当者"],rows,empty:"取得した取引先にはすべて担当者がいます。")
                return P(title:"Odoo・担当者未設定の取引先",sections:sections)
            }
        }
        func add(_ title:String,_ columns:[String],_ rows:[[P.Cell]],empty:String="該当する情報はありません。") { sections.append(.init(title:title,columns:columns,rows:rows,empty:empty)) }
        func pair(_ label:String,_ value:String)->[P.Cell] { [cell(label),cell(value)] }
        func cell(_ value:String,url:URL?=nil)->P.Cell { .init(text(value),url:url) }
        func record(_ name:String,_ model:String,_ id:String)->P.Cell { .init(text(name),record:.init(model:model,id:id)) }
        func canRead(_ model:String,_ id:String)->Bool { (try? service.assertAccess(model,id:id)) != nil }
        func row(_ value:Any?)->Row { value as? Row ?? [:] }
        func rows(_ value:Any?)->[Row] { value as? [Row] ?? [] }
        func yes(_ value:Any?)->Bool { NativePluginJSON.truthy(value) }
        func identifier(_ value:Any?)->String { let number=NativeOdooMap.number(value);return number.isFinite && number>=0 && number.rounded(.towardZero)==number ? NativePluginJSON.numberString(number):"" }
        func text(_ value:Any?)->String {
            guard let value,!(value is NSNull) else { return "—" }
            var result:String
            if let string=value as? String { result=string } else if let number=value as? NSNumber { result=NativePluginJSON.string(number) } else { return "—" }
            let raw=result.trimmingCharacters(in:.whitespacesAndNewlines)
            if (raw.hasPrefix("{") || raw.hasPrefix("[")),(try? JSONSerialization.jsonObject(with:Data(raw.utf8))) != nil { return "詳細データは表示対象外です。" }
            if !secretReference.isEmpty { result=result.replacingOccurrences(of:secretReference,with:"[非表示]") }
            for pattern in [#"(?i)https?://[^\s/@:]+:[^\s/@]+@"#,#"(?i)\b(?:bearer\s+|(?:api[_ -]?key|authorization|password|secret|token)\s*[=:]\s*)[^\s,;]+"#,#"(?i)\b(?:keychain|credential|secret-ref):[^\s]+"#,#"\b[0-9A-Fa-f]{40,}\b"#] { result=result.replacingOccurrences(of:pattern,with:"[認証情報は非表示]",options:.regularExpression) }
            let trimmed=result.trimmingCharacters(in:.whitespacesAndNewlines)
            // A serialized object is diagnostic data, never a table label.
            if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),(try? JSONSerialization.jsonObject(with:Data(trimmed.utf8))) != nil { return "詳細データは表示対象外です。" }
            return trimmed.isEmpty ? "—":String(trimmed.prefix(4096))
        }
        func remote(_ suffix:String)->URL? {
            guard let raw=ctx.settings["url"] as? String,var base=URLComponents(string:raw),base.scheme?.lowercased()=="https",base.host?.isEmpty==false,base.user==nil,base.password==nil,base.query==nil,base.fragment==nil else { return nil }
            base.path=base.path.replacingOccurrences(of:#"/+$"#,with:"",options:.regularExpression)
            guard let prefix=base.url?.absoluteString,!((prefix+suffix).contains(secretReference.isEmpty ? "\0":secretReference)) else { return nil }
            return URL(string:prefix+suffix)
        }
        func time(_ value:Any?)->String {
            guard let raw=value as? String,let date=try? NativePluginJSON.date(raw),let parts=try? NativeOdooMap.localParts(date,zone:NativePluginJSON.string(ctx.settings["timeZone"])) else { return "—" }
            return parts.day.replacingOccurrences(of:"-",with:"/")+String(parts.time.dropFirst(parts.day.count))
        }
        func day(_ value:Any?)->String { let raw=text(value);return raw=="—" ? raw:String(raw.prefix(10)).replacingOccurrences(of:"-",with:"/") }
        func money(_ value:Any?,_ currency:Any?=nil,sign:Double=1)->String {
            let number=NativeOdooMap.number(value);guard value != nil,!(value is NSNull),number.isFinite else { return "—" }
            let decimal=NSDecimalNumber(string:NativeOdooMap.fixed(number*sign,digits:2)),amount=amountFormatter.string(from:decimal) ?? decimal.stringValue,code=text(currency)
            return amount+(code=="—" ? "":" "+code)
        }
        func state(_ value:Any?)->String {
            let raw=text(value)
            return ["DRAFT":"下書き","PENDING_APPROVAL":"承認待ち","READY":"手配可能","SENT":"送信済み","CONFIRMED":"受注確定","DELIVERED":"納品済み","INVOICED":"請求済み","PAID":"入金済み","CANCELLED":"取消済み","SYNC_FAILED":"同期失敗","draft":"下書き","sent":"見積送付済み","sale":"受注確定","done":"完了","cancel":"取消済み","missing":"Odooで見つかりません","waiting":"待機中","confirmed":"確認済み","assigned":"出荷準備済み","not_paid":"未入金","in_payment":"入金処理中","paid":"入金済み","partial":"一部入金","reversed":"取消済み","blocked":"支払保留"][raw] ?? raw
        }
        func error(_ value:Any?)->String {
            let raw=text(value)
            if raw=="Odoo rejected the API key" { return "OdooのAPIキーが拒否されました。接続設定を確認してください。" }
            if raw.hasPrefix("Odoo denied access: ") { return "Odooでアクセスが拒否されました："+String(raw.dropFirst(20)) }
            if raw.hasPrefix("Odoo unreachable: ") { return "Odooに接続できません："+String(raw.dropFirst(18)) }
            if raw.hasPrefix("Odoo error ") { return "Odooからエラーが返されました（HTTP "+String(raw.dropFirst(11))+"）" }
            for (prefix,label) in [("compute_price ","未対応の価格計算方法："),("base ","未対応の基準価格："),("applied_on ","未対応のルール適用範囲：")] where raw.hasPrefix(prefix) { return label+String(raw.dropFirst(prefix.count)) }
            if raw.hasPrefix("variant rule "),let number=raw.split(separator:" ").dropFirst(2).first { return "同じ商品にバリエーション別ルール（"+number+"）があります。CRMとOdooで適用されるルールが異なる場合があります。" }
            return raw
        }
        func accountPanel(_ data:Row) {
            var items:[[P.Cell]]=[[cell("連携先"),cell("Odooパートナー #"+text(data["partnerId"]),url:remote("/odoo/contacts/"+identifier(data["partnerId"])))],pair("最終同期",time(data["syncedAt"])),pair("Odooで管理する項目","名称・登録番号・税務番号・請求先住所・メール・電話")]
            if let price=data["priceList"] as? Row { items.append(pair("価格表",text(price["name"])+(yes(price["imported"]) ? "（取得済み）":"（未取得）"))) }
            if yes(data["archived"]) { items.append(pair("状態","Odooでアーカイブ済みです。")) } else if yes(data["notCustomer"]) { items.append(pair("状態","Odooでは顧客ではなくなっています。")) }
            add("取引先との連携",["項目","内容"],items)
        }
        func accountTab(_ data:Row)throws {
            add("取得状況",["項目","内容"],[pair("情報の取得日時",time(data["at"])),[cell("Odooの受注"),cell("Odooですべての受注を確認",url:remote("/odoo/contacts/"+identifier(data["partnerId"])))]] )
            var orders:[[P.Cell]]=[]
            for item in rows(data["orders"]) { guard let id=item["orderId"] as? String,canRead("crm_Orders",id) else { continue };orders.append([record(text(item["number"]),"crm_Orders",id),cell(text(item["odooName"])),cell(day(item["date"])),cell(money(item["total"],item["currency"])),cell(state(item["status"])),cell(yes(item["imported"]) ? "Odooから取得":"CRMから送信")]) }
            add("受注",["番号","Odoo受注","日付","税抜合計","状態","連携区分"],orders,empty:"表示できるOdoo連携受注はありません。")
            add("未入金残高",["通貨","未入金"],rows(data["owed"]).map { [cell(text($0["currency"])),cell(money($0["amount"],$0["currency"]))] },empty:"未入金はありません。")
            add("未入金の請求書",["番号","区分","請求日","支払期限","期限超過","合計","未入金"],rows(data["invoices"]).map { item in
                let sign=NativeOdooMap.number(item["sign"]),days=NativeOdooMap.number(item["overdueDays"])
                return [cell(text(item["number"])),cell(sign<0 ? "返金・貸方":"請求書"),cell(day(item["date"])),cell(day(item["due"])),cell(days>0 ? text(days)+"日":"—"),cell(money(item["amount"],item["currency"],sign:sign)),cell(money(item["residual"],item["currency"],sign:sign))]
            },empty:"未入金の請求書はありません。")
            add("確定受注の税抜合計",["年","通貨","合計"],rows(data["totals"]).map { [cell(text($0["year"])+"年"),cell(text($0["currency"])),cell(money($0["amount"],$0["currency"]))] })
        }
        func orderPanel(_ data:Row,currency:String) {
            if let link=data["link"] as? Row {
                var items:[[P.Cell]]=[[cell("Odoo受注"),cell(text(link["name"]),url:remote("/odoo/action-sale.action_orders/"+identifier(link["odooId"])))],pair("Odooの状態",state(link["state"])),pair("連携区分",yes(link["imported"]) ? "Odooから取得":"CRMから送信"),pair("送信・取込日時",time(link["sentAt"])),pair("最終確認",time(link["checkedAt"]))]
                if text(link["state"])=="missing" { items.append(pair("確認事項","Odoo側での削除、またはAPIユーザーの権限不足が考えられます。CRMの状態は維持されます。")) }
                if yes(link["movedNotified"]) { items.append(pair("顧客の変更","Odooで顧客が変更されています。CRMの取引先は維持されています。")) }
                for kind in link["created"] as? [String] ?? [] { items.append(pair("Odooで作成済み",kind=="customer" ? "顧客":kind=="delivery" ? "納品先住所":text(kind))) }
                if yes(link["totalDiffers"]) { items.append(pair("合計金額の差","Odooの合計 "+money(link["total"],currency)+" はCRMの合計と異なります。")) }
                if let missing=link["missing"],NativeOdooMap.number(missing)>0 { items.append(pair("未取得の明細",text(missing)+"行（対応する商品を取得後に再確認します）")) }
                add("受注との連携",["項目","内容"],items)
                add("Odooとの価格差",["商品コード","CRM単価","Odoo単価"],rows(link["priceDiffs"]).map { [cell(text($0["sku"])),cell(money($0["crm"],currency)),cell(money($0["odoo"],currency))] },empty:"価格差は報告されていません。")
                add("出荷",["出荷番号","状態","日付"],rows(link["deliveries"]).map { [cell(text($0["name"])),cell(state($0["state"])),cell(day($0["date"]))] })
                add("請求書",["番号","支払期限","金額","未入金","入金状態"],rows(link["invoices"]).map { [cell(text($0["number"])),cell(day($0["due"])),cell(money($0["amount"],$0["currency"] ?? currency)),cell(money($0["residual"],$0["currency"] ?? currency)),cell(state($0["paymentState"]))] })
            }
            if let waiting=data["waiting"] as? Row { add("送信待ち",["項目","内容"],[pair("待機開始",time(waiting["waitingSince"])),pair("試行回数",text(waiting["attempts"])),pair("直近のエラー",error(waiting["lastError"]))]) }
            if let failed=data["failed"] as? Row { add("送信失敗",["日時","理由"],[[cell(time(failed["at"])),cell(error(failed["reason"]))]]) }
        }
        func admin()throws {
            let last=try ctx.store.get("meta:lastRun") as? Row,catalog=try NativeOdooViews.catalog(ctx),orders=try NativeOdooViews.orders(ctx,now:ctx.clock())
            var summary=[pair("実行モード",yes(ctx.settings["dryRun"]) ? "試行モード（変更予定のみ。データは取り込みません）":"通常同期"),pair("同期間隔",text(ctx.settings["syncMinutes"])+"分"),pair("タイムゾーン",text(ctx.settings["timeZone"])),pair("前回の実行",last.map { time($0["at"]) } ?? "未実行")]
            if let last {
                summary.append(pair("実行結果",yes(last["ok"]) ? "成功":"失敗"))
                if let at=last["at"] as? String,let date=try? NativePluginJSON.date(at) { summary.append(pair("次回の実行予定",time(NativePluginJSON.stamp(date.addingTimeInterval(NativeOdooMap.number(ctx.settings["syncMinutes"])*60))))) }
                for (key,label) in [("created","新規"),("updated","更新"),("unchanged","変更なし"),("skipped","スキップ"),("conflicts","競合"),("failed","失敗")] { summary.append(pair(label,text(last[key])+"件")) }
                if let errorValue=last["error"] { summary.append(pair("エラー",error(errorValue))) }
                if let counts=last["orders"] as? Row { for (key,label) in [("checked","受注確認"),("moved","受注の状態変更"),("imported","受注の取込")] where counts[key] != nil { summary.append(pair(label,text(counts[key])+"件")) } }
            }
            let queued=row(catalog["queued"]);summary += [pair("同期の予約",yes(queued["sync"]) ? "予約済み":"なし"),pair("比較の予約",yes(queued["compare"]) ? "予約済み":"なし")]
            if let lock=try ctx.store.get("meta:lock") as? Row { summary.append(pair("処理の占有期限",time(lock["until"]))) }
            add("同期状況",["項目","内容"],summary)
            var conflicts:[[P.Cell]]=[]
            for entry in try ctx.store.list("conflict:") { let item=row(entry.value),reason=["number":"登録番号が一致","vat":"税務番号が一致","linked":"別のOdoo顧客と連携済み"][text(item["reason"])] ?? text(item["reason"]);var candidates:[P.Cell]=[]
                for id in item["candidates"] as? [String] ?? [] where canRead("crm_Accounts",id) { if let a=try service.db.get("crm_Accounts",key:["id":.text(id)]) { candidates.append(record(a["name"].string,"crm_Accounts",id)) } }
                if candidates.isEmpty { candidates=[cell("閲覧できる候補がありません")] }
                for candidate in candidates { conflicts.append([cell(text(item["name"]),url:remote("/odoo/contacts/"+identifier(item["partnerId"]))),cell(reason),candidate]) }
            }
            add("複数の取引先に一致する顧客",["Odoo顧客","理由","CRMの候補"],conflicts,empty:"競合はありません。")
            if let counts=last?["catalog"] as? Row {
                var values:[[P.Cell]]=[];for (key,label) in [("categories","カテゴリ"),("productsCreated","商品新規"),("productsUpdated","商品更新"),("productsFailed","商品失敗"),("listsReplaced","価格表置換"),("accountLists","取引先価格表設定")] { values.append(pair(label,text(counts[key])+"件")) }
                if let missing=counts["listsMissing"] as? [Any],!missing.isEmpty { values.append(pair("見つからないOdoo価格表",missing.map(text).joined(separator:", "))) };add("商品・価格表の同期",["項目","件数"],values)
            }
            add("価格表の取得状況",["項目","内容"],[pair("取得日時",time(catalog["loadedAt"])),pair("設定方法","設定の「価格表」にOdooの価格表番号をカンマ区切りで指定します。基準価格表も自動取得します。")])
            add("Odooの価格表",["選択","番号","名前","通貨","ルール数","状態"],rows(catalog["lists"]).map { [cell(yes($0["chosen"]) ? "選択済み":"—"),cell(text($0["id"])),cell(text($0["name"])),cell(text($0["currency"])),cell(text($0["rules"])),cell(yes($0["active"]) ? "有効":"無効")] },empty:"「価格表を取得」でOdooの価格表を確認できます。")
            add("CRMでは使用できない価格ルール",["価格表","ルール番号","理由"],rows(catalog["skipped"]).map { [cell(text($0["list"])),cell(text($0["ruleId"])),cell(error($0["reason"]))] })
            let comparisonIndex=sections.count
            var comparison:[[P.Cell]]=[]
            if let progress=catalog["progress"] as? Row { comparison.append(pair("比較の進捗",text(progress["total"])+"件中 "+text(progress["done"])+"件")) }
            if let result=catalog["compare"] as? Row {
                comparison += [pair("最終比較",time(result["at"])),pair("結果",yes(result["ok"]) ? "完了":"失敗")]
                if let value=result["error"] { comparison.append(pair("エラー",error(value))) }
                add("価格表ごとの比較",["価格表","確認件数","一致","差分"],rows(result["lists"]).map { [cell(text($0["name"])),cell(text($0["checked"])),cell(text(NativeOdooMap.number($0["checked"])-NativeOdooMap.number($0["failed"]))),cell(text($0["failed"]))] })
                add("価格比較の差分",["価格表","商品","数量","CRM","Odoo","差額","理由","詳細"],rows(result["mismatches"]).map { [cell(text($0["list"])),cell(text($0["product"])),cell(text($0["quantity"])),cell(text($0["crm"])),cell(text($0["odoo"])),cell(text($0["diff"])),cell(text($0["reason"])=="rate" ? "為替レート":"価格ルール"),cell(error($0["error"]))] },empty:"価格の差分はありません。")
            }
            add("価格比較の状況",["項目","内容"],comparison,empty:"まだ価格を比較していません。")
            let comparisonSummary=sections.removeLast();sections.insert(comparisonSummary,at:comparisonIndex)
            let imported=row(orders["imported"])
            var orderSummary=[pair("CRMからの受注送信",yes(orders["enabled"]) ? "有効":"無効"),pair("送信待ち",text(orders["waiting"])+"件"),pair("過去7日間の送信",text(orders["sent"])+"件"),pair("送信失敗",text(rows(orders["failed"]).count)+"件"),pair("Odooからの取込累計",text(imported["total"])+"件"),pair("前回の取込",text(imported["lastRun"])+"件")]
            if let paused=orders["paused"] as? Row { orderSummary += [pair("送信停止の開始",time(paused["at"])),pair("送信停止の理由",error(paused["reason"])),pair("再開方法","Odooユーザーの権限と接続設定を確認し、「接続をテスト」を実行してください。") ] }
            add("受注の連携状況",["項目","内容"],orderSummary)
            var failures:[[P.Cell]]=[]
            for item in rows(orders["failed"]) { let id=item["orderId"] as? String ?? "";guard canRead("crm_Orders",id),let order=try service.db.get("crm_Orders",key:["id":.text(id)]),canRead("crm_Accounts",order["accountId"].string) else { continue };failures.append([record(text(item["number"]),"crm_Orders",id),cell(time(item["at"])),cell(error(item["reason"]))]) }
            add("送信できなかった受注",["受注番号","日時","理由"],failures)
            add("Odooから取得できなかった受注",["Odoo受注","日時","理由"],rows(imported["failed"]).map { [cell(text($0["name"]),url:remote("/odoo/action-sale.action_orders/"+identifier($0["odooId"]))),cell(time($0["at"])),cell(error($0["reason"]))] })
            add("Odooで作成済み",["日時","種類","名前","Odoo番号","受注番号"],rows(orders["created"]).map { [cell(time($0["at"])),cell(text($0["kind"])=="customer" ? "顧客":"納品先住所"),cell(text($0["name"]),url:remote("/odoo/contacts/"+identifier($0["odooId"]))),cell(text($0["odooId"])),cell(text($0["orderNumber"]))] })
        }
    }
}
