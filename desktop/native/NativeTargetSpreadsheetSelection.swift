import Foundation

/// Main-thread value state. Only explicitly selected IDs are retained; opening
/// a page or toggling its checkbox never preloads IDs from other pages.
struct NativeTargetSpreadsheetSelection {
    private var selected=Set<String>(),order:[String]=[]
    var ids:[String]{order.filter{selected.contains($0)}}
    var count:Int{selected.count}
    mutating func clear(){selected.removeAll();order.removeAll()}
    mutating func select(_ id:String){if selected.insert(id).inserted{order.append(id)}}
    mutating func remove(_ id:String){selected.remove(id);order.removeAll{$0==id}}
    mutating func updatePage(ids:[String],indexes:IndexSet){
        for (index,id) in ids.enumerated(){if indexes.contains(index){select(id)}else{remove(id)}}
    }
    func indexes(in visible:[String])->IndexSet{IndexSet(visible.indices.filter{selected.contains(visible[$0])})}
    mutating func prune(snapshot:[String],live:[String]){
        let missing=Set(snapshot).subtracting(live)
        selected.subtract(missing);order.removeAll{missing.contains($0)}
    }
    /// Existing read queue calls this with its termination fence. At most 100
    /// previously selected IDs enter one SQL query; no full-target scan occurs.
    static func liveIDs(_ snapshot:[String],service:CRMService,checkpoint:()throws->Void)throws->[String]{
        var live:[String]=[],offset=0
        while offset<snapshot.count {
            try checkpoint();try service.authenticated()
            let end=min(offset+100,snapshot.count),chunk=snapshot[offset..<end]
            let rows=try service.db.keysetPage("crm_Targets",fields:[],filter:.every([service.scope("crm_Targets"),.any(chunk.map{.equal("id",.text($0))})]))
            live.append(contentsOf:rows.map{$0["id"].string});offset=end
        }
        try checkpoint();return live
    }
}
