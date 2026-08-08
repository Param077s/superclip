import AppKit
import Carbon.HIToolbox

/// Lets the user rebind every action.
///
/// A real window rather than one of the floating panels: this is somewhere you
/// deliberately go, it should appear in the window list, and unlike the panels
/// it *wants* to activate the app so it can receive keystrokes normally.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var recorders: [HotkeyAction: RecorderButton] = [:]
    private var warnings: [HotkeyAction: NSTextField] = [:]
    private var resetAllButton: NSButton!

    /// Fired after a binding changes, so the manager can re-register.
    var onChange: (() -> Void)?
    /// Carbon consumes registered hotkeys before any local monitor sees them, so
    /// they have to be suspended while a new combination is being captured —
    /// otherwise pressing ⌃⌥V during recording fires the paste instead of being
    /// recorded.
    var onRecordingBegan: (() -> Void)?
    var onRecordingEnded: (() -> Void)?
    /// Supplies the live registration result, so combinations the system refused
    /// can be shown as unavailable rather than silently doing nothing.
    var registrationStatus: (() -> [HotkeyAction: OSStatus])?

    func show() {
        let window = self.window ?? build()
        self.window = window
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    // MARK: - Construction

    private func build() -> NSWindow {
        let width: CGFloat = 580
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Superclip Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 560))

        let header = NSTextField(labelWithString: "Click a shortcut to change it. Needs ⌘, ⌃, or ⌥ — a binding without one would swallow ordinary typing everywhere.")
        header.frame = NSRect(x: 20, y: 16, width: width - 40, height: 32)
        header.font = .systemFont(ofSize: 11)
        header.textColor = .secondaryLabelColor
        header.maximumNumberOfLines = 2
        content.addSubview(header)

        // Rows.
        let rowHeight: CGFloat = 52
        let list = FlippedView(frame: NSRect(x: 0, y: 0, width: width - 24,
                                             height: rowHeight * CGFloat(HotkeyAction.allCases.count)))
        for (index, action) in HotkeyAction.allCases.enumerated() {
            list.addSubview(row(for: action, y: CGFloat(index) * rowHeight, width: width - 24))
        }

        let scroll = NSScrollView(frame: NSRect(x: 8, y: 56, width: width - 16, height: 420))
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        content.addSubview(scroll)

        let divider = NSView(frame: NSRect(x: 0, y: 484, width: width, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        content.addSubview(divider)

        resetAllButton = NSButton(title: "Reset All to Defaults",
                                  target: self, action: #selector(resetAll))
        resetAllButton.bezelStyle = .rounded
        resetAllButton.frame = NSRect(x: 20, y: 500, width: 180, height: 30)
        content.addSubview(resetAllButton)

        let note = NSTextField(labelWithString: "⌘V is deliberately not bindable — it must stay instant.")
        note.frame = NSRect(x: 214, y: 506, width: width - 234, height: 18)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        content.addSubview(note)

        window.contentView = content
        return window
    }

    private func row(for action: HotkeyAction, y: CGFloat, width: CGFloat) -> NSView {
        let container = FlippedView(frame: NSRect(x: 0, y: y, width: width, height: 52))

        let title = NSTextField(labelWithString: action.title)
        title.frame = NSRect(x: 16, y: 8, width: 300, height: 18)
        title.font = .systemFont(ofSize: 13)
        container.addSubview(title)

        let warning = NSTextField(labelWithString: action.note ?? "")
        warning.frame = NSRect(x: 16, y: 27, width: 320, height: 15)
        warning.font = .systemFont(ofSize: 10.5)
        warning.textColor = .tertiaryLabelColor
        warning.lineBreakMode = .byTruncatingTail
        container.addSubview(warning)
        warnings[action] = warning

        let recorder = RecorderButton(for: action)
        recorder.frame = NSRect(x: width - 210, y: 12, width: 130, height: 26)
        recorder.onCapture = { [weak self] binding in self?.apply(binding, to: action) }
        recorder.onBegin = { [weak self] in self?.onRecordingBegan?() }
        recorder.onEnd = { [weak self] in self?.onRecordingEnded?() }
        container.addSubview(recorder)
        recorders[action] = recorder

        let reset = NSButton(title: "Reset", target: self, action: #selector(resetOne(_:)))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.tag = Int(action.hotkeyID)
        reset.frame = NSRect(x: width - 72, y: 13, width: 56, height: 24)
        container.addSubview(reset)

        return container
    }

    // MARK: - Changes

    private func apply(_ binding: KeyBinding, to action: HotkeyAction) {
        guard binding.isUsable else {
            warn(action, "Needs ⌘, ⌃, or ⌥.")
            refresh()
            return
        }
        if let clash = Bindings.conflict(for: binding, excluding: action) {
            warn(action, "Already used by “\(clash.title)”.")
            refresh()
            return
        }
        Bindings.set(binding, for: action)
        onChange?()
        refresh()
    }

    @objc private func resetOne(_ sender: NSButton) {
        guard let action = HotkeyAction.allCases.first(where: { Int($0.hotkeyID) == sender.tag })
        else { return }
        Bindings.reset(action)
        onChange?()
        refresh()
    }

    @objc private func resetAll() {
        Bindings.resetAll()
        onChange?()
        refresh()
    }

    private func warn(_ action: HotkeyAction, _ message: String) {
        warnings[action]?.stringValue = message
        warnings[action]?.textColor = .systemOrange
        NSSound.beep()
    }

    /// Repaints every row from current state. Called after any change, because
    /// resolving one conflict can free a combination for a different action.
    func refresh() {
        let status = registrationStatus?() ?? [:]
        for action in HotkeyAction.allCases {
            let binding = Bindings.binding(for: action)
            recorders[action]?.show(binding)

            let warning = warnings[action]
            if let result = status[action], result != noErr {
                warning?.stringValue = "Unavailable — another app or macOS has this combination."
                warning?.textColor = .systemOrange
            } else {
                warning?.stringValue = action.note ?? ""
                warning?.textColor = .tertiaryLabelColor
            }
        }
        resetAllButton.isEnabled = Bindings.isCustomized
    }

    func windowWillClose(_ notification: Notification) {
        // A recorder left mid-capture would keep the global hotkeys suspended.
        for recorder in recorders.values where recorder.isRecording { recorder.cancel() }
    }
}

// MARK: - Recorder

/// A button that captures the next key combination pressed.
private final class RecorderButton: NSButton {
    /// Not named `action` — `NSControl` already owns that name for its selector.
    private let hotkeyAction: HotkeyAction
    private var monitor: Any?
    private(set) var isRecording = false

    var onCapture: ((KeyBinding) -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    init(for hotkeyAction: HotkeyAction) {
        self.hotkeyAction = hotkeyAction
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .systemFont(ofSize: 13, weight: .medium)
        target = self
        action = #selector(toggle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ binding: KeyBinding) {
        guard !isRecording else { return }
        title = binding.display
    }

    @objc private func toggle() {
        isRecording ? cancel() : begin()
    }

    private func begin() {
        isRecording = true
        title = "Press keys…"
        onBegin?()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.cancel()
                return nil
            }
            let binding = KeyBinding(event: event)
            self.finish()
            self.onCapture?(binding)
            return nil
        }
    }

    func cancel() {
        finish()
    }

    private func finish() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onEnd?()
    }
}

/// Top-down coordinates, so a vertical list can be laid out by index without
/// every frame being computed from the bottom of the container.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
