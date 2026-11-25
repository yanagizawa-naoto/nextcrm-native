import AppKit
import CoreText

/// Display text without constructing TextKit. Once editing starts, preserve the native
/// editor and its undo/composition state until the form closes, even across scrolling.
final class DeferredTextInput: NSView, NSTextViewDelegate {
    private var stored: String
    let label: String; let readOnly: Bool
    private(set) var editor: NSTextView?
    private var scroller: NSScrollView?
    private var editingUndoManager: UndoManager?
    var activated: (() -> Void)?
    private static let font = NSFont.systemFont(ofSize:13)
    init(value: String, label: String, readOnly: Bool) {
        stored = value; self.label = label; self.readOnly = readOnly
        super.init(frame:.zero); setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var string: String {
        get { editor?.string ?? stored }
        set { if let editor { if editor.string != newValue { editor.string = newValue } } else { stored = newValue }; needsDisplay = true }
    }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in guard let self, self.window?.firstResponder === self else { return }; self.focusEditor() }
        return true
    }
    func activate() {
        guard editor == nil else { return }
        let text = NSTextView(); text.isRichText = false; text.allowsUndo = true; text.font = Self.font
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.string = stored; stored = ""; text.isEditable = !readOnly; text.isSelectable = true; text.delegate = self
        text.minSize = NSSize(width:0,height:76); text.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true; text.textContainerInset = NSSize(width:6,height:6); text.setAccessibilityLabel(label)
        let scroll = NSScrollView(frame:bounds); scroll.autoresizingMask = [.width,.height]; scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        addSubview(scroll); editor = text; scroller = scroll; activated?()
        NSAccessibility.post(element:self,notification:.layoutChanged)
    }
    func focusEditor() { activate(); if let editor { window?.makeFirstResponder(editor) } }
    func undoManager(for view: NSTextView) -> UndoManager? {
        if editingUndoManager == nil { editingUndoManager = window?.undoManager ?? UndoManager() }; return editingUndoManager
    }
    override func mouseDown(with event: NSEvent) { activate(); if let editor { window?.makeFirstResponder(editor); editor.mouseDown(with:event) } }
    override func draw(_ dirtyRect: NSRect) {
        guard editor == nil, let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.textBackgroundColor.setFill(); bounds.fill(); NSColor.separatorColor.setStroke(); NSBezierPath(rect:bounds.insetBy(dx:0.5,dy:0.5)).stroke()
        let empty = stored.isEmpty; let text = empty ? (readOnly ? "未設定" : "クリックして入力") : String(stored.prefix(2048))
        let attributed = NSAttributedString(string:text,attributes:[.font:Self.font,.foregroundColor:empty ? NSColor.placeholderTextColor : NSColor.textColor])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed),CFRange(location:0,length:0),CGPath(rect:bounds.insetBy(dx:7,dy:7),transform:nil),nil)
        context.saveGState(); CTFrameDraw(frame,context); context.restoreGState()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func isAccessibilityElement() -> Bool { editor == nil }
    override func isAccessibilityEnabled() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { editor == nil ? .button : .group }
    override func accessibilityValue() -> Any? { editor == nil ? String(stored.prefix(2048)) : nil }
    override func accessibilityHelp() -> String? { editor == nil ? "選択すると標準の長文入力欄を開きます。" : nil }
    override func accessibilityPerformPress() -> Bool { focusEditor(); return true }
    override func setAccessibilityFocused(_ focused: Bool) { if focused { focusEditor() } }
}

final class CRMFormWindow: NSWindow {
    var moveFocus: ((NSView?,Int) -> Bool)?
    var focusChanged: (() -> Void)?
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        if result { DispatchQueue.main.async { [weak self] in self?.focusChanged?() } }; return result
    }
    override func selectNextKeyView(_ sender: Any?) { if moveFocus?(nil,1) != true { super.selectNextKeyView(sender) } }
    override func selectPreviousKeyView(_ sender: Any?) { if moveFocus?(nil,-1) != true { super.selectPreviousKeyView(sender) } }
    override func selectKeyView(following view: NSView) { if moveFocus?(view,1) != true { super.selectKeyView(following:view) } }
    override func selectKeyView(preceding view: NSView) { if moveFocus?(view,-1) != true { super.selectKeyView(preceding:view) } }
}

final class CRMFormContentView: FlippedContentView {
    var fields: (() -> [Any])?
    var ready: (() -> Void)?
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { fields?() ?? super.accessibilityChildren() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { DispatchQueue.main.async { [weak self] in self?.ready?() } } }
}

final class CRMFormAccessibilityField: NSAccessibilityElement {
    weak var content: CRMFormContentView?
    var label = ""; var rect = NSRect.zero; var show: (() -> Void)?
    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label+"の入力欄へ移動" }
    override func accessibilityParent() -> Any? { content }
    override func accessibilityFrame() -> NSRect { guard let content, let window = content.window else { return .zero }; return window.convertToScreen(content.convert(rect,to:nil)) }
    override func accessibilityPerformPress() -> Bool { show?(); return true }
    override func setAccessibilityFocused(_ focused: Bool) { if focused { show?() } }
}
