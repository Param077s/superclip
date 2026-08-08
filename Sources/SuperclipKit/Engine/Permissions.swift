import AppKit
import ApplicationServices
import CoreGraphics

/// Superclip needs two permissions.
///
/// **Accessibility** reads the focused window's title (to know where a paste is
/// going) and synthesizes the Cmd+V keystroke that performs the paste.
///
/// **Screen Recording** is required to grab a region of the screen for the
/// copy-anything feature. macOS grants no partial version of this: reading a
/// 200×80 box around an error message needs the same permission as recording
/// the whole display.
enum Permissions {

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    static func openAccessibilitySettings() { open("Privacy_Accessibility") }
    static func openScreenRecordingSettings() { open("Privacy_ScreenCapture") }

    private static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
