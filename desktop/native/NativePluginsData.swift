import Foundation

/// Permission-scoped plugin data access. It deliberately does not apply a UI
/// user's ownership scope: the original plugin API operates across the CRM.
final class NativePluginData {
    let db: NativeDatabase, pluginId: String, permissions: Set<String>
    let clock: () -> Date, logger: (String,String,NativePluginRecord?) -> Void
    init(db:NativeDatabase,pluginId:String,permissions:[String],clock:@escaping () -> Date=Date.init,logger:@escaping (String,String,NativePluginRecord?)->Void={_,_,_ in}) {
        self.db=db;self.pluginId=pluginId;self.permissions=Set(permissions);self.clock=clock;self.logger=logger
    }
    static let models = ["accounts":"crm_Accounts","contacts":"crm_Contacts","leads":"crm_Leads","opportunities":"crm_Opportunities","orders":"crm_Orders","activities":"crm_Activities","users":"Users","products":"crm_Products"]
    func need(_ permission:String) throws { try NativePluginExecutionScope.check(pluginId);guard permissions.contains(permission) else { throw NativePluginError.permission(pluginId,permission) } }
    private func model(_ name:String) throws -> String {
        guard let model=Self.models[name] ?? Self.models.first(where:{$0.value == name})?.value else { throw NativePluginError(message:"Unknown data API: "+name) };return model
    }
    private func permission(_ model:String,_ operation:String) throws {
        guard let api=Self.models.first(where:{$0.value == model})?.key else { throw NativePluginError(message:"Unknown data API: "+model) };try need(api+":"+operation)
    }
    func record(_ row:NativeRecord) throws -> NativePluginRecord {
        let model=try db.schema.model(row.model);var result:NativePluginRecord=[:]
        for field in model.fields where field.name != "password" {
            guard let value=row.values[field.name] else { continue }
            if value == .null { result[field.name]=NSNull() }
            else if field.array || field.type == "Json" { result[field.name]=try NativePluginJSON.parse(value.string) }
            else if field.type == "Boolean" { result[field.name]=value.string == "1" }
            else if field.type == "Decimal" { result[field.name]=try NativeMCPWire.decimal(value.string) }
            else if field.type == "DateTime" { result[field.name]=NativePluginJSON.stamp(try NativePluginJSON.date(value.string)) }
            else { result[field.name]=value.json }
        }
        return result
    }
    func get(_ name:String,_ id:String) throws -> NativePluginRecord? {
        let model=try model(name);try permission(model,"read")
        guard let row=try db.get(model,key:["id":.text(id)]) else { return nil }
        var result=try record(row)
        if model == "crm_Orders" { result["lines"]=try all("crm_OrderLines",where:["orderId":id]) }
        return result
    }
    func find(_ name:String,_ args:NativePluginRecord=[:]) throws -> [NativePluginRecord] {
        let model=try model(name);try permission(model,"read");return try rawFind(model,args)
    }
    func rawFind(_ model:String,_ args:NativePluginRecord=[:],additional:RecordFilter = .all) throws -> [NativePluginRecord] {
        let schema=try db.schema.model(model),fields=schema.fields.filter { $0.name != "password" }.map(\.name)
        let requested=NativePluginJSON.number(args["take"]) ?? 100,skip=NativePluginJSON.number(args["skip"]) ?? 0
        guard requested.rounded(.towardZero)==requested,skip.rounded(.towardZero)==skip,skip>=0,skip<=Double(Int32.max) else { throw NativePluginError(message:"Invalid pagination") }
        let take=Int(max(-100,min(requested,100)));if take == 0 { return [] }
        var order:[(field:String,descending:Bool)]=[]
        let ordering=(args["orderBy"] as? [NativePluginRecord]) ?? (args["orderBy"] as? NativePluginRecord).map { [$0] } ?? []
        for item in ordering {
            for key in item.keys.sorted() {
                guard fields.contains(key) else { throw NativePluginError(message:"Invalid filter field: "+key) }
                guard let direction=item[key] as? String,["asc","desc"].contains(direction) else { throw NativePluginError(message:"Invalid order: "+key) }
                order.append((key,(direction == "desc") != (take<0)))
            }
        }
        if take<0 && order.isEmpty { order=[("id",true)] }
        let scope=try filter(args["where"],schema:schema)
        let page=try db.mcpPage(model,fields:fields,filter:.every([scope,additional]),limit:abs(take),offset:Int(skip),order:order,includeDeleted:true,allowEmptyOrder:true)
        let rows=try page.rows.map(record)
        return take<0 ? rows.reversed():rows
    }
    func filter(_ input:Any?,schema:NativeSchema.Model) throws -> RecordFilter {
        guard let input=input as? NativePluginRecord else { return .all }
        var filters:[RecordFilter]=[]
        for key in input.keys.sorted() {
            let value=input[key]!
            if ["AND","OR","NOT"].contains(key) {
                let values=value as? [Any] ?? [value],nested=try values.map { try filter($0,schema:schema) }
                filters.append(key == "OR" ? .any(nested):key == "NOT" ? .every(nested.map { .not($0) }):.every(nested));continue
            }
            guard key != "password",let field=schema.field(key) else { throw NativePluginError(message:"Invalid filter field: "+key) }
            guard let operations=value as? NativePluginRecord,field.type != "Json" else { filters.append(.equal(key,try sql(value,field:field)));continue }
            let insensitive=operations["mode"] as? String == "insensitive"
            for op in operations.keys.sorted() where op != "mode" {
                let argument=operations[op]!
                if op == "not" {
                    filters.append(.not(try filter([key:argument],schema:schema)));continue
                }
                guard ["equals","in","notIn","lt","lte","gt","gte","contains","startsWith","endsWith","has","hasSome","hasEvery","isEmpty"].contains(op) else { throw NativePluginError(message:"Invalid filter operator: "+op) }
                let many=["in","notIn","hasSome","hasEvery"].contains(op)
                let values=try (many ? (argument as? [Any] ?? []):[argument]).map { try sql($0,field:field,arrayElement:op.hasPrefix("has")) }
                filters.append(.scalar(key,op,values,insensitive))
            }
        }
        return .every(filters)
    }
    func sql(_ value:Any,field:NativeSchema.Field,arrayElement:Bool=false) throws -> SQLValue {
        if value is NSNull { return .null }
        if (field.array && !arrayElement) || field.type == "Json" { return .text(try NativePluginJSON.text(value)) }
        if field.type == "Boolean",let b=NativePluginJSON.boolean(value) { return .integer(b ? 1:0) }
        if ["Int","BigInt"].contains(field.type),let n=NativePluginJSON.number(value),n.rounded(.towardZero)==n,n >= Double(Int64.min),n < Double(Int64.max) { return .integer(Int64(n)) }
        if field.type == "Float",let n=NativePluginJSON.number(value) { return .real(n) }
        if field.type == "Decimal",let n=NativePluginJSON.number(value) { return .text(NativePluginJSON.numberString(n)) }
        if let text=value as? String {
            return .text(field.type == "DateTime" ? NativePluginJSON.stamp(try NativePluginJSON.date(text)):text)
        }
        throw NativePluginError(message:"Invalid scalar value: "+field.name)
    }
    func values(_ input:NativePluginRecord,model:String,existing:NativeRecord?=nil) throws -> [String:SQLValue] {
        let schema=try db.schema.model(model);var result:[String:SQLValue]=[:]
        for (key,raw) in input {
            guard let field=schema.field(key) else { throw NativePluginError(message:"Unknown field: "+key) }
            var value=raw
            if field.type != "Json",!field.array,let op=raw as? NativePluginRecord {
                if op.count==1,let set=op["set"] { value=set }
                else if let existing,op.count==1,let name=op.keys.first,["increment","decrement","multiply","divide"].contains(name) {
                    if field.type=="Decimal" {
                        let operand=try sql(op[name]!,field:field)
                        var left=try PriceDecimal.parse(existing[key].string),right=try PriceDecimal.parse(operand.string),result=Decimal()
                        let error:Decimal.CalculationError
                        switch name {case "increment":error=NSDecimalAdd(&result,&left,&right,.plain);case "decrement":error=NSDecimalSubtract(&result,&left,&right,.plain);case "multiply":error=NSDecimalMultiply(&result,&left,&right,.plain);default:error=NSDecimalDivide(&result,&left,&right,.plain)}
                        guard error == .noError || error == .lossOfPrecision else { throw NativePluginError(message:"Invalid decimal operation") };value=PriceDecimal.string(result)
                    } else if let amount=NativePluginJSON.number(op[name]),let old=Double(existing[key].string) {
                        switch name { case "increment":value=old+amount;case "decrement":value=old-amount;case "multiply":value=old*amount;default:value=old/amount }
                    } else { throw NativePluginError(message:"Invalid field operation: "+key) }
                } else { throw NativePluginError(message:"Invalid field operation: "+key) }
            }
            let converted=try sql(value,field:field)
            result[key]=field.type=="Decimal" && converted != .null ? .text(try NativePluginStoredDecimal.round(converted.string,field:field)):converted
        }
        return result
    }
    private func campaign(_ input:NativePluginRecord,existing:NativeRecord?) throws {
        if input["assigned_campaings"] != nil || (input["campaign"] != nil && !(input["campaign"] is NSNull) && !(input["campaign"] is String)) { throw NativePluginError(message:"Invalid campaign: set the campaign field to an id or null") }
        guard let id=input["campaign"] as? String,!id.isEmpty,existing?["campaign"].string != id else { return }
        guard let row=try db.get("crm_campaigns",key:["id":.text(id)]),row["deletedAt"] == .null,row["status"] != .text("deleted") else { throw NativePluginError(message:"Invalid campaign: \(id) does not exist or is deleted") }
    }
    func create(_ entity:NativePluginEntity,_ input:NativePluginRecord) throws -> NativePluginRecord {
        guard entity != .order else { return try createOrder(input) }
        try permission(entity.model,"write")
        if entity == .opportunity { try campaign(input,existing:nil) }
        var input=input;if input["v"] == nil { input["v"]=0 }
        let row=try NativePluginActorScope.withActor(.plugin(pluginId)) { try db.insert(entity.model,values:values(input,model:entity.model),actor:"plugin:"+pluginId) }
        audit(entity:entity.rawValue,id:row["id"].string,action:"created",changes:[pluginTag]);emitSaved(entity,id:row["id"].string)
        return try record(row)
    }
    func update(_ entity:NativePluginEntity,_ id:String,_ input:NativePluginRecord) throws -> NativePluginRecord {
        guard entity != .order else { return try updateOrder(id,input) }
        try permission(entity.model,"write")
        guard let before=try db.get(entity.model,key:["id":.text(id)]) else { throw NativePluginError(message:"Record to update not found") }
        if entity == .opportunity { try campaign(input,existing:before) }
        let row=try NativePluginActorScope.withActor(.plugin(pluginId)) { try db.update(before,changes:values(input,model:entity.model,existing:before),actor:"plugin:"+pluginId) }
        let action=before["deletedAt"] == .null && row["deletedAt"] != .null ? "deleted":before["deletedAt"] != .null && row["deletedAt"] == .null ? "restored":"updated"
        audit(entity:entity.rawValue,id:id,action:action,changes:[pluginTag]+(try diff(before,row)));emitSaved(entity,id:id);return try record(row)
    }
    var pluginTag:NativePluginRecord { ["field":"plugin","old":NSNull(),"new":pluginId] }
    func diff(_ before:NativeRecord,_ after:NativeRecord) throws -> [NativePluginRecord] {
        let old=try record(before),new=try record(after),ignored:Set<String>=["updatedAt","updatedBy","createdAt","createdBy","created_on","cratedAt","v","deletedAt","deletedBy"]
        return try db.schema.model(before.model).fields.map(\.name).filter { !ignored.contains($0) && !NativePluginJSON.equal(old[$0],new[$0]) }.map { ["field":$0,"old":old[$0] ?? NSNull(),"new":new[$0] ?? NSNull()] }
    }
    func audit(entity:String,id:String,action:String,changes:[NativePluginRecord]?,user:String?=nil) {
        do { try db.insert("crm_AuditLog",values:["entityType":.text(entity),"entityId":.text(id),"action":.text(action),"changes":try changes.map { .text(try NativePluginJSON.text($0)) } ?? .null,"userId":user.map(SQLValue.text) ?? .null],actor:"plugin:"+pluginId) }
        catch { logger("error","Audit log write failed",["entityType":entity,"entityId":id]) }
    }
    func emitSaved(_ entity:NativePluginEntity,id:String) {
        do { try db.transaction { try db.enqueue("plugin/event",payload:["event":"crm/\(entity.rawValue).saved","data":try NativePluginJSON.text(["record_id":id,"source":pluginId])],now:clock()) } }
        catch { logger("error","Failed to emit saved event",["model":entity.model,"recordId":id]) }
    }
    func activitiesForRecord(_ entity:String,_ id:String,_ query:NativePluginRecord=[:]) throws -> [NativePluginRecord] {
        try need("activities:read");var whereValue:NativePluginRecord=["deletedAt":NSNull()]
        if let types=query["types"] as? [String],!types.isEmpty { whereValue["type"]=["in":types] }
        if NativePluginJSON.truthy(query["status"]) { whereValue["status"]=query["status"] }
        if NativePluginJSON.truthy(query["since"]) { whereValue["date"]=["gte":query["since"]!] }
        var args:NativePluginRecord=["where":whereValue,"orderBy":["date":"desc"],"take":max(1,min(100,NativePluginJSON.number(query["take"]) ?? 100))];args["skip"]=query["skip"]
        return try rawFind("crm_Activities",args,additional:.relation(model:"crm_ActivityLinks",local:"id",foreign:"activityId",matching:.every([.equal("entityType",.text(entity)),.equal("entityId",.text(id))])))
    }
}

