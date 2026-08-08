import AppKit
import Carbon.HIToolbox

/// Global hotkeys, registered through Carbon's `RegisterEventHotKey`.
///
/// Carbon is used rather than an `NSEvent` global monitor for one reason: it
/// *consumes* the keystroke. A global monitor only observes, so ⇧⌘V would still
/// reach the frontmost app and fire its own "paste and match style".
@MainActor
final class HotkeyManager {
    /// The C event handler cannot capture context, so it reaches the action
    /// through this, keyed by hotkey id.
    private static var actions: [UInt32: HotkeyAction] = [:]
    private static var dispatch: ((HotkeyAction) -> Void)?

    private var refs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?

    /// Whether each action's binding actually took. A non-zero status means the
    /// combination is spoken for — usually by macOS or another running app — and
    /// the settings window shows it rather than leaving a dead key.
    private(set) var registrationStatus: [HotkeyAction: OSStatus] = [:]

    /// Registers every action's current binding, replacing anything already
    /// registered. Called at launch and again whenever a binding changes.
    func registerAll(_ handler: @escaping (HotkeyAction) -> Void) {
        unregisterAll()
        HotkeyManager.dispatch = handler
        installHandlerIfNeeded()

        for action in HotkeyAction.allCases {
            let binding = Bindings.binding(for: action)
            guard binding.isUsable else {
                registrationStatus[action] = OSStatus(paramErr)
                continue
            }

            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x53434C50), id: action.hotkeyID) // 'SCLP'
            let status = RegisterEventHotKey(UInt32(binding.keyCode),
                                             binding.carbonModifiers,
                                             id,
                                             GetApplicationEventTarget(), 0, &ref)
            registrationStatus[action] = status
            if status == noErr {
                HotkeyManager.actions[action.hotkeyID] = action
                refs.append(ref)
            }
        }

        let failed = registrationStatus.filter { $0.value != noErr }
        Log.write("hotkeys: registered \(registrationStatus.count - failed.count)/\(registrationStatus.count)"
                  + (failed.isEmpty ? "" : ", unavailable: \(failed.keys.map(\.rawValue).sorted().joined(separator: ", "))"))
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
            MainActor.assumeIsolated {
                guard let action = HotkeyManager.actions[id] else { return }
                HotkeyManager.dispatch?(action)
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    func unregisterAll() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        HotkeyManager.actions.removeAll()
        registrationStatus.removeAll()
    }
}
