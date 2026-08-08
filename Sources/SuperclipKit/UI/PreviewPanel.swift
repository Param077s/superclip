import AppKit
import SwiftUI

/// State the preview panel renders. Text arrives token by token while the model
/// is still generating.
@MainActor
final class PreviewModel: ObservableObject {
    @Published var text: String = ""
    @Published var headline: String = ""
    @Published var subtitle: String = ""
    @Published var isStreaming: Bool = true
    @Published var errorMessage: String?
    /// What Return does, e.g. "Paste" or "Copy".
    @Published var primaryAction: String = "Paste"
    /// What Cmd+Return does, or nil when there is no second option.
    @Published var secondaryAction: String?
    /// e.g. "2 of 3", shown when there are alternatives to arrow through.
    @Published var cycleHint: String?
}

/// A panel that can take key events without activating Superclip, so the app the
/// user is pasting into stays frontmost the whole time. This is the same
/// `.nonactivatingPanel` trick Spotlight uses.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The floating preview: shows what is about to be pasted or copied, streaming
/// in live. Return takes it, Escape cancels, and Cmd+Return is the per-flow
/// escape hatch — pasting the raw clipboard, or escalating an OCR to the model.
@MainActor
final class PreviewPanel {
    private var panel: NonActivatingPanel?
    private var keyMonitor: Any?
    private let model = PreviewModel()

    var onPrimary: ((String) -> Void)?
    var onSecondary: (() -> Void)?
    var onCancel: (() -> Void)?
    /// +1 for the next alternative, -1 for the previous.
    var onCycle: ((Int) -> Void)?

    var text: String { model.text }

    func show(headline: String,
              subtitle: String,
              primaryAction: String,
              secondaryAction: String?,
              isStreaming: Bool = true) {
        model.text = ""
        model.headline = headline
        model.subtitle = subtitle
        model.isStreaming = isStreaming
        model.errorMessage = nil
        model.primaryAction = primaryAction
        model.secondaryAction = secondaryAction
        model.cycleHint = nil

        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func setText(_ text: String) {
        model.text = text
    }

    func append(_ delta: String) {
        model.text += delta
    }

    func setSubtitle(_ subtitle: String) {
        model.subtitle = subtitle
    }

    func setSecondaryAction(_ action: String?) {
        model.secondaryAction = action
    }

    func setCycleHint(_ hint: String?) {
        model.cycleHint = hint
    }

    func setPrimaryAction(_ action: String) {
        model.primaryAction = action
    }

    func beginStreaming() {
        model.text = ""
        model.isStreaming = true
        model.errorMessage = nil
    }

    func finishStreaming() {
        model.isStreaming = false
    }

    func showError(_ message: String) {
        model.isStreaming = false
        model.errorMessage = message
    }

    func hide() {
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    // MARK: - Panel construction

    private func makePanel() -> NonActivatingPanel {
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PreviewView(model: model))
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 120
        ))
    }

    // MARK: - Keys

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 36, 76: // Return, Enter
                if event.modifierFlags.contains(.command) {
                    guard self.model.secondaryAction != nil else { return nil }
                    self.onSecondary?()
                } else {
                    self.onPrimary?(self.model.text)
                }
                return nil
            case 53: // Escape
                self.onCancel?()
                return nil
            case 125: // Down
                guard self.model.cycleHint != nil else { return event }
                self.onCycle?(1)
                return nil
            case 126: // Up
                guard self.model.cycleHint != nil else { return event }
                self.onCycle?(-1)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - View

private struct PreviewView: View {
    @ObservedObject var model: PreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.35)
            content
            Divider().opacity(0.35)
            footer
        }
        .frame(width: 640, height: 300)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.secondary)
            Text(model.headline)
                .font(.system(size: 13, weight: .semibold))
            Text(model.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            if model.isStreaming {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var content: some View {
        ScrollView {
            Text(displayText)
                .font(.system(size: 12.5, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(model.errorMessage == nil ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Spacer()
                if let secondary = model.secondaryAction { key("⌘↩", secondary) }
                key("esc", "Cancel")
            } else {
                key("↩", model.primaryAction)
                if let secondary = model.secondaryAction { key("⌘↩", secondary) }
                if let cycleHint = model.cycleHint { key("↑↓", cycleHint) }
                key("esc", "Cancel")
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func key(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(symbol)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var displayText: String {
        if let errorMessage = model.errorMessage, model.text.isEmpty { return errorMessage }
        if model.text.isEmpty && model.isStreaming { return "…" }
        return model.text
    }
}
