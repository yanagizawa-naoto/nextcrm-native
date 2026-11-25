import AppKit
import UniformTypeIdentifiers

/// Japanese administrator UI. The caller retains this controller and injects
/// the mail gateway; opening it never reads credentials or sends mail.
final class NativeUserAdministrationWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1080,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    private let service:CRMService, api:NativeUserAdministration, mail:NativeUserAdministrationMailGateway
    private let confirmDelete:(String)->Bool, confirm:(String)->Bool
    private let table=NSTableView(), search=NSSearchField(), role=NSPopUpButton(), state=NSPopUpButton()
    private let status=NSTextField(wrappingLabelWithString:""), count=NSTextField(labelWithString:"")
    private var rows:[NativeUserAdministrationRow]=[], offset=0, total=0, busy=false, permitted=true
    private var buttons:[String:NSButton]=[:], task:Task<Void,Never>?
    private var form:NativeUserAdministrationForm?, partner:NativeUserAdministrationPartnerPicker?, profile:NativeUserAdministrationProfileWindow?
    var onChanged:(()->Void)?
    init(service:CRMService, mailGateway:NativeUserAdministrationMailGateway = .unconfigured, confirmDelete:@escaping(String)->Bool = NativeUserAdministrationWindow.askDelete, confirmDiscard:@escaping(String)->Bool = NativeUserAdministrationWindow.askDiscard) throws {
        try service.authenticated();guard service.identity.role=="admin" else{throw NativeDBError.message("利用者の管理は管理者が行ってください。")}
        self.service=service;api=NativeUserAdministration(service:service,mail:mailGateway);mail=mailGateway;self.confirmDelete=confirmDelete;confirm=confirmDiscard
        super.init();window.title="利用者の管理";window.delegate=self
        let title=NSTextField(labelWithString:window.title);title.font = .systemFont(ofSize:22,weight:.semibold)
        let help=NSTextField(wrappingLabelWithString:"利用者の承認・権限・パートナー企業を管理します。無効化すると、本人のログインと API トークンが失効します。")
        search.placeholderString="名前・メールアドレス・ユーザー名で検索";search.target=self;search.action=#selector(searchChanged);search.setAccessibilityLabel("利用者を検索")
        role.addItems(withTitles:["すべての権限","管理者","マネージャー","一般ユーザー","パートナー"]);role.target=self;role.action=#selector(searchChanged)
        state.addItems(withTitles:["すべての状態","有効","無効","承認待ち"]);state.target=self;state.action=#selector(searchChanged)
        let toolbar=NSStackView(views:[search,role,state,button("再読み込み",#selector(refresh)),button("招待…",#selector(invite))]);toolbar.spacing=8
        for (key,title,width) in [("name","名前",160.0),("email","メールアドレス",245.0),("role","権限",110.0),("userStatus","状態",85.0),("created_on","作成日時",155.0),("lastLoginAt","最終ログイン",155.0)]{let c=NSTableColumn(identifier:.init(key));c.title=title;c.width=width;table.addTableColumn(c)}
        table.dataSource=self;table.delegate=self;table.rowHeight=29;table.allowsMultipleSelection=false;table.setAccessibilityLabel("利用者一覧")
        let scroll=NSScrollView();scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.autohidesScrollers=true;scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:310).isActive=true
        let actions=NSStackView(views:[button("詳細・プロフィール…",#selector(edit)),button("権限…",#selector(changeRole)),button("パートナー企業…",#selector(changePartner)),button("言語…",#selector(changeLanguage)),button("有効にする",#selector(activate)),button("無効にする",#selector(deactivate))]);actions.spacing=7
        let more=NSStackView(views:[button("API トークンを失効",#selector(revoke)),button("削除…",#selector(remove)),NSView(),button("自分のプロフィール…",#selector(ownProfile))]);more.spacing=8
        let footer=NSStackView(views:[button("前の100件",#selector(previous)),count,button("次の100件",#selector(next)),NSView(),button("閉じる",#selector(close))]);footer.spacing=8
        status.maximumNumberOfLines=3;status.setAccessibilityLabel("利用者管理の操作結果")
        NativeUserAdministrationForm.layout([title,help,toolbar,scroll,actions,more,status,footer],in:window)
        reload()
    }
    static func askDelete(_ text:String)->Bool{let alert=NSAlert();alert.messageText="利用者を削除しますか？";alert.informativeText=text;alert.addButton(withTitle:"キャンセル");alert.addButton(withTitle:"削除");return alert.runModal() == .alertSecondButtonReturn}
    static func askDiscard(_ text:String)->Bool{let alert=NSAlert();alert.messageText="変更を保存せずに閉じますか？";alert.informativeText=text;alert.addButton(withTitle:"編集を続ける");alert.addButton(withTitle:"変更を破棄");return alert.runModal() == .alertSecondButtonReturn}
    static func dismiss(_ window:NSWindow){if let parent=window.sheetParent{parent.endSheet(window)}else{window.close()}}
    func start(){reload()}
    func confirmDiscard()->Bool{!busy && (form?.confirmDiscard() ?? true) && (profile?.confirmDiscard() ?? true)}
    private func button(_ title:String,_ action:Selector)->NSButton{let b=NSButton(title:title,target:self,action:action);buttons[title]=b;return b}
    func show(){window.center();window.makeKeyAndOrderFront(nil);reload()}
    private var chosen:NativeUserAdministrationRow?{rows.indices.contains(table.selectedRow) ? rows[table.selectedRow]:nil}
    private func controls(){for b in buttons.values{b.isEnabled = !busy && permitted};search.isEnabled = !busy && permitted;role.isEnabled=search.isEnabled;state.isEnabled=search.isEnabled
        for key in ["詳細・プロフィール…","権限…","パートナー企業…","言語…","有効にする","無効にする","API トークンを失効","削除…"]{buttons[key]?.isEnabled = !busy && permitted && chosen != nil}
        buttons["パートナー企業…"]?.isEnabled = !busy && permitted && chosen?["role"] == .text("partner")
        if chosen?.id==service.identity.id{buttons["無効にする"]?.isEnabled=false;buttons["削除…"]?.isEnabled=false}
        buttons["前の100件"]?.isEnabled = !busy && permitted && offset>0;buttons["次の100件"]?.isEnabled = !busy && permitted && offset+rows.count<total;buttons["閉じる"]?.isEnabled=true
    }
    func reload(){let selection=chosen?.id
        do{try service.authenticated();guard service.identity.role=="admin"else{throw NativeDBError.message("利用者を管理する権限がありません。")};permitted=true
            let roles:[String?]=[nil,"admin","manager","user","partner"],states:[String?]=[nil,"ACTIVE","INACTIVE","PENDING"]
            var page=try api.list(search:search.stringValue,role:roles[role.indexOfSelectedItem],status:states[state.indexOfSelectedItem],offset:offset)
            if offset>0 && page.rows.isEmpty{offset=max(0,((max(1,page.total)-1)/100)*100);page=try api.list(search:search.stringValue,role:roles[role.indexOfSelectedItem],status:states[state.indexOfSelectedItem],offset:offset)}
            rows=page.rows;total=page.total;count.stringValue="\(total==0 ? 0:offset+1)〜\(offset+rows.count) / \(total) 件";table.reloadData()
            if let selection,let i=rows.firstIndex(where:{$0.id==selection}){table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false)}
        }catch{rows=[];total=0;table.reloadData();permitted=false;status.stringValue=error.localizedDescription;count.stringValue=""}
        controls()
    }
    func numberOfRows(in tableView:NSTableView)->Int{rows.count}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView?{guard rows.indices.contains(row),let key=tableColumn?.identifier.rawValue else{return nil};let value=rows[row][key].string
        let text = key=="role" ? Self.roleTitle(value):key=="userStatus" ? Self.statusTitle(value):["created_on","lastLoginAt"].contains(key) ? Self.date(rows[row][key]):value
        let identifier=NSUserInterfaceItemIdentifier("user-"+key);let label=(tableView.makeView(withIdentifier:identifier,owner:self) as? NSTextField) ?? NSTextField(labelWithString:"");label.identifier=identifier;label.stringValue=text.isEmpty ? "—":text;label.lineBreakMode = .byTruncatingTail;label.toolTip=text;return label
    }
    func tableViewSelectionDidChange(_ notification:Notification){controls()}
    static func roleTitle(_ raw:String)->String{["admin":"管理者","manager":"マネージャー","user":"一般ユーザー","partner":"パートナー"][raw] ?? raw}
    static func statusTitle(_ raw:String)->String{["ACTIVE":"有効","INACTIVE":"無効","PENDING":"承認待ち"][raw] ?? raw}
    static func date(_ value:SQLValue)->String{guard let d=NativeAPITokens.date(value)else{return "—"};let f=DateFormatter();f.locale=Locale(identifier:"ja_JP");f.dateFormat="yyyy/MM/dd HH:mm";return f.string(from:d)}
    private func selected(_ body:(NativeUserAdministrationRow)throws->Void){do{guard !busy,window.attachedSheet==nil,let chosen else{return};try body(api.detail(chosen.id))}catch{status.stringValue=error.localizedDescription;reload()}}
    private func mutate(_ body:()throws->String){do{status.stringValue=try body();onChanged?()}catch{status.stringValue=error.localizedDescription};reload()}
    private func perform(_ body:@escaping()async throws->String){guard !busy else{return};busy=true;controls();task=Task{@MainActor [weak self] in guard let self else{return};defer{self.busy=false;self.task=nil;self.reload();self.onChanged?()};do{let message=try await body();try Task.checkCancellation();self.status.stringValue=message}catch is CancellationError{}catch{self.status.stringValue=error.localizedDescription}}}
    @objc private func searchChanged(){offset=0;reload()}
    @objc private func refresh(){reload()}
    @objc private func previous(){offset=max(0,offset-100);reload()}
    @objc private func next(){offset+=100;reload()}
    @objc private func close(){guard window.attachedSheet==nil,confirmDiscard() else{return};Self.dismiss(window)}
    func windowShouldClose(_ sender:NSWindow)->Bool{guard window.attachedSheet==nil,confirmDiscard()else{return false};if let parent=window.sheetParent{parent.endSheet(window);return false};return true}
    func windowWillClose(_ notification:Notification){task?.cancel();form?.window.close();partner?.window.close();profile?.window.close()}
    @objc private func remove(){selected{row in guard confirmDelete("\(row["name"].string)（\(row["email"].string)）を削除します。元に戻せません。関連データによっては削除できません。")else{return};mutate{_ = try api.delete(row.id);return "利用者を削除しました。"}}}
    @objc private func deactivate(){selected{row in mutate{_ = try api.deactivate(row.id);return "利用者を無効にし、ログインと API トークンを失効しました。"}}}
    @objc private func revoke(){selected{row in mutate{"API トークン \(try api.revokeAPITokens(row.id)) 件を失効しました。"}}}
    @objc private func activate(){selected{row in perform{[api] in let result=try await api.activate(row.id);switch result.delivery{case .sent:return "利用者を有効にし、通知メールを送信しました。";case .failed:return "利用者は有効になりましたが、通知メールを送信できませんでした。";case .notConfigured:return "利用者は有効になりました。通知メールは未設定のため送信していません。"}}}}
    private func editor(_ title:String,_ fields:[NativeUserAdministrationForm.Field],_ save:@escaping([String:String])async throws->String){guard !busy,window.attachedSheet==nil else{return};let editor=NativeUserAdministrationForm(title:title,fields:fields,confirmDiscard:confirm,save:save);editor.onFinished={[weak self] in self?.reload();self?.onChanged?()};form=editor;window.beginSheet(editor.window){[weak self] _ in self?.form=nil}}
    @objc private func edit(){selected{row in editor("利用者の詳細・プロフィール",[.init("email","メールアドレス",row["email"].string,readOnly:true),.init("created","作成日時",Self.date(row["created_on"]),readOnly:true),.init("login","最終ログイン",Self.date(row["lastLoginAt"]),readOnly:true),.init("name","名前",row["name"].string),.init("username","ユーザー名",row["username"].string),.init("account","会社名",row["account_name"].string)]){[api] v in _ = try api.updateProfile(row.id,name:v["name"]!,username:v["username"]!,accountName:v["account"]!);return "プロフィールを保存しました。"}}}
    @objc private func changeRole(){selected{row in editor("利用者の権限",[.init("role","権限",row["role"].string,options:[("admin","管理者"),("manager","マネージャー"),("user","一般ユーザー"),("partner","パートナー")])]){[api] v in _ = try api.setRole(row.id,role:v["role"]!);return "権限を変更しました。"}}}
    @objc private func changeLanguage(){selected{row in editor("利用者の言語",[.init("language","言語",row["userLanguage"].string,options:NativeUserAdministrationProfileWindow.languages)]){[api] v in _ = try api.setLanguage(row.id,language:v["language"]!);return "言語を保存しました。"}}}
    @objc private func changePartner(){selected{row in let controller=try NativeUserAdministrationPartnerPicker(service:service,userID:row.id,currentAccountID:row["partnerAccountId"] == .null ? nil:row["partnerAccountId"].string,onChanged:{[weak self] in self?.reload();self?.onChanged?()});partner=controller;window.beginSheet(controller.window){[weak self] _ in self?.partner=nil}}}
    @objc private func invite(){editor("利用者を招待",[.init("name","名前",""),.init("email","メールアドレス",""),.init("language","言語","ja",options:NativeUserAdministrationProfileWindow.languages)]){[api,mail] v in
        guard mail.isConfigured else{throw NativeDBError.message("招待メールの接続が設定されていません。管理者のメール・ログイン設定を完了してください。")}
        let name=v["name"]!,email=v["email"]!;guard (3...50).contains(name.unicodeScalars.count),email.range(of:#"^(?:[A-Za-z0-9_'+\-]+\.)*[A-Za-z0-9_'+\-]*[A-Za-z0-9_+-]@(?:[A-Za-z0-9][A-Za-z0-9\-]*\.)+[A-Za-z]{2,}$"#,options:.regularExpression) != nil else{throw NativeDBError.message("名前は3〜50文字、メールアドレスは正しい形式で入力してください。")}
        _ = try await api.invite(name:name,email:email,language:v["language"]!);return "利用者を作成し、招待メールを送信しました。"
    }}
    @objc private func ownProfile(){guard !busy,window.attachedSheet==nil else{return};do{let controller=try NativeUserAdministrationProfileWindow(service:service,confirmDiscard:confirm);controller.onChanged={[weak self] in self?.reload();self?.onChanged?()};profile=controller;window.beginSheet(controller.window){[weak self] _ in self?.profile=nil}}catch{status.stringValue=error.localizedDescription}}
    // Isolated AppKit tests drive the same selectors and table, not a duplicate model.
    func selectForTesting(_ id:String){if let index=rows.firstIndex(where:{$0.id==id}){table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false)};controls()}
    func searchForTesting(_ text:String){search.stringValue=text;searchChanged()}
    func invokeForTesting(_ title:String){buttons[title]?.performClick(nil)}
    var testState:(rows:Int,total:Int,status:String,enabled:[String:Bool],form:NativeUserAdministrationForm?,partner:NativeUserAdministrationPartnerPicker?){(rows.count,total,status.stringValue,buttons.mapValues(\.isEnabled),form,partner)}
}

final class NativeUserAdministrationForm:NSObject,NSWindowDelegate {
    struct Field{let key:String,title:String,value:String,readOnly:Bool,options:[(String,String)]?;init(_ key:String,_ title:String,_ value:String,readOnly:Bool=false,options:[(String,String)]?=nil){self.key=key;self.title=title;self.value=value;self.readOnly=readOnly;self.options=options}}
    let window=NSPanel(contentRect:NSRect(x:0,y:0,width:560,height:440),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    private let fields:[Field],save:([String:String])async throws->String,confirm:(String)->Bool
    private var baseline:[String:String]=[:]
    private var inputs:[String:NSControl]=[:],task:Task<Void,Never>?,busy=false
    private let status=NSTextField(wrappingLabelWithString:""),submit=NSButton(title:"保存",target:nil,action:nil)
    var onFinished:(()->Void)?
    init(title:String,fields:[Field],confirmDiscard:@escaping(String)->Bool = NativeUserAdministrationWindow.askDiscard,save:@escaping([String:String])async throws->String){self.fields=fields;self.save=save;confirm=confirmDiscard;super.init();window.title=title;window.delegate=self
        let heading=NSTextField(labelWithString:title);heading.font = .systemFont(ofSize:19,weight:.semibold);var views:[NSView]=[heading]
        for field in fields{let label=NSTextField(labelWithString:field.title);let control:NSControl
            if let options=field.options{let popup=NSPopUpButton();popup.addItems(withTitles:options.map{$0.1});popup.selectItem(at:options.firstIndex(where:{$0.0==field.value}) ?? 0);control=popup}else{let text=NSTextField(string:field.value);text.isEditable = !field.readOnly;text.isSelectable=true;control=text}
            control.setAccessibilityLabel(field.title);inputs[field.key]=control;let row=NSStackView(views:[label,control]);label.widthAnchor.constraint(equalToConstant:125).isActive=true;row.spacing=12;views.append(row)
        }
        submit.target=self;submit.action=#selector(apply);let close=NSButton(title:"閉じる",target:self,action:#selector(close));views += [status,NSStackView(views:[NSView(),close,submit])];Self.layout(views,in:window);baseline=values()
    }
    static func layout(_ views:[NSView],in window:NSWindow){let stack=NSStackView(views:views);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=12;stack.translatesAutoresizingMaskIntoConstraints=false;window.contentView!.addSubview(stack);NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),stack.bottomAnchor.constraint(lessThanOrEqualTo:window.contentView!.bottomAnchor,constant:-20)]);for view in views{view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}}
    func show(){window.center();window.makeKeyAndOrderFront(nil)}
    private func values()->[String:String]{var result:[String:String]=[:];for field in fields{if let popup=inputs[field.key] as? NSPopUpButton,let options=field.options{result[field.key]=options[popup.indexOfSelectedItem].0}else{result[field.key]=(inputs[field.key] as? NSTextField)?.stringValue ?? ""}};return result}
    func confirmDiscard()->Bool{!busy && (values()==baseline || confirm("編集中の内容は保存されません。"))}
    @objc private func apply(){guard !busy else{return};let values=values()
        busy=true;submit.isEnabled=false;inputs.values.forEach{$0.isEnabled=false};task=Task{@MainActor [weak self] in guard let self else{return};defer{self.busy=false;self.submit.isEnabled=true;self.inputs.values.forEach{$0.isEnabled=true};self.task=nil;self.onFinished?()};do{let text=try await self.save(values);try Task.checkCancellation();self.status.stringValue=text;self.baseline=values}catch is CancellationError{}catch{self.status.stringValue=error.localizedDescription}}
    }
    @objc private func close(){guard confirmDiscard()else{return};NativeUserAdministrationWindow.dismiss(window)}
    func windowShouldClose(_ sender:NSWindow)->Bool{guard confirmDiscard()else{return false};if let parent=window.sheetParent{parent.endSheet(window);return false};return true}
    func windowWillClose(_ notification:Notification){task?.cancel()}
    func closeForTesting(){close()}
    func setForTesting(_ key:String,_ value:String){if let text=inputs[key] as? NSTextField{text.stringValue=value};if let popup=inputs[key] as? NSPopUpButton,let options=fields.first(where:{$0.key==key})?.options,let i=options.firstIndex(where:{$0.0==value}){popup.selectItem(at:i)}}
    func submitForTesting(){submit.performClick(nil)}
    var testState:(busy:Bool,status:String){(busy,status.stringValue)}
}

final class NativeUserAdministrationProfileWindow: NSObject, NSWindowDelegate {
    static let languages = [("ja","日本語"),("en","英語"),("cz","チェコ語"),("de","ドイツ語"),("uk","ウクライナ語")]
    let window = NSPanel(contentRect: NSRect(x:0,y:0,width:660,height:650), styleMask:[.titled,.closable], backing:.buffered, defer:false)
    private let api: NativeUserAdministration, avatarStore: NativeUserAvatarStore, id: String
    private let confirm: (String)->Bool, confirmRemove: ()->Bool
    private var profileBaseline: [String] = [], languageBaseline = 0
    private let name = NSTextField(), username = NSTextField(), company = NSTextField(), language = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString:""), photo = NSTextField(wrappingLabelWithString:"")
    private let animation = NSTextField(wrappingLabelWithString:"")
    private let avatar = NativeUserAvatarView(frame:.zero)
    private var task: Task<Void,Never>?, pending: NativeUserAvatarStore.Prepared?, savedReference = ""
    private var buttons: [String:NSButton] = [:]
    var onChanged: (()->Void)?

    init(service: CRMService, avatarStore: NativeUserAvatarStore? = nil,
         confirmDiscard: @escaping (String)->Bool = NativeUserAdministrationWindow.askDiscard,
         confirmRemove: @escaping ()->Bool = NativeUserAdministrationProfileWindow.askRemove) throws {
        api = NativeUserAdministration(service:service)
        let row = try api.currentProfile(); id = row.id
        self.avatarStore = try avatarStore ?? NativeUserAvatarStore(service:service)
        confirm = confirmDiscard; self.confirmRemove = confirmRemove
        super.init(); window.title = "自分のプロフィール"; window.delegate = self
        name.stringValue = row["name"].string; username.stringValue = row["username"].string; company.stringValue = row["account_name"].string
        language.addItems(withTitles:Self.languages.map{$0.1})
        language.selectItem(at:Self.languages.firstIndex(where:{$0.0==row["userLanguage"].string}) ?? 0)
        language.setAccessibilityLabel("表示言語")
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        var views: [NSView] = [title,NSTextField(labelWithString:row["email"].string)]
        for (title,control) in [("名前",name),("ユーザー名",username),("会社名",company)] {
            control.setAccessibilityLabel(title)
            let label = NSTextField(labelWithString:title); label.widthAnchor.constraint(equalToConstant:125).isActive = true
            let line = NSStackView(views:[label,control]); line.spacing = 8; views.append(line)
        }
        views.append(button("プロフィールを保存",#selector(saveProfile)))
        let languageRow = NSStackView(views:[NSTextField(labelWithString:"表示言語"),language,button("言語を保存",#selector(saveLanguage))]); languageRow.spacing = 8
        views.append(languageRow)
        avatar.widthAnchor.constraint(equalToConstant:104).isActive = true
        avatar.heightAnchor.constraint(equalToConstant:104).isActive = true
        photo.setAccessibilityLabel("プロフィール写真の状態"); animation.setAccessibilityLabel("写真の再生状態")
        animation.textColor = .secondaryLabelColor; animation.font = .systemFont(ofSize:12)
        let photoText = NSStackView(views:[photo,animation]); photoText.orientation = .vertical; photoText.alignment = .leading; photoText.spacing = 8
        let picture = NSStackView(views:[avatar,photoText]); picture.spacing = 18; views.append(picture)
        let help = NSTextField(wrappingLabelWithString:"PNG・JPEG・GIF・WebP、4MB以内。選択した写真を確認してから保存してください。")
        help.font = .systemFont(ofSize:12); help.textColor = .secondaryLabelColor; views.append(help)
        let photoButtons = NSStackView(views:[button("写真を選択…",#selector(selectPhoto)),button("写真を保存",#selector(savePhoto)),button("選択を取り消す",#selector(cancelPhoto)),button("写真を削除…",#selector(removePhoto))]); photoButtons.spacing = 8
        status.maximumNumberOfLines = 3; status.setAccessibilityLabel("プロフィールの操作結果")
        views += [photoButtons,status,NSView(),button("閉じる",#selector(close))]
        NativeUserAdministrationForm.layout(views,in:window)
        profileBaseline = profileValues; languageBaseline = language.indexOfSelectedItem
        avatar.onAnimationStatusChange = { [weak self] value in self?.animation.stringValue = value.message }
        reloadPhoto(); controls()
    }
    deinit { task?.cancel(); if let pending { avatarStore.discard(pending) } }
    private static func askRemove()->Bool {
        let alert = NSAlert(); alert.messageText = "プロフィール写真を削除しますか？"
        alert.addButton(withTitle:"キャンセル"); alert.addButton(withTitle:"削除")
        return alert.runModal() == .alertSecondButtonReturn
    }
    private func button(_ title:String,_ action:Selector)->NSButton {
        let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; buttons[title] = b; return b
    }
    func show(){window.center();window.makeKeyAndOrderFront(nil)}
    private var profileValues:[String]{[name.stringValue,username.stringValue,company.stringValue]}
    private func controls() {
        let idle = task == nil
        buttons.values.forEach{$0.isEnabled = idle}
        [name,username,company].forEach{$0.isEnabled = idle}; language.isEnabled = idle
        buttons["写真を保存"]?.isEnabled = idle && pending != nil
        buttons["選択を取り消す"]?.isEnabled = pending != nil || !idle
        buttons["写真を削除…"]?.isEnabled = idle && pending == nil && !savedReference.isEmpty
    }
    func confirmDiscard()->Bool {
        guard task == nil, window.attachedSheet == nil else { return false }
        window.makeFirstResponder(nil)
        return (profileValues == profileBaseline && language.indexOfSelectedItem == languageBaseline && pending == nil)
            || confirm("プロフィール・言語・選択した写真の変更は保存されません。")
    }
    @objc private func saveProfile() {
        guard task == nil else { return }; window.makeFirstResponder(nil)
        do {_ = try api.updateProfile(id,name:name.stringValue,username:username.stringValue,accountName:company.stringValue);status.stringValue = "プロフィールを保存しました。";profileBaseline = profileValues;onChanged?()}
        catch {status.stringValue = error.localizedDescription}
    }
    @objc private func saveLanguage() {
        guard task == nil else { return }
        do {_ = try api.setLanguage(id,language:Self.languages[language.indexOfSelectedItem].0);status.stringValue = "言語を保存しました。";languageBaseline = language.indexOfSelectedItem;onChanged?()}
        catch {status.stringValue = error.localizedDescription}
    }
    private func reloadPhoto() {
        avatar.stopAnimation(); animation.stringValue = ""
        do {
            let row = try api.currentProfile(); savedReference = row["avatar"].string
            let image = try avatarStore.image(forUserID:id); avatar.set(image:image,name:row["name"].string)
            photo.stringValue = image != nil ? "保存済みのプロフィール写真です。" : savedReference.isEmpty ? "プロフィール写真は未設定です。" : "以前の写真はこのMacに保存されていません。"
            if image != nil {animatePhoto()}
        } catch {avatar.set(image:nil,name:name.stringValue);photo.stringValue = "写真を読み込めません。";status.stringValue = error.localizedDescription}
    }
    private func animatePhoto(prepared:NativeUserAvatarStore.Prepared? = nil) {
        avatar.setAnimationSource { [store = avatarStore, id] in
            let work = Task.detached(priority:.utility){()throws->Data? in
                if let prepared {return try store.original(prepared).data}
                return try store.original(forUserID:id)?.data
            }
            return try await withTaskCancellationHandler(operation:{let data = try await work.value;try Task.checkCancellation();return data},onCancel:{work.cancel()})
        }
    }
    @objc private func selectPhoto() {
        guard task == nil, window.attachedSheet == nil else { return }
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.png,.jpeg,.gif,.webP]
        picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.beginSheetModal(for:window){[weak self] result in if result == .OK,let url = picker.url {self?.preparePhoto(url)}}
    }
    private func preparePhoto(_ file:URL) {
        guard task == nil else { return }
        status.stringValue = "写真を読み込んでいます…"
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {self.task = nil;self.controls()}
            do {
                let prepared = try await self.avatarStore.prepare(file)
                do {
                    try Task.checkCancellation();let image = try self.avatarStore.preview(prepared)
                    if let previous = self.pending {self.avatarStore.discard(previous)}
                    self.pending = prepared;self.avatar.set(image:image,name:self.name.stringValue)
                    self.animatePhoto(prepared:prepared);self.photo.stringValue = "選択した写真のプレビューです。まだ保存していません。"
                    self.status.stringValue = "写真を確認して「写真を保存」を押してください。"
                } catch {self.avatarStore.discard(prepared);throw error}
            } catch is CancellationError {self.status.stringValue = "写真の選択を中止しました。"}
            catch {self.status.stringValue = error.localizedDescription}
        }; controls()
    }
    @objc private func savePhoto() {
        guard task == nil,let prepared = pending else { return }
        status.stringValue = "写真を保存しています…"
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {self.task = nil;self.controls()}
            do {
                let work = Task.detached(priority:.utility){[store = self.avatarStore] in try store.commit(prepared)}
                let receipt = try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                self.pending = nil;self.reloadPhoto()
                self.status.stringValue = receipt.cleanupDeferred ? "写真を保存しました。以前の写真の画像ファイルは削除できませんでした。" : "プロフィール写真を保存しました。"
                self.onChanged?()
            } catch {
                self.pending = nil;self.reloadPhoto()
                self.status.stringValue = "写真を保存できませんでした。もう一度写真を選択してください。 " + error.localizedDescription
            }
        }; controls()
    }
    @objc private func cancelPhoto() {
        if let task {task.cancel();status.stringValue = "写真の処理を中止しています…";return}
        if let pending {avatarStore.discard(pending);self.pending = nil}
        reloadPhoto();status.stringValue = "写真の選択を取り消しました。";controls()
    }
    @objc private func removePhoto() {
        guard task == nil,pending == nil,!savedReference.isEmpty else { return }
        let expectedReference = savedReference
        guard confirmRemove() else { return }
        status.stringValue = "写真を削除しています…"
        task = Task { @MainActor [weak self] in
            guard let self else { return };defer {self.task = nil;self.controls()}
            do {
                let work = Task.detached(priority:.utility){[store = self.avatarStore] in try store.clearCurrent(expectedReference:expectedReference)}
                let cleaned = try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                self.reloadPhoto();self.status.stringValue = cleaned ? "プロフィール写真を削除しました。" : "写真の設定を解除しました。画像ファイルは削除できませんでした。";self.onChanged?()
            } catch is CancellationError {self.reloadPhoto();self.status.stringValue = "写真の削除を中止しました。"}
            catch {self.reloadPhoto();self.status.stringValue = error.localizedDescription}
        }; controls()
    }
    private func discardPhoto() {if let pending {avatarStore.discard(pending);self.pending = nil};avatar.stopAnimation()}
    @objc private func close(){guard confirmDiscard() else {return};discardPhoto();NativeUserAdministrationWindow.dismiss(window)}
    func windowShouldClose(_ sender:NSWindow)->Bool{guard confirmDiscard() else {return false};discardPhoto();if let parent = window.sheetParent{parent.endSheet(window);return false};return true}
    func windowWillClose(_ notification:Notification){task?.cancel();discardPhoto()}
    func setForTesting(name:String,username:String,company:String){self.name.stringValue = name;self.username.stringValue = username;self.company.stringValue = company}
    func invokeForTesting(_ title:String){buttons[title]?.performClick(nil)}
    func languageForTesting(_ code:String){if let i = Self.languages.firstIndex(where:{$0.0==code}){language.selectItem(at:i)}}
    func selectPhotoForTesting(_ file:URL){preparePhoto(file)}
    var testStatus:String{status.stringValue}
    var photoTestState:(busy:Bool,pending:Bool,reference:String,message:String){(task != nil,pending != nil,savedReference,photo.stringValue)}
}

final class NativeUserAdministrationPartnerPicker:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSWindowDelegate {
    let window=NSPanel(contentRect:NSRect(x:0,y:0,width:640,height:520),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    private let service:CRMService,api:NativeUserAdministration,userID:String,onChanged:()->Void
    private let search=NSSearchField(),table=NSTableView(),status=NSTextField(wrappingLabelWithString:"")
    private var rows:[NativeRecord]=[],offset=0,total=0,currentAccountID:String?
    init(service:CRMService,userID:String,currentAccountID:String?,onChanged:@escaping()->Void)throws{self.service=service;api=NativeUserAdministration(service:service);_ = try api.detail(userID);self.userID=userID;self.currentAccountID=currentAccountID;self.onChanged=onChanged;super.init();window.title="パートナー企業";window.delegate=self;search.placeholderString="取引先名で検索";search.target=self;search.action=#selector(searchChanged)
        let column=NSTableColumn(identifier:.init("name"));column.title="取引先";column.width=570;table.addTableColumn(column);table.delegate=self;table.dataSource=self;table.rowHeight=29
        let scroll=NSScrollView();scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.heightAnchor.constraint(equalToConstant:250).isActive=true
        let controls=NSStackView(views:[NSButton(title:"前の100件",target:self,action:#selector(previous)),NSButton(title:"次の100件",target:self,action:#selector(next)),NSView(),NSButton(title:"割当を解除",target:self,action:#selector(clear)),NSButton(title:"選択して保存",target:self,action:#selector(save)),NSButton(title:"閉じる",target:self,action:#selector(close))])
        NativeUserAdministrationForm.layout([NSTextField(wrappingLabelWithString:"パートナー自身の企業です。本人には閲覧のみ許可されます。"),search,scroll,status,controls],in:window);reload()
    }
    func show(){window.center();window.makeKeyAndOrderFront(nil)}
    private func reload(){do{_ = try api.detail(userID);let page=try service.references("crm_Accounts",search:search.stringValue,offset:offset);rows=page.rows;total=page.total;status.stringValue="\(total) 件";table.reloadData();if let currentAccountID,let index=rows.firstIndex(where:{$0["id"].string==currentAccountID}){table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false)}}catch{rows=[];table.reloadData();status.stringValue=error.localizedDescription}}
    func numberOfRows(in tableView:NSTableView)->Int{rows.count}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView?{rows.indices.contains(row) ? NSTextField(labelWithString:rows[row]["name"].string):nil}
    @objc private func searchChanged(){offset=0;reload()}
    @objc private func previous(){offset=max(0,offset-100);reload()}
    @objc private func next(){if offset+rows.count<total{offset+=100;reload()}}
    private func assign(_ id:String?){do{_ = try api.setPartnerAccount(userID,accountID:id);currentAccountID=id;status.stringValue=id == nil ? "パートナー企業の割当を解除しました。":"パートナー企業を保存しました。";onChanged()}catch{status.stringValue=error.localizedDescription}}
    @objc private func save(){guard rows.indices.contains(table.selectedRow)else{status.stringValue="取引先を選択してください。";return};assign(rows[table.selectedRow]["id"].string)}
    @objc private func clear(){assign(nil)}
    @objc private func close(){NativeUserAdministrationWindow.dismiss(window)}
    func windowShouldClose(_ sender:NSWindow)->Bool{if let parent=window.sheetParent{parent.endSheet(window);return false};return true}
    func closeForTesting(){close()}
    func assignForTesting(_ accountID:String?){if let accountID,let i=rows.firstIndex(where:{$0["id"].string==accountID}){table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false);save()}else if accountID==nil{clear()}}
    var testStatus:String{status.stringValue}
}
