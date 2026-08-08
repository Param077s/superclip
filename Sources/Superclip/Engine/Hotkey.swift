import AppKit
import Carbon.HIToolbox

/// Global hotkeys, registered through Carbon's `RegisterEventHotKey`.
///
/// Carbon is used rather than an `NSEvent` global monitor for one reason: it
/// *consumes* the keystroke. A global monitor only observes, so Cmd+Shift+V
/// would still reach the frontmost app and fire its own "paste and match style".
@MainActor
final class HotkeyManager {
    /// The C event handler cannot capture context, so it reaches the actions
    /// through this, keyed by hotkey id.
    private static var actions: [UInt32: () -> Void] = [:]

    private var refs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?

    private enum ID {
        static let smartPaste: UInt32 = 1
        static let captureScreen: UInt32 = 2
        static let pullPaste: UInt32 = 3
        static let fillForm: UInt32 = 4
        static let toggleStack: UInt32 = 5
        static let popStack: UInt32 = 6
        static let mergeStack: UInt32 = 7
        static let searchHistory: UInt32 = 8
    }

    /// ⇧⌘V — reshape the clipboard for wherever the cursor is.
    /// Plain ⌘V is deliberately never touched; it must stay instant.
    func registerSmartPaste(_ action: @escaping () -> Void) {
        register(id: ID.smartPaste, keyCode: UInt32(kVK_ANSI_V),
                 modifiers: UInt32(cmdKey | shiftKey), action: action)
    }

    /// ⌥⇧⌘C — grab text out of any region of the screen.
    /// ⇧⌘C is avoided because Chrome binds it to "inspect element" and Finder to
    /// "go to Computer"; Carbon would swallow both.
    func registerScreenCapture(_ action: @escaping () -> Void) {
        register(id: ID.captureScreen, keyCode: UInt32(kVK_ANSI_C),
                 modifiers: UInt32(cmdKey | shiftKey | optionKey), action: action)
    }

    /// ⌃⌘V — pull: ask what belongs in the field under the cursor.
    /// ⌥⌘V is avoided because Finder binds it to "Move Item Here".
    func registerPullPaste(_ action: @escaping () -> Void) {
        register(id: ID.pullPaste, keyCode: UInt32(kVK_ANSI_V),
                 modifiers: UInt32(cmdKey | controlKey), action: action)
    }

    /// ⌃⇧⌘V — spread one copied record across a whole form.
    /// A sibling of pull, deliberately: same key, one more modifier, one bigger
    /// blast radius. ⌥⇧⌘V is avoided because macOS binds it to Paste and Match
    /// Style in Mail, TextEdit, and Pages.
    func registerFillForm(_ action: @escaping () -> Void) {
        register(id: ID.fillForm, keyCode: UInt32(kVK_ANSI_V),
                 modifiers: UInt32(cmdKey | controlKey | shiftKey), action: action)
    }

    /// ⌃⌥C — start or stop collecting into the copy stack.
    func registerToggleStack(_ action: @escaping () -> Void) {
        register(id: ID.toggleStack, keyCode: UInt32(kVK_ANSI_C),
                 modifiers: UInt32(controlKey | optionKey), action: action)
    }

    /// ⌃⌥V — paste the next item off the stack.
    ///
    /// Two modifiers rather than three, and adjacent to each other, because this
    /// is the one binding meant to be pressed repeatedly — once per form field.
    func registerPopStack(_ action: @escaping () -> Void) {
        register(id: ID.popStack, keyCode: UInt32(kVK_ANSI_V),
                 modifiers: UInt32(controlKey | optionKey), action: action)
    }

    /// ⌃⌥⇧V — paste everything left on the stack as one merged block.
    func registerMergeStack(_ action: @escaping () -> Void) {
        register(id: ID.mergeStack, keyCode: UInt32(kVK_ANSI_V),
                 modifiers: UInt32(controlKey | optionKey | shiftKey), action: action)
    }

    /// ⌃⌥F — ask for something you copied instead of scrolling for it.
    /// F rather than another V because the action begins as a search; the paste
    /// is what happens after you have found the thing.
    func registerSearchHistory(_ action: @escaping () -> Void) {
        register(id: ID.searchHistory, keyCode: UInt32(kVK_ANSI_F),
                 modifiers: UInt32(controlKey | optionKey), action: action)
    }

    private func register(id: UInt32, keyCode: UInt32, modifiers: UInt32,
                          action: @escaping () -> Void) {
        HotkeyManager.actions[id] = action
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x53434C50), id: id) // 'SCLP'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
        Log.write("hotkey: register id=\(id) status=\(status)")
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            MainActor.assumeIsolated { HotkeyManager.actions[id]?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    func unregisterAll() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        HotkeyManager.actions.removeAll()
    }
}