/// PostgreSQL NUMERIC rounds at the storage boundary, including Decimal string
/// inputs that cannot be represented by binary64. Query operands remain exact.
private enum NativePluginStoredDecimal {
    static func round(_ input:String,field:NativeSchema.Field) throws -> String {
        let error=NativePluginError(message:"Invalid decimal value: "+field.name)
        guard let attributes=try? NSRegularExpression(pattern:#"@db\.Decimal\(([0-9]+),\s*([0-9]+)\)"#),let spec=attributes.firstMatch(in:field.attributes,range:NSRange(field.attributes.startIndex...,in:field.attributes)) else { return input }
        func parameter(_ i:Int)->Int {Int((field.attributes as NSString).substring(with:spec.range(at:i)))!}
        let precision=parameter(1),scale=parameter(2)
        guard let regex=try? NSRegularExpression(pattern:#"^([+-]?)([0-9]*)(?:\.([0-9]*))?(?:[eE]([+-]?[0-9]+))?$"#),let match=regex.firstMatch(in:input,range:NSRange(input.startIndex...,in:input)) else { throw error }
        func part(_ i:Int)->String { match.range(at:i).location==NSNotFound ? "":(input as NSString).substring(with:match.range(at:i)) }
        let integer=part(2),fraction=part(3),exponentText=part(4)
        guard !integer.isEmpty || !fraction.isEmpty else { throw error }
        var digits=Array((integer+fraction).utf8),point=integer.utf8.count
        guard let first=digits.firstIndex(where:{$0 != 48}) else {return "0"}
        point-=first;digits.removeFirst(first)
        if !exponentText.isEmpty {
            guard let exponent=Int(exponentText),exponent > -1_000_000,exponent < 1_000_000 else { if exponentText.hasPrefix("-"){return "0"};throw error }
            point+=exponent
        }
        guard point<=precision-scale else { throw error }
        let kept=point+scale
        if kept<0 {return "0"}
        let up=kept<digits.count && digits[kept]>=53
        if kept<digits.count {digits=Array(digits.prefix(kept))}else{digits += Array(repeating:48,count:kept-digits.count)}
        if up {
            var index=digits.count-1
            while index>=0,digits[index]==57 {digits[index]=48;index-=1}
            if index>=0 {digits[index]+=1}else{digits.insert(49,at:0)}
        }
        guard let first=digits.firstIndex(where:{$0 != 48}) else {return "0"};digits.removeFirst(first)
        guard digits.count<=precision else {throw error}
        if digits.count<=scale {digits=Array(repeating:48,count:scale+1-digits.count)+digits}
        if scale>0 {digits.insert(46,at:digits.count-scale);while digits.last==48 {digits.removeLast()};if digits.last==46 {digits.removeLast()}}
        return (part(1)=="-" ? "-":"")+String(decoding:digits,as:UTF8.self)
    }
}
