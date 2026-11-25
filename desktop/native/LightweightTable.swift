import AppKit
import CoreText

struct NativeColumn {
    let title: String
    let fraction: CGFloat
    static let accounts = [NativeColumn(title: "会社名", fraction: 0.31), NativeColumn(title: "担当者", fraction: 0.16),
                           NativeColumn(title: "メールアドレス", fraction: 0.25), NativeColumn(title: "電話番号", fraction: 0.17),
                           NativeColumn(title: "状態", fraction: 0.11)]
}

/// One reusable view per visible row. Display-only text does not instantiate NSTextField,
/// Auto Layout constraints, or text editors. Editing continues to use native AppKit controls.
final class LightweightTableCell: NSTableCellView {
    private var columns: [NativeColumn] = []
    private var values: [String] = []
    private var lines: [CTLine] = []
    private var accessibleFields: [NativeTextAccessibility] = []
    private var positiveColumn: Int?
    private var heading = false
    var onColumnPress: ((Int) -> Void)?
    var actionableColumns: Set<Int> = []
    var horizontalInset: CGFloat = 0
    private static let regular = NSFont.systemFont(ofSize: 13)
    private static let emphasis = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let ellipsis = makeLine("…", font: regular)
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        if let index = columns.indices.first(where:{ cellRect($0).insetBy(dx:-6,dy:0).contains(point) }), actionableColumns.contains(index), let onColumnPress { onColumnPress(index) }
        else { super.mouseDown(with:event) }
    }
    fileprivate func isActionable(_ index: Int) -> Bool { actionableColumns.contains(index) && onColumnPress != nil }
    fileprivate func pressColumn(_ index: Int) -> Bool {
        if isActionable(index) { onColumnPress?(index); return true }
        return selectFromAccessibility()
    }

    private static func makeLine(_ text: String, font: NSFont) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
    func configure(columns: [NativeColumn], values: [String], positiveColumn: Int? = nil, heading: Bool = false) {
        precondition(columns.count == values.count)
        self.columns = columns; self.values = values; self.positiveColumn = positiveColumn; self.heading = heading
        lines = values.enumerated().map { Self.makeLine($0.element.isEmpty ? "—" : $0.element,
            font: heading ? Self.headerFont : $0.offset == 0 ? Self.emphasis : Self.regular) }
        accessibleFields = values.enumerated().map { index, value in
            let element = NativeTextAccessibility()
            element.owner = self; element.index = index
            element.label = heading ? value : "\(columns[index].title)：\(value.isEmpty ? "未設定" : value)"
            return element
        }
        needsDisplay = true
    }
    private func cellRect(_ index: Int) -> NSRect {
        let width = max(0, bounds.width - horizontalInset * 2)
        let x = horizontalInset + columns.prefix(index).reduce(CGFloat(0)) { $0 + $1.fraction } * width
        return NSRect(x: x + 6, y: 0, width: max(0, width * columns[index].fraction - 12), height: bounds.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let selected = (superview as? NSTableRowView)?.isSelected == true
        let emphasized = (superview as? NSTableRowView)?.isEmphasized == true
        for (index, fullLine) in lines.enumerated() {
            let rect = cellRect(index)
            guard rect.intersects(dirtyRect), rect.width > 0 else { continue }
            let line = CTLineCreateTruncatedLine(fullLine, Double(rect.width), .end, Self.ellipsis) ?? fullLine
            var ascent: CGFloat = 0; var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let color: NSColor = selected && emphasized ? .alternateSelectedControlTextColor :
                heading ? .secondaryLabelColor : positiveColumn == index ? .systemGreen : .labelColor
            context.saveGState(); context.clip(to: rect)
            context.translateBy(x: rect.minX, y: rect.midY); context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity; context.setFillColor(color.cgColor)
            context.textPosition = CGPoint(x: 0, y: -(ascent - descent) / 2)
            CTLineDraw(line, context); context.restoreGState()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { needsDisplay = true } }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? {
        return accessibleFields
    }
    fileprivate func accessibleFrame(_ index: Int) -> NSRect {
        guard columns.indices.contains(index), let window else { return .zero }
        return window.convertToScreen(convert(cellRect(index), to: nil))
    }
    fileprivate func selectFromAccessibility() -> Bool {
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? NSTableView {
                let row = table.row(for: self); guard row >= 0 else { return false }
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.window?.makeFirstResponder(table)
                return true
            }
            ancestor = view.superview
        }
        return false
    }
}

private final class NativeTextAccessibility: NSAccessibilityElement {
    weak var owner: LightweightTableCell?
    var index = 0
    var label = ""
    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { owner != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { owner?.isActionable(index) == true ? .button : .staticText }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityParent() -> Any? { owner }
    override func accessibilityFrame() -> NSRect { owner?.accessibleFrame(index) ?? .zero }
    override func accessibilityPerformPress() -> Bool { owner?.pressColumn(index) ?? false }
}
