import AppKit
import PrompterCore

/// Clickable list of the notes' headings, indented by level, with the section
/// being read highlighted.
@MainActor
final class OutlineSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView()
    /// Called with the index of the clicked heading.
    var onSelect: ((Int) -> Void)?

    private let table = FirstClickTableView()
    private let scrollView = NSScrollView()
    private var headings: [Heading] = []
    private var topLevel = 1
    private var current: Int?
    var appearance = TextAppearance() {
        didSet { if appearance != oldValue { table.reloadData() } }
    }

    override init() {
        super.init()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor

        let column = NSTableColumn(identifier: .init("heading"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.rowHeight = 22
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    func setHeadings(_ headings: [Heading]) {
        self.headings = headings
        topLevel = headings.map(\.level).min() ?? 1
        current = nil
        table.reloadData()
    }

    /// Highlights the section being read and keeps it in view.
    func setCurrent(_ index: Int?) {
        guard index != current else { return }
        let previous = current
        current = index
        let rows = IndexSet([previous, index].compactMap { $0 }.filter { headings.indices.contains($0) })
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        if let index { table.scrollRowToVisible(index) }
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard headings.indices.contains(row) else { return }
        onSelect?(row)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        headings.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: OutlineCell.identifier, owner: nil) as? OutlineCell ?? OutlineCell()
        let heading = headings[row]
        cell.configure(text: heading.text, depth: heading.level - topLevel, isCurrent: row == current, appearance: appearance)
        return cell
    }
}

/// Rows respond to the first click, since the overlay never becomes key.
private final class FirstClickTableView: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class OutlineCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("OutlineCell")

    private let label = NSTextField(labelWithString: "")
    private let highlight = NSView()
    private var leading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 5
        highlight.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            leading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(text: String, depth: Int, isCurrent: Bool, appearance: TextAppearance) {
        leading.constant = 12 + CGFloat(min(depth, 4)) * 12
        let font = NSFont.systemFont(ofSize: depth == 0 ? 12 : 11.5, weight: isCurrent ? .semibold : (depth == 0 ? .medium : .regular))
        // Same text treatment as the notes.
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(appearance.textOpacity * (isCurrent ? 1 : 0.72)),
        ]
        if let band = appearance.band { attributes[.backgroundColor] = band }
        if let shadow = appearance.shadow { attributes[.shadow] = shadow }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        attributes[.paragraphStyle] = paragraph
        label.attributedStringValue = NSAttributedString(string: text, attributes: attributes)
        highlight.isHidden = !isCurrent
    }
}
