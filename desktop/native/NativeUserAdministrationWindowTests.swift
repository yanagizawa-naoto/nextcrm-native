import AppKit
import ImageIO

@main enum NativeUserAdministrationWindowTests {
    static var checks=0
    static func check(_ condition:@autoclosure()throws->Bool,_ name:String)throws{guard try condition()else{throw NativeDBError.message("FAIL "+name)};checks+=1}
    static func id(_ n:Int)->String{String(format:"b2000000-0000-4000-8000-%012d",n)}
    static func photo(_ url:URL,red:CGFloat)throws {
        let context=CGContext(data:nil,width:48,height:32,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:red,green:0.3,blue:1-red,alpha:1));context.fill(CGRect(x:0,y:0,width:48,height:32))
        let output=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(output,context.makeImage()!,nil)
        guard CGImageDestinationFinalize(output)else{throw NativeDBError.message("fixture PNG")}
    }
    static func wait(_ ready:()->Bool)throws{let deadline=Date().addingTimeInterval(10);while !ready() && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.01))};try check(ready(),"async UI completion")}
    @MainActor static func main(){_ = NSApplication.shared;NSApp.setActivationPolicy(.accessory);do{try run();print("NativeUserAdministrationWindowTests: \(checks) AppKit/SQLite checks passed")}catch{fputs("After \(checks): \(error.localizedDescription)\n",stderr);exit(1)}}
    @MainActor static func run()throws{
        let n=URL(fileURLWithPath:CommandLine.arguments[1]),dir=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-UserAdminUI-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
        let db=try NativeDatabase(url:dir.appendingPathComponent("crm.sqlite"),schemaURL:n.appendingPathComponent("schema.json"),sqlURL:n.appendingPathComponent("schema.sql"))
        for i in 1...151{_ = try db.insert("Users",values:["id":.text(id(i)),"name":.text(i==2 ? "対象利用者":"利用者\(i)"),"email":.text("u\(i)@fixture.invalid"),"role":.text(i==1 ? "admin":i==3 ? "partner":"user"),"userStatus":.text("ACTIVE"),"created_on":.text("2026-11-01T00:00:00Z"),"password":.text("must-not-display")],actor:id(1))}
        _ = try db.insert("crm_Accounts",values:["id":.text(id(500)),"v":.integer(0),"name":.text("日本語の企業")],actor:id(1))
        func svc(_ i:Int,_ role:String)->CRMService{CRMService(db:db,identity:.init(id:id(i),role:role,partnerAccountID:nil))}
        func row(_ i:Int)throws->NativeRecord{try db.get("Users",key:["id":.text(id(i))])!}
        var discard=false,discardPrompts=0
        let service=svc(1,"admin"),ui=try NativeUserAdministrationWindow(service:service,confirmDelete:{_ in true},confirmDiscard:{_ in discardPrompts+=1;return discard});defer{ui.window.close()};ui.show()
        try check(ui.testState.rows==100 && ui.testState.total==151,"bounded initial directory")
        ui.invokeForTesting("次の100件");try check(ui.testState.rows==51,"page two")
        ui.invokeForTesting("前の100件");try check(ui.testState.rows==100,"page one")
        ui.selectForTesting(id(1));try check(ui.testState.enabled["削除…"]==false && ui.testState.enabled["無効にする"]==false,"self destructive actions disabled")
        ui.searchForTesting("対象利用者");try check(ui.testState.total==1,"Japanese search")
        ui.selectForTesting(id(2));ui.invokeForTesting("詳細・プロフィール…")
        guard let profile=ui.testState.form else{throw NativeDBError.conflict};defer{profile.window.close()}
        try check(profile.window.sheetParent===ui.window,"user editor is owned by directory sheet")
        profile.setForTesting("name","更新した利用者");profile.setForTesting("username","ユーザー名");profile.setForTesting("account","日本の企業")
        try check(!ui.confirmDiscard() && discardPrompts==1,"application close propagates unsaved child confirmation")
        profile.closeForTesting();try check(profile.window.sheetParent===ui.window,"cancel discard retains editor")
        profile.submitForTesting();try wait{!profile.testState.busy}
        try check(try row(2)["name"] == .text("更新した利用者") && row(2)["username"] == .text("ユーザー名"),"profile saved through AppKit")
        try check(profile.confirmDiscard(),"successful save resets dirty baseline")
        profile.closeForTesting();try wait{ui.testState.form==nil}
        ui.searchForTesting("更新した利用者");ui.selectForTesting(id(2));ui.invokeForTesting("権限…")
        let role=ui.testState.form!;role.setForTesting("role","partner");role.submitForTesting();try wait{!role.testState.busy}
        try check(try row(2)["role"] == .text("partner"),"role control")
        role.closeForTesting();try wait{ui.testState.form==nil}
        ui.selectForTesting(id(2));ui.invokeForTesting("パートナー企業…");let partner=ui.testState.partner!;defer{partner.window.close()}
        partner.assignForTesting(id(500));try check(try row(2)["partnerAccountId"] == .text(id(500)),"account picker stores home company")
        partner.assignForTesting(nil);try check(try row(2)["partnerAccountId"] == .null,"account picker clear")
        partner.closeForTesting();try wait{ui.testState.partner==nil}
        ui.selectForTesting(id(2));ui.invokeForTesting("無効にする");try check(try row(2)["userStatus"] == .text("INACTIVE"),"deactivation button")
        ui.selectForTesting(id(2));ui.invokeForTesting("有効にする");try wait{ui.testState.status.contains("未設定")}
        try check(try row(2)["userStatus"] == .text("ACTIVE"),"activation commits with explicit mail warning")
        ui.selectForTesting(id(2));ui.invokeForTesting("API トークンを失効");try check(ui.testState.status.contains("0 件"),"revoke count Japanese")
        ui.invokeForTesting("招待…");let invite=ui.testState.form!;invite.setForTesting("name","新規招待先");invite.setForTesting("email","new@fixture.invalid");invite.submitForTesting();try wait{!invite.testState.busy}
        try check(invite.testState.status.contains("接続が設定されていません"),"unconfigured invitation explicit")
        try check(try db.page("Users",fields:[]).total==151,"no accidental invite row")
        try check(!invite.confirmDiscard(),"failed save preserves the dirty invitation")
        discard=true;invite.closeForTesting();try wait{ui.testState.form==nil};discard=false
        ui.selectForTesting(id(2));ui.invokeForTesting("削除…");try check(try db.get("Users",key:["id":.text(id(2))])==nil,"confirmed deletion action")
        let avatarStore=try NativeUserAvatarStore(service:svc(4,"user"));var removePhoto=false
        let selfUI=try NativeUserAdministrationProfileWindow(service:svc(4,"user"),avatarStore:avatarStore,confirmDiscard:{_ in false},confirmRemove:{removePhoto});defer{selfUI.window.close()};selfUI.show()
        selfUI.setForTesting(name:"自分の名前",username:"self",company:"会社");selfUI.invokeForTesting("プロフィールを保存")
        try check(try row(4)["name"] == .text("自分の名前"),"ordinary self profile")
        try check(selfUI.confirmDiscard(),"saved self profile is clean")
        selfUI.languageForTesting("uk");try check(!selfUI.confirmDiscard(),"unsaved language participates in close confirmation")
        selfUI.languageForTesting("uk");selfUI.invokeForTesting("言語を保存");try check(try row(4)["userLanguage"] == .text("uk"),"all five original language values")
        let photoA=dir.appendingPathComponent("photo-a.png"),photoB=dir.appendingPathComponent("photo-b.png"),badPhoto=dir.appendingPathComponent("bad.png")
        try photo(photoA,red:1);try photo(photoB,red:0);try Data("not an image".utf8).write(to:badPhoto)
        try Data(contentsOf:photoA).write(to:n.appendingPathComponent("build/user-profile-photo-fixture.png"),options:.atomic)
        selfUI.selectPhotoForTesting(photoA);try wait{!selfUI.photoTestState.busy}
        try check(selfUI.photoTestState.pending && selfUI.photoTestState.message.contains("まだ保存"),"selected photo waits in preview")
        try check(try row(4)["avatar"] == .null,"preview leaves metadata unchanged")
        try check(!selfUI.confirmDiscard(),"unsaved preview participates in close guard")
        selfUI.invokeForTesting("選択を取り消す")
        try check(!selfUI.photoTestState.pending && selfUI.confirmDiscard(),"cancel removes preview and dirty state")
        try check(try FileManager.default.contentsOfDirectory(atPath:avatarStore.root.path).filter{$0.contains("pending")}.isEmpty,"cancel removes staged original and thumbnail")
        selfUI.selectPhotoForTesting(photoA);try check(!selfUI.confirmDiscard(),"close waits for photo operation")
        selfUI.invokeForTesting("選択を取り消す");try wait{!selfUI.photoTestState.busy}
        try check(try row(4)["avatar"] == .null && !selfUI.photoTestState.pending,"cancelling preparation does not publish photo")
        selfUI.selectPhotoForTesting(photoA);try wait{!selfUI.photoTestState.busy}
        selfUI.selectPhotoForTesting(badPhoto);try wait{!selfUI.photoTestState.busy}
        try check(selfUI.photoTestState.pending,"invalid replacement preserves previous valid preview")
        let beforePhotoRevision=try row(4).revision
        selfUI.setForTesting(name:"未保存の氏名",username:"self",company:"会社")
        selfUI.invokeForTesting("写真を保存");try wait{!selfUI.photoTestState.busy}
        let firstReference=try row(4)["avatar"].string
        try check(firstReference.hasPrefix(NativeUserAvatarStore.prefix) && !selfUI.photoTestState.pending,"save commits native photo reference")
        try check(try row(4).revision==beforePhotoRevision+1,"photo metadata committed exactly once")
        try check(try avatarStore.original(forUserID:id(4))?.data==Data(contentsOf:photoA),"profile flow preserves exact original")
        try check(try row(4)["name"] == .text("自分の名前") && !selfUI.confirmDiscard(),"photo save preserves unrelated unsaved profile text")
        selfUI.setForTesting(name:"自分の名前",username:"self",company:"会社")
        try check(selfUI.confirmDiscard(),"saved photo clears preview dirty state")
        let reopened=try NativeUserAdministrationProfileWindow(service:svc(4,"user"),confirmDiscard:{_ in true});defer{reopened.window.close()}
        let staleRemover=try NativeUserAdministrationProfileWindow(service:svc(4,"user"),confirmDiscard:{_ in true},confirmRemove:{true});defer{staleRemover.window.close()}
        try check(reopened.photoTestState.reference==firstReference && reopened.photoTestState.message.contains("保存済み"),"reopened profile reads stored image")
        selfUI.selectPhotoForTesting(photoB);try wait{!selfUI.photoTestState.busy}
        selfUI.invokeForTesting("選択を取り消す")
        try check(try row(4)["avatar"].string==firstReference && avatarStore.original(forUserID:id(4))?.data==Data(contentsOf:photoA),"replacement cancellation preserves old photo pair")
        let failingStore=try NativeUserAvatarStore(service:svc(4,"user"),checkpoint:{point in if case .beforeMetadata=point{throw NativeDBError.message("fixture publication failure")}})
        let failingUI=try NativeUserAdministrationProfileWindow(service:svc(4,"user"),avatarStore:failingStore,confirmDiscard:{_ in true});defer{failingUI.window.close()}
        failingUI.selectPhotoForTesting(photoB);try wait{!failingUI.photoTestState.busy};failingUI.invokeForTesting("写真を保存");try wait{!failingUI.photoTestState.busy}
        try check(failingUI.testStatus.contains("保存できません") && !failingUI.photoTestState.pending,"failed publication clears consumed preview with actionable error")
        try check(try row(4)["avatar"].string==firstReference && avatarStore.original(forUserID:id(4))?.data==Data(contentsOf:photoA),"failed publication preserves old metadata and bytes")
        try check(try FileManager.default.contentsOfDirectory(atPath:avatarStore.root.path).filter{$0.contains("pending")}.isEmpty,"failed publication cleans staged pair")
        selfUI.selectPhotoForTesting(photoB);try wait{!selfUI.photoTestState.busy}
        reopened.selectPhotoForTesting(photoB);try wait{!reopened.photoTestState.busy};reopened.invokeForTesting("写真を保存");try wait{!reopened.photoTestState.busy}
        let changedReference=try row(4)["avatar"].string
        let changedRevision=try row(4).revision
        staleRemover.invokeForTesting("写真を削除…");try wait{!staleRemover.photoTestState.busy}
        try check(try row(4)["avatar"].string==changedReference && row(4).revision==changedRevision,"stale profile removal preserves another window's saved photo")
        try check(staleRemover.photoTestState.reference==changedReference && !staleRemover.testStatus.isEmpty,"stale removal reloads latest photo and reports conflict")
        selfUI.invokeForTesting("写真を保存");try wait{!selfUI.photoTestState.busy}
        try check(selfUI.testStatus.contains("保存できません") && selfUI.photoTestState.reference==changedReference,"stale preview does not overwrite another saved photo")
        selfUI.invokeForTesting("写真を削除…");try check(try row(4)["avatar"].string==changedReference,"cancel removal preserves photo")
        var cancellingUI:NativeUserAdministrationProfileWindow?
        let cancellingStore=try NativeUserAvatarStore(service:svc(4,"user"),checkpoint:{point in
            if case .afterMetadata=point {DispatchQueue.main.sync{cancellingUI?.invokeForTesting("選択を取り消す")}}
        })
        cancellingUI=try NativeUserAdministrationProfileWindow(service:svc(4,"user"),avatarStore:cancellingStore,confirmDiscard:{_ in true},confirmRemove:{true})
        cancellingUI!.invokeForTesting("写真を削除…");try wait{!cancellingUI!.photoTestState.busy}
        try check(try row(4)["avatar"].string==changedReference && row(4).revision==changedRevision,"cancel button before removal commit preserves photo")
        try check(cancellingUI!.testStatus.contains("削除を中止") && avatarStore.original(forUserID:id(4))?.data==Data(contentsOf:photoB),"cancelled removal reports cancellation and preserves original")
        cancellingUI!.window.close();cancellingUI=nil
        removePhoto=true;selfUI.invokeForTesting("写真を削除…");try wait{!selfUI.photoTestState.busy}
        try check(try row(4)["avatar"] == .null && selfUI.photoTestState.reference.isEmpty,"confirmed removal clears profile")
        try check(try FileManager.default.contentsOfDirectory(atPath:avatarStore.root.path).filter{!$0.hasPrefix(".")}.isEmpty,"removed photo deletes original and thumbnail")
        reopened.selectPhotoForTesting(photoA);try wait{!reopened.photoTestState.busy};reopened.invokeForTesting("閉じる")
        try check(try FileManager.default.contentsOfDirectory(atPath:avatarStore.root.path).filter{$0.contains("pending")}.isEmpty && !reopened.photoTestState.pending,"discard on close cleans staged image")
        let quitHost=NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        let quitOuter=NSPanel(contentRect:NSRect(x:0,y:0,width:680,height:680),styleMask:[.titled],backing:.buffered,defer:false)
        quitHost.isReleasedWhenClosed=false;quitOuter.isReleasedWhenClosed=false
        var quitAllowed=false,quitClosures:[String]=[]
        let quitProfile=try NativeUserAdministrationProfileWindow(service:svc(4,"user"),confirmDiscard:{_ in quitAllowed})
        quitHost.beginSheet(quitOuter){_ in quitClosures.append("outer")}
        quitOuter.beginSheet(quitProfile.window){_ in quitClosures.append("profile")}
        quitProfile.selectPhotoForTesting(photoA);try wait{!quitProfile.photoTestState.busy}
        if quitProfile.confirmDiscard(){NativeSheetTermination.dismiss(in:quitHost)}
        try check(quitHost.attachedSheet===quitOuter && quitProfile.photoTestState.pending,"cancelled quit keeps nested sheet and staged photo")
        quitAllowed=true
        if quitProfile.confirmDiscard(){NativeSheetTermination.dismiss(in:quitHost)}
        try check(quitHost.attachedSheet==nil && quitClosures==["profile","outer"],"approved quit ends nested sheets child first")
        try check(!quitProfile.photoTestState.pending && FileManager.default.contentsOfDirectory(atPath:avatarStore.root.path).filter{$0.contains("pending")}.isEmpty,"approved quit delivers close cleanup while profile is still retained")
        quitHost.close()
        let closeWaiters=NativeSheetCloseWaiters()
        var requests=0,joined=0,finished=0
        for _ in 0..<2 { Task { @MainActor in
            joined += 1
            await closeWaiters.wait { requests += 1 }
            finished += 1
        } }
        try wait { joined==2 }
        try check(requests==1 && finished==0,"overlapping quit requests share one close operation")
        closeWaiters.didClose();try wait { finished==2 }
        try check(finished==2,"all overlapping close waiters resume")
        Task { @MainActor in await closeWaiters.wait { requests += 1 };finished += 1 }
        try wait { finished==3 }
        try check(requests==1,"a late termination request observes the already completed close")
        // A synchronous idle-sheet close can complete inside requestClose.
        let idleClose=NativeSheetCloseWaiters()
        Task { @MainActor in await idleClose.wait { requests += 1; idleClose.didClose() };finished += 1 }
        try wait { finished==4 }
        try check(requests==2,"synchronous sheet completion resumes its registered waiter")
        do{_ = try NativeUserAdministrationWindow(service:svc(4,"user"));throw NativeDBError.message("FAIL nonadmin window")}catch NativeDBError.message(let error){try check(error.contains("管理者"),"nonadmin rejected")}
        var sent=0
        let gateway=NativeUserAdministrationMailGateway(applicationName:"NextCRM",applicationURL:"https://fixture.invalid/login",from:"crm@fixture.invalid",isConfigured:true,send:{_ in sent+=1;throw NativeDBError.message("fake send failure")})
        let configured=try NativeUserAdministrationWindow(service:service,mailGateway:gateway);defer{configured.window.close()};configured.invokeForTesting("招待…");let badInvite=configured.testState.form!;badInvite.setForTesting("name","失敗時の招待先");badInvite.setForTesting("email","failed@fixture.invalid");badInvite.submitForTesting();try wait{!badInvite.testState.busy}
        try check(sent==1 && badInvite.testState.status.contains("招待できませんでした"),"fake mail failure visible")
        try check(try db.page("Users",fields:[],equal:["email":.text("failed@fixture.invalid")]).total==1,"created user remains visible after invite failure")
        ui.searchForTesting("");ui.window.contentView!.layoutSubtreeIfNeeded();ui.window.displayIfNeeded()
        ui.window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);RunLoop.current.run(until:Date().addingTimeInterval(0.1))
        if let image=CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID(ui.window.windowNumber),.boundsIgnoreFraming),let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]){try png.write(to:n.appendingPathComponent("build/user-administration-window.png"));try check(png.count>1000,"AppKit actual window screenshot artifact")}

        _ = try db.update(row(1),changes:["role":.text("user")],actor:id(5));ui.reload()
        try check(ui.testState.rows==0 && ui.testState.enabled["招待…"]==false,"lost authority clears directory")
        let unchanged=try row(4)["name"];_ = try db.update(row(4),changes:["banned":.integer(1)],actor:id(5));selfUI.setForTesting(name:"拒否",username:"x",company:"x");selfUI.invokeForTesting("プロフィールを保存")
        try check(try row(4)["name"] == unchanged && selfUI.testStatus.contains("ログイン"),"profile rechecks current actor")
    }
}
