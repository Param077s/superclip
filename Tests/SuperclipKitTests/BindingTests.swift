import AppKit
import Carbon.HIToolbox
import Testing
@testable import SuperclipKit

/// Hotkey bindings.
///
/// Two of these guard failures that are completely silent at runtime: two
/// actions sharing a combination gives it to whichever registered first and
/// leaves the other dead, and a binding with no modifier would swallow ordinary
/// typing in every application.
@Suite("Hotkey bindings")
struct BindingTests {

    @Test("Every action has a distinct default")
    func defaultsDistinct() {
        let signatures = HotkeyAction.allCases.map {
            "\($0.defaultBinding.keyCode)-\($0.defaultBinding.carbonModifiers)"
        }
        #expect(Set(signatures).count == HotkeyAction.allCases.count)
    }

    @Test("Nothing claims plain ⌘V")
    func nothingStealsPlainPaste() {
        let stealsPaste = HotkeyAction.allCases.contains {
            $0.defaultBinding.keyCode == UInt16(kVK_ANSI_V)
                && $0.defaultBinding.carbonModifiers == UInt32(cmdKey)
        }
        #expect(!stealsPaste)
    }

    @Test("Every default carries a real modifier")
    func defaultsUsable() {
        #expect(HotkeyAction.allCases.allSatisfy { $0.defaultBinding.isUsable })
    }

    @Test("Shift alone is not enough to be a global shortcut")
    func shiftAloneRejected() {
        #expect(!KeyBinding(keyCode: 0, carbonModifiers: UInt32(shiftKey)).isUsable)
        #expect(!KeyBinding(keyCode: 0, carbonModifiers: 0).isUsable)
        #expect(KeyBinding(keyCode: 0, carbonModifiers: UInt32(cmdKey)).isUsable)
        #expect(KeyBinding(keyCode: 0, carbonModifiers: UInt32(controlKey | optionKey)).isUsable)
    }

    @Test("Renders in macOS's ⌃⌥⇧⌘ order")
    func displayOrder() {
        #expect(HotkeyAction.smartPaste.defaultBinding.display == "⇧⌘V")
        #expect(HotkeyAction.captureScreen.defaultBinding.display == "⌥⇧⌘C")
        #expect(HotkeyAction.mergeStack.defaultBinding.display == "⌃⌥⇧V")
        #expect(HotkeyAction.searchHistory.defaultBinding.display == "⌃⌥F")
    }

    @Test("Keys with no printable character are named")
    func specialKeyNames() {
        #expect(KeyNames.name(for: UInt16(kVK_Space)) == "Space")
        #expect(KeyNames.name(for: UInt16(kVK_LeftArrow)) == "←")
        #expect(KeyNames.name(for: UInt16(kVK_Return)) == "↩")
        #expect(KeyNames.name(for: UInt16(kVK_Escape)) == "⎋")
    }

    @Test("Identifiers are unique and non-zero")
    func identifiers() {
        let ids = HotkeyAction.allCases.map(\.hotkeyID)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0 > 0 })
    }

    @Test("Raw values are unique — they are persistence keys")
    func rawValuesUnique() {
        #expect(Set(HotkeyAction.allCases.map(\.rawValue)).count == HotkeyAction.allCases.count)
    }

    @Test("A custom binding persists and resets")
    func persistence() {
        defer { Bindings.reset(.smartPaste) }

        let custom = KeyBinding(keyCode: UInt16(kVK_ANSI_P),
                                carbonModifiers: UInt32(cmdKey | optionKey))
        Bindings.set(custom, for: .smartPaste)
        #expect(Bindings.binding(for: .smartPaste) == custom)
        #expect(Bindings.isCustomized)

        Bindings.reset(.smartPaste)
        #expect(Bindings.binding(for: .smartPaste) == HotkeyAction.smartPaste.defaultBinding)
        #expect(!Bindings.isCustomized)
    }

    @Test("A combination already in use is reported, and an action never conflicts with itself")
    func conflicts() {
        #expect(Bindings.conflict(for: HotkeyAction.popStack.defaultBinding,
                                  excluding: .smartPaste) == .popStack)
        #expect(Bindings.conflict(for: HotkeyAction.popStack.defaultBinding,
                                  excluding: .popStack) == nil)

        let unused = KeyBinding(keyCode: UInt16(kVK_ANSI_Q),
                                carbonModifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey))
        #expect(Bindings.conflict(for: unused, excluding: .smartPaste) == nil)
    }

    @Test("A binding is built correctly from a key event")
    func fromEvent() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
            context: nil, characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_V)
        ))
        #expect(KeyBinding(event: event) == HotkeyAction.smartPaste.defaultBinding)
    }
}
