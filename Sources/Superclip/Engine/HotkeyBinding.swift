import AppKit
import Carbon.HIToolbox

/// A key combination, stored in the Carbon vocabulary that `RegisterEventHotKey`
/// speaks so nothing has to be translated at registration time.
struct KeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var carbonModifiers: UInt32

    /// At least one of Command, Control, or Option is required. Shift alone does
    /// not count: a global hotkey of ⇧A would swallow every capital A the user
    /// types, in every application.
    var isUsable: Bool {
        let required = UInt32(cmdKey | controlKey | optionKey)
        return carbonModifiers & required != 0
    }

    /// Rendered in the order macOS itself uses: ⌃⌥⇧⌘.
    var display: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + KeyNames.name(for: keyCode)
    }

    init(keyCode: UInt16, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Builds a binding from a captured `NSEvent`.
    init(event: NSEvent) {
        keyCode = event.keyCode
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        carbonModifiers = modifiers
    }
}

/// Everything Superclip can be asked to do from the keyboard.
///
/// The raw values are persistence keys and must not change; the titles are what
/// the settings window shows.
enum HotkeyAction: String, CaseIterable {
    case smartPaste
    case captureScreen
    case pullPaste
    case fillForm
    case toggleStack
    case popStack
    case mergeStack
    case searchHistory
    case browseHistory

    var title: String {
        switch self {
        case .smartPaste:    return "Paste smart"
        case .captureScreen: return "Copy from screen"
        case .pullPaste:     return "Pull into this field"
        case .fillForm:      return "Fill this form"
        case .toggleStack:   return "Start / stop collecting"
        case .popStack:      return "Paste next from stack"
        case .mergeStack:    return "Paste stack merged"
        case .searchHistory: return "Search what you've copied"
        case .browseHistory: return "Browse clipboard history"
        }
    }

    /// One line on why this binding and not a more obvious one, shown in the
    /// settings window so a user changing it knows what they may collide with.
    var note: String? {
        switch self {
        case .smartPaste:    return "⌘V is never taken — it must stay instant"
        case .captureScreen: return "⇧⌘C avoided: Chrome inspect, Finder go-to-Computer"
        case .fillForm:      return "⌥⇧⌘V avoided: system Paste and Match Style"
        case .popStack:      return "Two modifiers — meant to be pressed repeatedly"
        default:             return nil
        }
    }

    var defaultBinding: KeyBinding {
        switch self {
        case .smartPaste:
            return KeyBinding(keyCode: UInt16(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | shiftKey))
        case .captureScreen:
            return KeyBinding(keyCode: UInt16(kVK_ANSI_C), carbonModifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .pullPaste:
            return KeyBinding(keyCode: UInt16(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | controlKey))
        case .fillForm:
            return KeyBinding(keyCode: UInt16(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | controlKey | shiftKey))
        case .toggleStack:
            return KeyBinding(keyCode: UInt16(kVK_ANSI_C), carbonModifiers: UInt32(controlKey | optionKey))
        case .popStack:
            return KeyBinding(keyCode: UInt16(kVK_ANSI_V), carbonModifiers: UInt32(controlKey | optionKey))
        case .mergeStack:
            return KeyBinding(keyCode: UInt16(kVK_ANSI_V), carbonModifiers: UInt32(controlKey | optionKey | shiftKey))
        case .searchHistory:
            return KeyBinding(keyCode: UInt16(kVK_ANSI_F), carbonModifiers: UInt32(controlKey | optionKey))
        case .browseHistory:
            return KeyBinding(keyCode: UInt16(kVK_ANSI_H), carbonModifiers: UInt32(controlKey | optionKey))
        }
    }

    /// Stable identifier for `RegisterEventHotKey`.
    var hotkeyID: UInt32 {
        UInt32((HotkeyAction.allCases.firstIndex(of: self) ?? 0) + 1)
    }
}

/// Persisted bindings, defaulting to the built-in ones.
enum Bindings {
    private static func key(_ action: HotkeyAction) -> String { "binding.\(action.rawValue)" }

    static func binding(for action: HotkeyAction) -> KeyBinding {
        guard let data = UserDefaults.standard.data(forKey: key(action)),
              let stored = try? JSONDecoder().decode(KeyBinding.self, from: data) else {
            return action.defaultBinding
        }
        return stored
    }

    static func set(_ binding: KeyBinding, for action: HotkeyAction) {
        guard let data = try? JSONEncoder().encode(binding) else { return }
        UserDefaults.standard.set(data, forKey: key(action))
    }

    static func reset(_ action: HotkeyAction) {
        UserDefaults.standard.removeObject(forKey: key(action))
    }

    static func resetAll() {
        for action in HotkeyAction.allCases { reset(action) }
    }

    static var isCustomized: Bool {
        HotkeyAction.allCases.contains { binding(for: $0) != $0.defaultBinding }
    }

    /// Any other action already using this combination. Registering two hotkeys
    /// with the same combination silently gives one of them to whichever
    /// registered first, so this is caught before it reaches Carbon.
    static func conflict(for binding: KeyBinding, excluding action: HotkeyAction) -> HotkeyAction? {
        HotkeyAction.allCases.first { $0 != action && Self.binding(for: $0) == binding }
    }
}

/// Turns a virtual key code into something printable.
enum KeyNames {
    /// Keys whose names are not characters, plus the ones that would render as
    /// invisible or ambiguous glyphs.
    private static let special: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_ANSI_KeypadEnter: "⌤",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12"
    ]

    static func name(for keyCode: UInt16) -> String {
        if let name = special[Int(keyCode)] { return name }
        if let translated = translate(keyCode), !translated.isEmpty {
            return translated.uppercased()
        }
        return "Key \(keyCode)"
    }

    /// Asks the current keyboard layout what this key produces, so a binding
    /// reads correctly on layouts where the physical key is not the US one.
    private static func translate(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return nil }

            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, characters.count, &length, &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}
