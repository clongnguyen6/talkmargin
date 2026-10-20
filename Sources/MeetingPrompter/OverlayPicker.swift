import AppKit
import PrompterCore

/// A dropdown list drawn inside the overlay window (never a separate window, so
/// it is hidden from screen sharing exactly like the overlay). Rows respond to
/// the first click and to right-⌥ arrows / Return / digits routed in by the
/// controller; the picker itself never takes the keyboard.
@MainActor
final class OverlayPicker: DropdownBox, NSTableViewDataSource, NSTableViewDelegate {
    enum Row {
        /// Group title or notice; cannot be chosen.
        case header(String)
        case item(id: String, title: String, detail: String?, isCurrent: Bool)
        /// A command such as "open another file".
        case action(id: String, title: String, symbol: String)

        var id: String? {
            switch self {
            case .header: nil
            case .item(let id, _, _, _), .action(let id, _, _): id
            }
        }

        var isSelectable: Bool { id != nil }
    }

    /// Called with the row id the user chose.
    var onPick: ((String) -> Void)?

    static let width: CGFloat = 340
    private static let maxListHeight: CGFloat = 420

    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: tr(.pickerKeys))
    private let table = PickerTableView()
    private let scrollView = NSScrollView()
    private var rows: [Row] = []
    private var highlighted: Int?
    private var heightConstraint: NSLayoutConstraint!

    override init() {
        super.init()
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.onHover = { [weak self] in self?.setHighlight($0) }

        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(scrollView)
        addSubview(hintLabel)
        let width = widthAnchor.constraint(equalToConstant: Self.width)
        width.priority = .dragThatCannotResizeWindow
        heightConstraint = heightAnchor.constraint(equalToConstant: 100)
        heightConstraint.priority = .dragThatCannotResizeWindow
        NSLayoutConstraint.activate([
            width, heightConstraint,
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            hintLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Texts of its own; rows and title come from `setRows`.
    func localize() {
        hintLabel.stringValue = tr(.pickerKeys)
    }

    /// Replaces the rows; `highlight` is the row the keyboard starts on.
    func setRows(_ rows: [Row], title: String, highlight: Int?) {
        self.rows = rows
        titleLabel.stringValue = title
        highlighted = highlight.flatMap { rows.indices.contains($0) && rows[$0].isSelectable ? $0 : nil }
        table.reloadData()
        let list = rows.reduce(CGFloat(0)) { $0 + Self.height(of: $1) }
        // Title, hint and their paddings around the list.
        heightConstraint.constant = min(list, Self.maxListHeight) + 8 + 17 + 6 + 6 + 14 + 8
        if let highlighted { table.scrollRowToVisible(highlighted) }
    }

    // MARK: - Keyboard, routed from the controller

    func moveHighlight(by direction: Int) {
        guard let next = PickerList.move(from: highlighted, by: direction, selectable: rows.map(\.isSelectable)) else { return }
        setHighlight(next)
        table.scrollRowToVisible(next)
    }

    func pickHighlighted() {
        guard let highlighted, let id = rows[highlighted].id else { return }
        onPick?(id)
    }

    /// Chooses the Nth selectable row (⌥1…⌥9).
    func pick(ordinal: Int) {
        guard let row = PickerList.ordinal(ordinal, selectable: rows.map(\.isSelectable)), let id = rows[row].id else { return }
        onPick?(id)
    }

    private func setHighlight(_ row: Int?) {
        let row = row.flatMap { rows.indices.contains($0) && rows[$0].isSelectable ? $0 : nil }
        guard row != highlighted else { return }
        let changed = IndexSet([highlighted, row].compactMap { $0 })
        highlighted = row
        table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row), let id = rows[row].id else { return }
        onPick?(id)
    }

    // MARK: - Table

    private static func height(of row: Row) -> CGFloat {
        switch row {
        case .header: 24
        case .item(_, _, let detail, _): detail == nil ? 28 : 40
        case .action: 30
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { Self.height(of: rows[row]) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: PickerCell.identifier, owner: nil) as? PickerCell ?? PickerCell()
        cell.configure(rows[row], ordinal: ordinal(of: row), highlighted: row == highlighted)
        return cell
    }

    /// 1-based position among selectable rows, shown for the first nine (⌥1…⌥9).
    private func ordinal(of row: Int) -> Int? {
        guard rows[row].isSelectable else { return nil }
        let ordinal = rows[...row].filter(\.isSelectable).count
        return ordinal <= 9 ? ordinal : nil
    }
}

/// Clicks work without the window being key; the pointer moves the highlight,
/// which stays where it was when the pointer leaves, so ⌥↩ still has a target.
private final class PickerTableView: NSTableView {
    var onHover: ((Int) -> Void)?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onHover?(row) }
    }
}

private final class PickerCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PickerCell")

    private let highlight = NSView()
    private let mark = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let ordinal = NSTextField(labelWithString: "")
    private var titleCenter: NSLayoutConstraint!
    private var titleTop: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        highlight.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        for view in [highlight, mark, title, detail, ordinal] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        mark.font = .systemFont(ofSize: 12, weight: .semibold)
        mark.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ordinal.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        ordinal.textColor = .tertiaryLabelColor

        titleCenter = title.centerYAnchor.constraint(equalTo: centerYAnchor)
        titleTop = title.topAnchor.constraint(equalTo: topAnchor, constant: 5)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            mark.widthAnchor.constraint(equalToConstant: 16),
            mark.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: ordinal.leadingAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: ordinal.leadingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            ordinal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            ordinal.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(_ row: OverlayPicker.Row, ordinal number: Int?, highlighted: Bool) {
        highlight.isHidden = !highlighted
        ordinal.stringValue = number.map { "⌥\($0)" } ?? ""
        switch row {
        case .header(let text):
            mark.stringValue = ""
            title.stringValue = text.uppercased()
            title.font = .systemFont(ofSize: 10, weight: .semibold)
            title.textColor = .tertiaryLabelColor
            detail.isHidden = true
            titleTop.isActive = false
            titleCenter.isActive = true
        case .item(_, let text, let subtitle, let isCurrent):
            mark.stringValue = isCurrent ? "✓" : ""
            mark.textColor = .controlAccentColor
            title.stringValue = text
            title.font = .systemFont(ofSize: 12.5, weight: isCurrent ? .semibold : .regular)
            title.textColor = .labelColor
            detail.stringValue = subtitle ?? ""
            detail.isHidden = subtitle == nil
            titleCenter.isActive = subtitle == nil
            titleTop.isActive = subtitle != nil
        case .action(_, let text, let symbol):
            mark.stringValue = ""
            mark.attributedStringValue = Self.symbol(symbol)
            title.stringValue = text
            title.font = .systemFont(ofSize: 12.5, weight: .medium)
            title.textColor = .labelColor
            detail.isHidden = true
            titleTop.isActive = false
            titleCenter.isActive = true
        }
    }

    private static func symbol(_ name: String) -> NSAttributedString {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) else { return NSAttributedString() }
        let attachment = NSTextAttachment()
        attachment.image = image.withSymbolConfiguration(.init(hierarchicalColor: .secondaryLabelColor)) ?? image
        return NSAttributedString(attachment: attachment)
    }
}
