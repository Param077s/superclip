import AppKit
import CoreGraphics

/// Puts text into the app the user was in when the hotkey fired.
///
/// The mechanism is pasteboard + synthesized Cmd+V rather than writing through
/// the Accessibility API, because Cmd+V works in every app including ones that
/// expose nothing useful over AX. The original clipboard is snapshotted and put
/// back afterwards, so using Superclip never costs the user what they copied.
@MainActor
enum PasteEngine {

    /// Everything on the pasteboard, so it can be put back byte-for-byte.
    struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        static func capture() -> Snapshot {
            let items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
                var stored: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { stored[type] = data }
                }
                return stored
            }
            return Snapshot(items: items)
        }

        func restore() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let restored = items.map { stored -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in stored { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
    }

    /// Writes `text` to the pasteboard, brings `target` back to the front, sends
    /// Cmd+V, then restores whatever was on the pasteboard before.
    static func paste(_ text: String, into target: AppContext) async {
        let snapshot = Snapshot.capture()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // The preview panel is non-activating, so the target app should still be
        // frontmost — but re-activating makes this robust if anything stole focus.
        if let app = NSRunningApplication(processIdentifier: target.pid), !app.isActive {
            app.activate()
            try? await Task.sleep(for: .milliseconds(90))
        }

        sendCommandV()

        // Give the target app time to actually read the pasteboard before we
        // put the old contents back. Apps read it asynchronously; too short a
        // delay here pastes the user's previous clipboard instead.
        try? await Task.sleep(for: .milliseconds(400))
        snapshot.restore()
        Log.write("paste: delivered \(text.count) chars to \(target.name)")
    }

    /// Replaces whatever is in the currently focused field with `text`, using
    /// real keystrokes. Slower than writing the value over the Accessibility
    /// API, but it works in web views and Electron apps, where an AX write
    /// often updates the accessibility layer without the app's own state ever
    /// hearing about it.
    ///
    /// The caller owns the pasteboard snapshot — this is meant to run in a loop.
    static func replaceFocusedField(with text: String) async {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        sendKey(0x00, flags: .maskCommand) // Cmd+A — select the field's contents
        try? await Task.sleep(for: .milliseconds(25))
        sendKey(0x09, flags: .maskCommand) // Cmd+V
        try? await Task.sleep(for: .milliseconds(70))
    }

    private static func sendCommandV() {
        sendKey(0x09, flags: .maskCommand)
    }

    static func sendKey(_ key: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // Stop the user's physically-held modifiers from mixing into our events.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
