import AppKit
import ApplicationServices

/// What one field should end up containing.
struct FieldAssignment {
    let field: FormField
    let value: String
}

/// Writes values into another app's form.
///
/// Two mechanisms, tried in order. Writing the value straight over the
/// Accessibility API is instant, silent, and does not touch the clipboard — but
/// in web views and Electron apps it frequently updates only the accessibility
/// layer, leaving the app's own state (and therefore what gets submitted)
/// unchanged. So every AX write is read back, and anything that did not take is
/// redone with real keystrokes, which no app can ignore.
@MainActor
enum FormFiller {

    struct Report {
        var filled: [String] = []
        var skipped: [(label: String, reason: String)] = []

        var summary: String {
            var parts = ["Filled \(filled.count) field\(filled.count == 1 ? "" : "s")"]
            if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
            return parts.joined(separator: " · ")
        }
    }

    static func fill(_ assignments: [FieldAssignment], in app: AppContext) async -> Report {
        var report = Report()
        guard !assignments.isEmpty else { return report }

        let snapshot = PasteEngine.Snapshot.capture()

        if let running = NSRunningApplication(processIdentifier: app.pid), !running.isActive {
            running.activate()
            try? await Task.sleep(for: .milliseconds(120))
        }

        for assignment in assignments {
            let label = assignment.field.label ?? "unlabelled field"

            if writeViaAccessibility(assignment) {
                report.filled.append(label)
                continue
            }

            // Fall back to keystrokes. This requires the field to actually take
            // focus first — if it does not, the keystrokes would land in
            // whatever *is* focused and overwrite it, so verify before typing.
            guard focus(assignment.field) else {
                report.skipped.append((label, "could not focus"))
                Log.write("form: could not focus \(label)")
                continue
            }
            await PasteEngine.replaceFocusedField(with: assignment.value)
            report.filled.append(label)
        }

        try? await Task.sleep(for: .milliseconds(200))
        snapshot.restore()
        Log.write("form: \(report.summary)")
        return report
    }

    /// Sets the value directly and reads it back. The read-back is the whole
    /// point: `AXUIElementSetAttributeValue` reports success in plenty of apps
    /// where nothing actually changed.
    private static func writeViaAccessibility(_ assignment: FieldAssignment) -> Bool {
        guard AXKit.set(assignment.field.element, kAXValueAttribute, assignment.value as CFTypeRef)
        else { return false }
        let readBack = AXKit.string(assignment.field.element, kAXValueAttribute)
        return readBack == assignment.value
    }

    /// Focuses a field and confirms the app agrees that it is now focused.
    private static func focus(_ field: FormField) -> Bool {
        AXKit.set(field.element, kAXFocusedAttribute, kCFBooleanTrue)

        // Ask the application which element it considers focused, rather than
        // trusting the setter's return value.
        guard let pid = pid(of: field.element) else { return false }
        let application = AXUIElementCreateApplication(pid)
        guard let focused = AXKit.element(application, kAXFocusedUIElementAttribute) else {
            return false
        }
        return AXKit.isSame(focused, field.element)
    }

    private static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }
}
