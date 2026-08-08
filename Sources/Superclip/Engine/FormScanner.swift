import AppKit
import ApplicationServices

/// One writable field found in the focused window.
struct FormField {
    let element: AXUIElement
    let role: String
    let label: String?
    let value: String
    let frame: CGRect?

    var isEmpty: Bool { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// What the model sees. Deliberately no element identity — just the human
    /// signals a person would use to work out what a field is for.
    func describedForModel(index: Int) -> String {
        var parts = ["[\(index)]"]
        parts.append(label.map { "label: \($0)" } ?? "label: (none)")
        parts.append("type: \(role.replacingOccurrences(of: "AX", with: ""))")
        if !isEmpty { parts.append("currently contains: \(value.prefix(80))") }
        return parts.joined(separator: ", ")
    }
}

/// Walks the focused window's Accessibility tree looking for fields that can be
/// written to. This is what makes "integration without integration" possible:
/// every app on macOS publishes its form controls here, whether or not it has an
/// API, and whether or not its vendor has ever heard of us.
@MainActor
enum FormScanner {

    private static let entryRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"
    ]

    /// Bounds on the walk. Some apps — Electron especially — publish enormous
    /// trees, and an unbounded search would hang the hotkey.
    private static let maxNodes = 1500
    private static let maxDepth = 18

    static func scan(app: AppContext) -> [FormField] {
        guard Permissions.hasAccessibility else { return [] }

        let application = AXUIElementCreateApplication(app.pid)
        guard let window = AXKit.element(application, kAXFocusedWindowAttribute)
                ?? AXKit.element(application, kAXMainWindowAttribute) else { return [] }

        var found: [FormField] = []
        var visited = 0

        // Breadth-first, so that if the node budget runs out it is the deepest
        // and least likely-to-matter parts of the tree that get dropped.
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        while !queue.isEmpty, visited < maxNodes {
            let (element, depth) = queue.removeFirst()
            visited += 1

            if let field = field(from: element) { found.append(field) }
            if depth < maxDepth {
                for child in AXKit.children(element) {
                    queue.append((child, depth + 1))
                }
            }
        }

        Log.write("form: scanned \(visited) nodes, \(found.count) writable field(s)")
        return inReadingOrder(found)
    }

    private static func field(from element: AXUIElement) -> FormField? {
        guard let role = AXKit.string(element, kAXRoleAttribute),
              entryRoles.contains(role) else { return nil }

        // Password fields are excluded at the source, so they cannot reach the
        // model or the filler even by accident.
        if AXKit.string(element, kAXSubroleAttribute) == "AXSecureTextField" { return nil }

        // A field we cannot write to is noise in the prompt and a guaranteed
        // failure at fill time.
        guard AXKit.isSettable(element, kAXValueAttribute) else { return nil }
        if AXKit.bool(element, kAXEnabledAttribute) == false { return nil }

        return FormField(
            element: element,
            role: role,
            label: AXKit.label(of: element),
            value: AXKit.string(element, kAXValueAttribute) ?? "",
            frame: AXKit.frame(element)
        )
    }

    /// Top to bottom, then left to right — the order a person reads the form in,
    /// which is also the order that makes the review panel legible.
    private static func inReadingOrder(_ fields: [FormField]) -> [FormField] {
        ReadingOrder.sortedIndices(frames: fields.map(\.frame)).map { fields[$0] }
    }
}
