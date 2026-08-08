import AppKit
import ApplicationServices

/// Who an app is, from the transform's point of view: the app itself plus the
/// title of its focused window, which is often the only signal that tells us a
/// browser tab is Google Sheets or an editor is open on a `.py` file.
struct AppContext {
    let name: String
    let bundleID: String
    let pid: pid_t
    let windowTitle: String?

    /// A one-line description for the model prompt.
    var describedForModel: String {
        var text = "\(name) (\(bundleID))"
        if let windowTitle, !windowTitle.isEmpty {
            text += ", focused window titled \"\(windowTitle)\""
        }
        return text
    }

    static func frontmost() -> AppContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppContext(
            name: app.localizedName ?? "Unknown",
            bundleID: app.bundleIdentifier ?? "unknown",
            pid: app.processIdentifier,
            windowTitle: focusedWindowTitle(pid: app.processIdentifier)
        )
    }

    /// Reads the focused window's title over the Accessibility API. Returns nil
    /// when AX is not yet granted or the app exposes no focused window.
    private static func focusedWindowTitle(pid: pid_t) -> String? {
        guard Permissions.hasAccessibility else { return nil }
        let element = AXUIElementCreateApplication(pid)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef else { return nil }

        var titleRef: CFTypeRef?
        let window = windowRef as! AXUIElement
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String, !title.isEmpty else { return nil }
        return title
    }
}
