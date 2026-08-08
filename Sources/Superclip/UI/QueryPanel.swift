import AppKit

/// A single-line input bar, in the shape of Spotlight.
///
/// Built from AppKit rather than SwiftUI on purpose: this panel has to take
/// keyboard focus *without* activating Superclip, so the app being pasted into
/// stays frontmost, and an `NSTextField` in a non-activating panel is far more
/// dependable at that than SwiftUI's focus machinery.
@MainActor
final class QueryPanel: NSObject, NSTextFieldDelegate {
    private var panel: NonActivatingQueryPanel?
    private var field: NSTextField?

    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(placeholder: String) {
        let panel = self.panel ?? build()
        self.panel = panel
        field?.stringValue = ""
        field?.placeholderString = placeholder
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        if let field { panel.makeFirstResponder(field) }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Construction

    private func build() -> NonActivatingQueryPanel {
        let panel = NonActivatingQueryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 58),
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

        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 560, height: 58))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let icon = NSImageView(frame: NSRect(x: 18, y: 18, width: 22, height: 22))
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        background.addSubview(icon)

        let field = NSTextField(frame: NSRect(x: 50, y: 16, width: 494, height: 26))
        field.font = .systemFont(ofSize: 16)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        background.addSubview(field)
        self.field = field

        panel.contentView = background
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                     y: frame.maxY - panel.frame.height - 160))
    }

    // MARK: - Keys

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let query = (field?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty { onCancel?() } else { onSubmit?(query) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}

/// Borderless panels refuse key status unless told otherwise.
private final class NonActivatingQueryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
