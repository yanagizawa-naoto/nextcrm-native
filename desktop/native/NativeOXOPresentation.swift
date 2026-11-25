import Foundation

/// Read-only, Japanese projections of the original OXO account/product/order,
/// administrator and needs-owner slots. No secret is loaded to render a view.
enum NativeOXOPresentation {
    typealias Row=NativePluginRecord
    typealias P=NativePluginPresentation
    typealias M=NativeOXOMap
    static let pluginID="oxo-erp-connector"

    static func build(service:CRMService,host:NativePluginHost,location:NativePluginLocation) throws -> P? {
        guard service.db === host.db else { throw NativeDBError.message("表示対象のデータベースが一致しません。") }
        return try service.db.transaction {
            try service.authenticated()
            guard let definition=host.definition(pluginID),let installed=try host.state(pluginID),installed["status"] == .text("ENABLED") else { return nil }
            let role=service.identity.role
            func available(_ kind:NativePluginSlot.Kind,_ id:String?=nil) -> [NativePluginSlot] { definition.slots.filter{$0.kind==kind && (id==nil || $0.id==id)} }
            func permitted(_ slots:[NativePluginSlot]) throws -> Bool {
                if slots.isEmpty { return false }
                guard slots.contains(where:{$0.roles.contains(role)}) else { throw NativeDBError.message("この拡張機能を表示する権限がありません。") };return true
            }
            var accountPanel=false,accountTab=false
            switch location {
            case .admin:
                guard try permitted(available(.adminSection)) else { return nil }
                guard role=="admin" else { throw NativeDBError.message("管理者のみ連携の状況を確認できます。") }
            case let .account(id):
                let panel=available(.accountPanel),tab=available(.accountTab)
                guard !(panel+tab).isEmpty else { return nil }
                _ = try permitted(panel+tab);accountPanel=panel.contains{$0.roles.contains(role)};accountTab=tab.contains{$0.roles.contains(role)}
                try service.assertAccess("crm_Accounts",id:id)
            case let .product(id):guard try permitted(available(.productPanel)) else { return nil };try service.assertAccess("crm_Products",id:id)
            case let .order(id):guard try permitted(available(.orderPanel)) else { return nil };try service.assertAccess("crm_Orders",id:id)
            case let .page(path):guard path=="needs-owner",try permitted(available(.page,path)) else { return nil }
            }
            let raw=try NativePluginJSON.parse(installed["settings"].string)
            let settings=definition.settings.stored(raw){_,_ in}
            var viewDefinition=definition
            viewDefinition.permissions=definition.permissions.filter{$0.hasSuffix(":read")}
            let data=NativePluginData(db:service.db,pluginId:pluginID,permissions:viewDefinition.permissions,clock:host.clock)
            let context=NativePluginContext(definition:viewDefinition,actor:.init(type:.user,userId:service.identity.id,role:role),locale:"ja",settings:settings,secrets:[:],store:NativePluginStore(db:service.db,pluginId:pluginID,clock:host.clock),data:data,clock:host.clock,logger:{_,_,_ in},translator:{key,args in NativePluginMessages.translate(pluginID,key,args,"ja")},notification:{_ in throw NativeDBError.message("表示処理から通知は送信できません。")},transport:{_ in throw NativeDBError.message("表示処理から外部サービスには接続できません。")},persistAfterTransaction:{_ in})
            let view=Builder(service:service,context:context)
            switch location {
            case .admin:return try view.admin()
            case let .account(id):return try view.account(id,panel:accountPanel,tab:accountTab)
            case let .product(id):return try view.product(id)
            case let .order(id):return try view.order(id)
            case .page:return try view.needsOwner()
            }
        }
    }

