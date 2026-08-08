import AppKit
import ApplicationServices

/// What the field under the cursor is asking for.
///
/// This is the half of "paste without copy" that makes it possible at all: the
/// Accessibility API already knows a field's placeholder, label, and role, which
/// is usually enough to say "this wants a shipping address" without the user
/// telling us anything.
struct FieldIntent {
    let app: AppContext
    let role: String?
    let subrole: String?
    /// Best available human label: placeholder, then title, then description.
    let label: String?
    /// What is already typed, which narrows intent — "param@" in an empty-ish
    /// field says email far more clearly than any placeholder.
    let existingValue: String?

    /// Password fields. Superclip never offers to fill these; credentials belong
    /// in a password manager, and a clipboard tool guessing at them is exactly
    /// the behavior that makes a tool untrustworthy.
    var isSecure: Bool { subrole == "AXSecureTextField" }

    /// Whether the focused element is somewhere text can actually be typed.
    var isTextEntry: Bool {
        guard let role else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }

    /// A short name for the panel header.
    var shortLabel: String {
        if let label, !label.isEmpty { return label }
        if let role { return role.replacingOccurrences(of: "AX", with: "") }
        return "this field"
    }

    var describedForModel: String {
        var parts: [String] = ["Application: \(app.name)"]
        if let title = app.windowTitle, !title.isEmpty {
            parts.append("Window: \(title)")
        }
        if let role { parts.append("Field type: \(role)") }
        if let label, !label.isEmpty { parts.append("Field label or placeholder: \(label)") }
        if let existingValue, !existingValue.isEmpty {
            parts.append("Already typed in the field: \(existingValue)")
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Reading it out of the app

    static func focused(in app: AppContext) -> FieldIntent? {
        guard Permissions.hasAccessibility else { return nil }

        let application = AXUIElementCreateApplication(app.pid)
        guard let element = AXKit.element(application, kAXFocusedUIElementAttribute) else {
            return FieldIntent(app: app, role: nil, subrole: nil, label: nil, existingValue: nil)
        }

        let value = AXKit.string(element, kAXValueAttribute)
        return FieldIntent(
            app: app,
            role: AXKit.string(element, kAXRoleAttribute),
            subrole: AXKit.string(element, kAXSubroleAttribute),
            label: AXKit.label(of: element),
            existingValue: value.map { String($0.prefix(200)) }
        )
    }
}
