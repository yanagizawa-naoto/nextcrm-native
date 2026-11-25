import AppKit

/// Presents a value-only prerequisite decision. It neither holds a CRMService
/// nor performs the state changes described by the selected choice.
@MainActor final class NativePersonalRuntimeRequirementWindow:NSObject {
    typealias Prompt=NativePersonalRuntimePrerequisites.Prompt
    typealias Choice=NativePersonalRuntimePrerequisites.Choice
    let window=NSPanel(contentRect:NSRect(x:0,y:0,width:740,height:540),styleMask:[.titled],backing:.buffered,defer:false)
    private let prompt:Prompt
    private var selected:Choice
    private var choices:[NSButton]=[]
    private var completion:CheckedContinuation<Choice?,Never>?
    private var canceled=false,presented=false,ending=false
    private init(prompt:Prompt)throws {
        guard let first=prompt.choices.first,!prompt.title.isEmpty,
              prompt.choices.count<=Choice.allCases.count,Set(prompt.choices).count==prompt.choices.count else {
            throw NativeDBError.message("確認する内容を読み込めませんでした。もう一度開いてください。")
        }
        self.prompt=prompt;selected=first;super.init();window.title=prompt.title
        let title=NSTextField(labelWithString:prompt.title);title.font = .systemFont(ofSize:20,weight:.semibold)
        let count=NSTextField(labelWithString:"設定対象：\(prompt.configured)件　復元前の処理：\(prompt.oldJobs)件　結果の確認が必要：\(prompt.ambiguousJobs)件")
        count.font = .systemFont(ofSize:12);count.setAccessibilityLabel("確認対象の件数")
        let notes=NSTextField(wrappingLabelWithString:prompt.notes.joined(separator:"\n\n"))
        notes.font = .systemFont(ofSize:13);notes.setAccessibilityLabel("再開前に確認する内容")
        var optionViews:[NSView]=[]
        for (index,choice) in prompt.choices.enumerated() {
            let button=NSButton(radioButtonWithTitle:choice.title,target:self,action:#selector(selectChoice(_:)))
            button.tag=index;button.state=index==0 ? .on:.off;button.setAccessibilityLabel(choice.title)
            choices.append(button);optionViews.append(button)
        }
        let options=NSStackView(views:optionViews);options.orientation = .vertical;options.alignment = .leading;options.spacing=10
        let detail=NSTextField(wrappingLabelWithString:"この確認を保存しても自動処理は再開しません。確認後、使う機能の「有効にする」を選んでください。")
        detail.font = .systemFont(ofSize:12);detail.textColor = .secondaryLabelColor
        let cancel=NSButton(title:"キャンセル",target:self,action:#selector(cancelChoice));cancel.bezelStyle = .rounded;cancel.keyEquivalent="\u{1b}"
        let save=NSButton(title:"この内容で確認を保存",target:self,action:#selector(acceptChoice));save.bezelStyle = .rounded
        let footer=NSStackView(views:[NSView(),cancel,save]);footer.spacing=10
        InvoiceMailUI.layout(window,[title,count,notes,options,detail,footer])
    }
    static func choose(prompt:Prompt,on parent:NSWindow)async throws->Choice? {
        try Task.checkCancellation()
        guard parent.attachedSheet==nil else{throw NativeDBError.message("開いている確認画面を閉じてから操作してください。")}
        let controller=try NativePersonalRuntimeRequirementWindow(prompt:prompt)
        return await withTaskCancellationHandler(operation:{
            await withCheckedContinuation {continuation in
                controller.completion=continuation
                guard !controller.canceled,!Task.isCancelled else{controller.complete(nil);return}
                controller.presented=true
                parent.beginSheet(controller.window){_ in
                    controller.window.orderOut(nil)
                    controller.complete(controller.canceled ? nil:controller.result)
                }
            }
        },onCancel:{Task {@MainActor in controller.cancel()}})
    }
    private var result:Choice?
    @objc private func selectChoice(_ sender:NSButton) {
        guard !ending,prompt.choices.indices.contains(sender.tag) else{return}
        selected=prompt.choices[sender.tag]
        for button in choices{button.state=button===sender ? .on:.off}
    }
    @objc private func cancelChoice(){cancel()}
    @objc private func acceptChoice(){finish(selected)}
    private func cancel(){canceled=true;finish(nil)}
    private func finish(_ choice:Choice?) {
        guard !ending else{return};ending=true;result=choice
        if presented,let parent=window.sheetParent {parent.endSheet(window,returnCode:choice==nil ? .cancel:.OK)}
        else{window.orderOut(nil);complete(canceled ? nil:choice)}
    }
    private func complete(_ choice:Choice?) {
        let value=completion;completion=nil;value?.resume(returning:choice)
    }
}
