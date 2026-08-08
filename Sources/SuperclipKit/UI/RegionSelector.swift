import AppKit

/// The drag-a-box overlay. One transparent window per screen, dimmed, with the
/// selection punched out of the dim so the user can see exactly what they are
/// about to grab.
@MainActor
final class RegionSelector {
    private var windows: [OverlayWindow] = []
    private var onSelect: ((NSRect, NSScreen) -> Void)?
    private var onCancel: (() -> Void)?

    var isActive: Bool { !windows.isEmpty }

    func begin(onSelect: @escaping (NSRect, NSScreen) -> Void,
               onCancel: @escaping () -> Void) {
        guard !isActive else { return }
        self.onSelect = onSelect
        self.onCancel = onCancel

        for screen in NSScreen.screens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onFinish = { [weak self] rect in
                guard let self else { return }
                if let rect, rect.width >= 4, rect.height >= 4 {
                    let global = window.convertToScreen(rect)
                    self.end()
                    self.onSelect?(global, screen)
                } else {
                    self.end()
                    self.onCancel?()
                }
            }
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }

        // Superclip is an accessory app, so it must be activated for the overlay
        // to receive key events (Escape) as well as clicks.
        NSApp.activate(ignoringOtherApps: true)
        if let first = windows.first {
            first.makeKeyAndOrderFront(nil)
            first.makeFirstResponder(first.contentView)
        }
    }

    /// Tears the overlay down. Returns once the windows are off screen — the
    /// caller still needs to wait a frame before capturing, so the compositor
    /// has actually removed them from what the display shows.
    func end() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }
}

// MARK: - Windows and views

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    /// Called with the selection in view coordinates, or nil if cancelled.
    var onFinish: ((NSRect?) -> Void)?

    private var anchor: NSPoint?
    private var cursor: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    private var selection: NSRect? {
        guard let anchor, let cursor else { return nil }
        return NSRect(x: min(anchor.x, cursor.x),
                      y: min(anchor.y, cursor.y),
                      width: abs(cursor.x - anchor.x),
                      height: abs(cursor.y - anchor.y))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        cursor = anchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        onFinish?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } // Escape
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.30).setFill()
        dirtyRect.fill()

        guard let selection, selection.width > 0, selection.height > 0 else {
            drawHint()
            return
        }

        // Punch the selection out of the dim so the content underneath is
        // visible at full brightness while dragging.
        NSColor.clear.setFill()
        selection.fill(using: .copy)

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 1.5
        border.stroke()

        drawDimensions(for: selection)
    }

    private func drawHint() {
        let text = "Drag to copy text from the screen  ·  esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY),
                  withAttributes: attributes)
    }

    private func drawDimensions(for rect: NSRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let padding: CGFloat = 5
        // Below the selection, or above it when there is no room below.
        let belowY = rect.minY - size.height - padding * 2 - 4
        let originY = belowY > 0 ? belowY : rect.maxY + 4
        let box = NSRect(x: rect.minX, y: originY,
                         width: size.width + padding * 2,
                         height: size.height + padding)

        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: box.minX + padding, y: box.minY + padding / 2),
                  withAttributes: attributes)
    }
}
