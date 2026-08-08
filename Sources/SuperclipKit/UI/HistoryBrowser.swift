import AppKit

/// A scrollable view of everything Superclip has kept.
///
/// Deliberately different from search. Search is for when you can describe the
/// thing but not find it; browsing is for when you want to see what is actually
/// there. So filtering here is literal substring matching in strict recency
/// order — no ranking, no model, no reordering under you as you type. A list
/// that rearranges itself while you read it is not a list you can trust.
///
/// It is also the only place the stored history is visible, which makes it the
/// right home for deleting one specific clip. "Forget everything" is the blunt
/// instrument; this is the scalpel.
@MainActor
final class HistoryBrowser: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    private var panel: BrowserPanel?
    private var filterField: NSTextField!
    private var table: NSTableView!
    private var detail: NSTextView!
    private var footer: NSTextField!

    private var all: [ClipboardMonitor.Entry] = []
    private var visible: [ClipboardMonitor.Entry] = []

    var onPaste: ((String) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onCancel: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: - Presentation

    func show(entries: [ClipboardMonitor.Entry]) {
        all = entries
        visible = entries

        let panel = self.panel ?? build()
        self.panel = panel
        filterField.stringValue = ""
        table.reloadData()
        selectRow(0)
        updateFooter()

        position(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(filterField)
    }

    func hide() { panel?.orderOut(nil) }

    // MARK: - Construction

    private func build() -> BrowserPanel {
        let size = NSSize(width: 720, height: 480)
        let panel = BrowserPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        // Filter field, top.
        let icon = NSImageView(frame: NSRect(x: 18, y: 440, width: 20, height: 20))
        icon.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        background.addSubview(icon)

        filterField = NSTextField(frame: NSRect(x: 46, y: 438, width: 656, height: 24))
        filterField.font = .systemFont(ofSize: 14)
        filterField.isBordered = false
        filterField.drawsBackground = false
        filterField.focusRingType = .none
        filterField.placeholderString = "Filter…"
        filterField.delegate = self
        filterField.cell?.usesSingleLineMode = true
        background.addSubview(filterField)

        background.addSubview(divider(y: 430, width: size.width))

        // The list.
        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 58
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 1)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.width = 700
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pasteSelected)

        let scroll = NSScrollView(frame: NSRect(x: 8, y: 150, width: 704, height: 278))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        background.addSubview(scroll)

        background.addSubview(divider(y: 148, width: size.width))

        // Full text of the selected clip.
        let detailScroll = NSScrollView(frame: NSRect(x: 8, y: 38, width: 704, height: 108))
        detail = NSTextView(frame: detailScroll.bounds)
        detail.isEditable = false
        detail.drawsBackground = false
        detail.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        detail.textContainerInset = NSSize(width: 10, height: 8)
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        background.addSubview(detailScroll)

        footer = NSTextField(labelWithString: "")
        footer.frame = NSRect(x: 16, y: 10, width: 688, height: 18)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        background.addSubview(footer)

        panel.contentView = background
        return panel
    }

    private func divider(y: CGFloat, width: CGFloat) -> NSView {
        let line = NSView(frame: NSRect(x: 0, y: y, width: width, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        return line
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                     y: frame.midY - panel.frame.height / 2 + 60))
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visible.indices.contains(row) else { return nil }
        let entry = visible[row]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 58))

        let meta = NSTextField(labelWithString: "\(entry.sourceName)  ·  \(Self.relative.localizedString(for: entry.capturedAt, relativeTo: Date()))")
        meta.frame = NSRect(x: 12, y: 36, width: 676, height: 15)
        meta.font = .systemFont(ofSize: 11, weight: .medium)
        meta.textColor = .secondaryLabelColor
        container.addSubview(meta)

        let preview = NSTextField(labelWithString: Self.snippet(entry.text))
        preview.frame = NSRect(x: 12, y: 8, width: 676, height: 26)
        preview.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        preview.textColor = .labelColor
        preview.lineBreakMode = .byTruncatingTail
        preview.maximumNumberOfLines = 2
        container.addSubview(preview)

        return container
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        detail.string = visible.indices.contains(row) ? visible[row].text : ""
        detail.scroll(NSPoint(x: 0, y: 0))
    }

    /// Collapses whitespace so a multi-line clip still reads as a row rather
    /// than showing two blank lines and a fragment.
    private static func snippet(_ text: String) -> String {
        let flattened = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ⏎ ")
        return flattened.count > 240 ? String(flattened.prefix(240)) + "…" : flattened
    }

    // MARK: - Filtering

    func controlTextDidChange(_ obj: Notification) {
        let query = filterField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        visible = query.isEmpty ? all : all.filter {
            $0.text.lowercased().contains(query) || $0.sourceName.lowercased().contains(query)
        }
        table.reloadData()
        selectRow(0)
        updateFooter()
    }

    private func selectRow(_ row: Int) {
        guard visible.indices.contains(row) else {
            detail.string = ""
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func updateFooter() {
        let count = visible.count
        let total = all.count
        let scope = count == total ? "\(total) clip\(total == 1 ? "" : "s")" : "\(count) of \(total)"
        footer.stringValue = "\(scope)     ↑↓ move     ↩ paste     ⌘⌫ forget this one     esc close"
    }

    // MARK: - Keys

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            pasteSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            // Only when Command is held — plain backspace has to keep editing
            // the filter, or the field becomes unusable.
            guard NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return false }
            forgetSelected()
            return true
        default:
            return false
        }
    }

    private func move(by delta: Int) {
        guard !visible.isEmpty else { return }
        let next = min(max(table.selectedRow + delta, 0), visible.count - 1)
        selectRow(next)
    }

    @objc private func pasteSelected() {
        guard visible.indices.contains(table.selectedRow) else { return }
        onPaste?(visible[table.selectedRow].text)
    }

    private func forgetSelected() {
        let row = table.selectedRow
        guard visible.indices.contains(row) else { return }
        let entry = visible[row]
        onDelete?(entry.id)

        all.removeAll { $0.id == entry.id }
        visible.remove(at: row)
        table.reloadData()
        selectRow(min(row, max(visible.count - 1, 0)))
        updateFooter()
    }
}

/// Borderless panels refuse key status unless told otherwise.
private final class BrowserPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