    static func safe(_ value:Any?,empty:String="—") -> String {
        guard let value,!(value is NSNull) else { return empty }
        guard value is String || value is NSNumber else { return "詳細情報は表示できません。" }
        let raw=M.string(value)
        if raw.isEmpty { return empty }
        return raw.replacingOccurrences(of:#"oxo_[A-Za-z0-9_-]{40}"#,with:"［非表示］",options:.regularExpression)
    }
    static func error(_ value:Any?) -> String {
        let text=safe(value,empty:"詳細はありません。")
        if let object=try? NativePluginJSON.parse(text),object is Row || object is [Any] {
            if let row=object as? Row,let message=row["message"] as? String { return safe(message) }
            return "提供元からエラーが返されました。接続設定を確認してください。"
        }
        return text.replacingOccurrences(of:"OXO ERP unreachable: ",with:"OXO ERPに接続できません：").replacingOccurrences(of:"OXO ERP error ",with:"OXO ERPからのエラー ")
    }
    static func state(_ value:Any?,crm:Bool=false,deliveryRecord:Bool=false) -> String {
        let raw=safe(value)
        let crmNames=["DRAFT":"下書き","PENDING_APPROVAL":"承認待ち","READY":"手配可能","SENT":"送信済み","CONFIRMED":"確定","DELIVERED":"納品済み","INVOICED":"請求済み","PAID":"入金済み","CANCELLED":"取消済み","SYNC_FAILED":"同期失敗"]
        let erp=["draft":"下書き","sent":"見積送付済み","sale":"受注確定","done":"完了","cancel":"取消済み","missing":"OXO ERPに見つかりません","waiting":"前工程待ち","confirmed":"待機中","assigned":"出荷準備完了"]
        return (crm ? crmNames[raw]:erp[raw]) ?? (raw=="—" ? raw:"不明な状態（\(raw)）")
    }
    static func delivery(_ value:Any?) -> String { let raw=safe(value);return ["none":"未出荷","partial":"一部出荷","full":"出荷済み"][raw] ?? (raw=="—" ? raw:"不明な納品状況（\(raw)）") }
    static func day(_ value:Any?) -> String {
        guard let value=value as? String else{return "—"}
        let text=String(value.prefix(10)),parts=text.split(separator:"-")
        guard parts.count==3,let year=Int(parts[0]),let month=Int(parts[1]),let day=Int(parts[2]),(1...12).contains(month),(1...31).contains(day) else{return "日付不明"}
        return "\(year)年\(month)月\(day)日"
    }
    static func amount(_ value:Any?,currency:Any?) -> String {
        let number=M.number(value);guard number.isFinite else{return "金額不明"}
        let rounded=NSDecimalNumber(string:NativeOdooMap.fixed(number,digits:2)),formatter=NumberFormatter()
        formatter.locale=Locale(identifier:"ja_JP");formatter.numberStyle = .decimal;formatter.minimumFractionDigits=2;formatter.maximumFractionDigits=2
        return (formatter.string(from:rounded) ?? rounded.stringValue)+" "+safe(currency)
    }
    static func externalURL(_ value:Any?) -> URL? {
        guard let text=value as? String,let url=URL(string:text),["https","http"].contains(url.scheme?.lowercased() ?? ""),let host=url.host,!host.isEmpty,url.user==nil,url.password==nil,!text.contains("\n"),!text.contains("\r"),text.range(of:#"oxo_[A-Za-z0-9_-]{40}"#,options:.regularExpression)==nil else{return nil}
        let sensitive=Set(["apikey","api_key","token","secret","password","access_token"])
        if (URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []).contains(where:{sensitive.contains($0.name.lowercased())}) { return nil }
        return url
    }
    private struct Builder {
        let service:CRMService,context:NativePluginContext
        var connector:NativeOXOConnector { NativeOXOConnector(context) }
        func t(_ key:String,_ args:Row?=nil) -> String { context.t(key,args) }
        func text(_ value:Any?,empty:String="—") -> P.Cell { .init(safe(value,empty:empty)) }
        func info(_ title:String,_ rows:[(String,String)]) -> P.Section { .init(title:title,columns:["項目","内容"],rows:rows.map{[.init($0.0),.init($0.1)]}) }
        func time(_ value:Any?) -> String {
            guard let value=value as? String else{return "—"}
            guard let raw=try? M.localTime(value,zone:M.string(context.settings["timeZone"])) else{return "日時不明"}
            guard let split=raw.range(of:" ") else{return "日時不明"}
            return day(String(raw[..<split.lowerBound]))+String(raw[split.lowerBound...])
        }
        func visible(_ model:String,_ id:String) -> Bool { (try? service.assertAccess(model,id:id)) != nil }
        func accountName(_ value:Any?) -> String {
            guard let id=value as? String,visible("crm_Accounts",id),let record=try? service.db.get("crm_Accounts",key:["id":.text(id)]) else { return "取引先を確認できません" }
            return safe(record["name"].string,empty:"名称未設定")
        }
        func recordCell(_ model:String,_ id:Any?,_ label:String) -> P.Cell {
            guard let id=id as? String,visible(model,id) else{return .init(label)}
            return .init(label,record:.init(model:model,id:id))
        }
        func countRows(_ values:Row,_ labels:[(String,String)]) -> [[P.Cell]] { labels.map{[.init($0.1),.init(safe(values[$0.0],empty:"0")+"件")]} }
        func summary(_ summary:Row,_ title:String) -> [P.Section] {
            var parts=[info(title,[("実行日時",time(summary["at"])),("結果",M.truth(summary["ok"]) ? "成功":"失敗"),("実行モード",M.truth(summary["dryRun"]) ? "試行（変更予定の確認）":"同期（データを更新）")])]
            if !M.truth(summary["ok"]) { parts.append(info("エラー",[("内容",error(summary["error"]))])) }
            if let counts=summary["customers"] as? Row { parts.append(.init(title:title+"：顧客",columns:["項目","件数"],rows:countRows(counts,[("linked","連携済み"),("number","登録番号一致"),("vat","税務番号一致"),("name","名称・郵便番号一致"),("created","新規"),("updated","更新"),("conflicts","競合"),("skipped","無効"),("failed","失敗")]))) }
            if let counts=summary["catalog"] as? Row {
                parts.append(.init(title:title+"：商品・価格表",columns:["項目","件数"],rows:countRows(counts,[("categoriesMatched","カテゴリ一致"),("categoriesCreated","カテゴリ新規"),("productsUpdated","商品更新"),("productsCreated","商品新規"),("productsFailed","商品失敗"),("listsReplaced","価格表置換"),("accountLists","取引先価格表設定")])))
                if let missing=counts["listsMissing"] as? [Any],!missing.isEmpty { parts.append(info("未取得の価格表",[("OXO ERPにない価格表ID",missing.map{safe($0)}.joined(separator:", "))])) }
            }
            if let counts=summary["orders"] as? Row { parts.append(.init(title:title+"：受注",columns:["項目","件数"],rows:countRows(counts,[("checked","確認"),("moved","状態変更"),("imported","取得"),("updated","更新"),("pending","取引先の連携待ち")]))) }
            return parts
        }
        func account(_ id:String,panel:Bool,tab:Bool) throws -> P? {
            var sections:[P.Section]=[]
            if panel,let data=try connector.panelData(id) as? Row {
                var rows=[("連携先","OXO ERP顧客 #"+safe(data["customerId"])),("最終同期",time(data["syncedAt"])),("管理元",t("panel.fields"))]
                if let list=data["priceList"] as? Row { rows.append(("価格表",M.truth(list["imported"]) ? safe(M.coalesce(list["name"],list["id"] ?? M.null)):"OXO ERPの価格表 #\(safe(list["id"]))は未取得です")) }
                if M.truth(data["inactive"]) { rows.append(("利用状況",t("panel.inactive"))) };sections.append(info("OXO ERPとの連携",rows))
                let addresses=(data["addresses"] as? [Row] ?? []).map{[text($0["text"])]}
                if !addresses.isEmpty { sections.append(.init(title:t("panel.addresses"),columns:["住所"],rows:addresses)) }
            }
            if tab {
                if let data=try connector.accountTabData(id) as? Row {
                    let rows=(data["orders"] as? [Row] ?? []).filter{visible("crm_Orders",M.string($0["orderId"]))}.map{order in [recordCell("crm_Orders",order["orderId"],safe(order["number"])),text(order["oxoNumber"]),.init(day(order["date"])),.init(amount(order["total"],currency:order["currency"])),.init(state(order["status"],crm:true)),.init(delivery(order["delivery"]))]}
                    sections.append(.init(title:"連携された受注（新しい順・最大50件）",columns:["CRM受注番号","OXO ERP受注番号","日付","税抜合計","CRMの状態","納品状況"],rows:rows,empty:t("tab.ordersEmpty")))
                } else { sections.append(info("連携状況",[("顧客連携",t("tab.notLinked"))])) }
            }
            return sections.isEmpty ? nil:P(title:"OXO ERP · "+accountName(id),sections:sections)
        }
        func product(_ id:String) throws -> P? {
            guard let data=try connector.productPanelData(id) as? Row else{return nil}
            return .init(title:"OXO ERP · 商品の連携",sections:[info("連携先",[("商品","OXO ERP商品 #"+safe(data["oxoId"]))])])
        }
        func order(_ id:String) throws -> P? {
            guard let data=try connector.orderPanelData(id) as? Row else{return nil};var sections:[P.Section]=[]
            if let link=data["link"] as? Row {
                let linked=P.Cell("OXO ERP受注 "+safe(link["number"]),url:externalURL(link["url"]))
                var rows:[[P.Cell]]=[[.init("連携先"),linked],[.init("OXO ERPの状態"),.init(state(link["state"]))]]
                if link["state"] as? String != "missing" { rows.append([.init("納品状況"),.init(delivery(link["delivery"]))]) }
                if M.truth(link["imported"]) { rows.append([.init("取得元"),.init(t("order.imported"))]) }
                if let below=link["belowList"] as? [Any],!below.isEmpty { rows.append([.init("OXO ERPの定価未満"),.init(below.map{safe($0)}.joined(separator:", "))]) }
                sections.append(.init(title:"受注の連携状況",columns:["項目","内容"],rows:rows))
                let shipments=(link["deliveries"] as? [Row] ?? []).map{[text($0["number"]),.init(state($0["state"],deliveryRecord:true)),.init(day($0["doneAt"]))]}
                if !shipments.isEmpty { sections.append(.init(title:t("order.deliveries"),columns:["出荷番号","状態","完了日"],rows:shipments)) }
            }
            if let waiting=data["waiting"] as? Row { sections.append(info("送信待ち",[("待機開始",time(waiting["waitingSince"])),("直近のエラー",error(waiting["lastError"]))])) }
            if let failed=data["failed"] as? Row { sections.append(info("未送信",[("原因",error(failed["reason"]))])) }
            return .init(title:"OXO ERP · 受注の連携",sections:sections)
        }
        func needsOwner() throws -> P {
            let rows=try connector.needsOwner().filter{visible("crm_Accounts",M.string($0["accountId"]))}.map{[recordCell("crm_Accounts",$0["accountId"],safe($0["name"]))]}
            return .init(title:t("needsOwner.title"),sections:[info("担当者の設定",[("操作",t("needsOwner.help"))]),.init(title:"担当者未設定の取引先",columns:["取引先名"],rows:rows,empty:t("needsOwner.empty"))])
        }
        func admin() throws -> P {
            var sections:[P.Section]=[]
            let last=try connector.stored("meta:lastRun"),report=try connector.stored("meta:report"),catalog=try connector.catalogData(),orders=try connector.ordersData(context.clock())
            var overview=[("同期モード",M.truth(context.settings["dryRun"]) ? t("admin.dryRun"):"同期を有効にしています。"),("同期の間隔",safe(context.settings["syncMinutes"])+"分"),("前回の実行",last.map{time($0["at"])} ?? t("admin.never"))]
            if !M.truth(context.settings["dryRun"]),let at=last?["at"] as? String,let date=try? NativePluginJSON.date(at) { overview.append(("次回同期の目安",time(NativePluginJSON.stamp(date.addingTimeInterval(M.number(context.settings["syncMinutes"])*60))))) }
            if M.truth(catalog["queued"]) { overview.append(("予約状況",t("admin.queued"))) };sections.append(info("同期の状況",overview))
            if let last { sections += summary(last,"前回の同期結果") }
            if let report {
                sections += summary(report,"前回の試行結果")
                let reportRows=report["rows"] as? Row ?? [:]
                for (key,title) in [("name",t("admin.nameLinks")),("created",t("admin.createdRows"))] {
                    let rows=(reportRows[key] as? [Row] ?? []).map{row in [text(row["name"]),text(row["customerId"]),recordCell("crm_Accounts",row["accountId"],row["accountId"]==nil ? "新規作成予定":accountName(row["accountId"]))]}
                    if !rows.isEmpty { sections.append(.init(title:title,columns:["OXO ERP顧客名","顧客ID","CRM取引先"],rows:rows)) }
                }
            }
            let conflicts=try connector.entries("conflict:").flatMap{entry -> [[P.Cell]] in
                let row=entry.value,reason=M.string(row["reason"]),known=["number","vat","name","linked"].contains(reason),candidates=row["candidates"] as? [Any] ?? []
                let prefix=[text(row["name"]),text(row["customerId"]),P.Cell(known ? t("admin.reason."+reason):safe(reason))]
                return candidates.isEmpty ? [prefix+[.init("該当する取引先がありません")]]:candidates.map{prefix+[recordCell("crm_Accounts",$0,accountName($0))]}
            }
            sections.append(.init(title:t("admin.conflicts"),columns:["OXO ERP顧客名","顧客ID","原因","該当するCRM取引先"],rows:conflicts,empty:t("admin.conflictsEmpty")))
            if !conflicts.isEmpty { sections.append(info("競合の解消",[("対応",t("admin.conflictsHelp"))])) }
            sections.append(info("価格表の取得",[("設定","価格表の設定にOXO ERPの価格表IDをカンマ区切りで入力します（例：3, 7）。基準となる価格表も取得します。"),("最終取得",catalog["loadedAt"] is NSNull ? t("admin.listsNotLoaded"):time(catalog["loadedAt"]))]))
            if let lists=catalog["lists"] as? [Row] { sections.append(.init(title:"OXO ERPの価格表",columns:["取得対象","価格表ID","名称","通貨","ルール数"],rows:lists.map{[.init(M.truth($0["chosen"]) ? "選択済み":"未選択"),text($0["id"]),text($0["name"]),text($0["currency"]),text($0["rules"])]})) }
            if let skipped=catalog["skipped"] as? [Row],!skipped.isEmpty { sections.append(.init(title:t("admin.skippedRules"),columns:["価格表","ルールID","理由"],rows:skipped.map{[text($0["list"]),text($0["ruleId"]),.init(skippedReason($0["reason"]))]})) }
            let failed=orders["failed"] as? [Row] ?? []
            var orderRows=[("受注送信",M.truth(orders["enabled"]) ? "有効":"無効。設定で受注送信を有効にすると、手配可能な受注をOXO ERPへ送信します。")]
            if M.truth(orders["enabled"]) { orderRows += [("送信待ち",safe(orders["waiting"])+"件"),("過去7日間の送信",safe(orders["sent"])+"件"),("送信失敗","\(failed.count)件")] }
            if M.number(orders["pending"])>0 { orderRows.append(("取引先の連携待ち",safe(orders["pending"])+"件")) }
            if let paused=orders["paused"] as? Row { orderRows += [("送信停止",time(paused["at"])+"から停止中"),("停止理由",error(paused["reason"])),("再開方法","OXO ERPが受注を受け付ける状態になったら「接続をテスト」を実行してください。")] };sections.append(info("受注の送信",orderRows))
            if !failed.isEmpty { sections.append(.init(title:"送信に失敗した受注",columns:["CRM受注番号","原因"],rows:failed.map{[recordCell("crm_Orders",$0["orderId"],safe($0["number"])),.init(error($0["reason"]))]})) }
            return .init(title:"OXO ERP連携の状況",sections:sections)
        }
        func skippedReason(_ value:Any?) -> String {
            let raw=safe(value)
            if raw.hasPrefix("base list "),raw.hasSuffix(" not imported") { return "基準の価格表 "+String(raw.dropFirst(10).dropLast(13))+" が未取得です" }
            if raw.hasPrefix("category "),raw.hasSuffix(" not in the CRM") { return "カテゴリ "+String(raw.dropFirst(9).dropLast(15))+" がCRMにありません" }
            return error(raw)
        }
    }
}
