import Foundation

/// A deliberate, ordered collection of clips.
///
/// Distinct from `ClipboardMonitor`'s history, which is passive and newest-first.
/// The stack is something the user turns on, fills on purpose, and drains in the
/// order they filled it — first copied, first pasted — because the thing people
/// actually do with it is walk down a form.
///
/// Draining involves no model call and no network. That is the feature: the user
/// already decided what these values are, so a press should paste instantly and
/// cost nothing.
@MainActor
final class CopyStack {
    private(set) var items: [String] = []
    private(set) var isCollecting = false

    /// Fired whenever the count or mode changes, so the menu bar can reflect it.
    var onChange: (() -> Void)?

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    /// Starts a fresh collection. The current clipboard is seeded as item one,
    /// since in practice the user copies the first thing and *then* realizes
    /// they want a stack.
    func startCollecting(seed: String?) {
        items.removeAll()
        isCollecting = true
        if let seed, !seed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(seed)
        }
        Log.write("stack: collecting, seeded=\(items.count)")
        onChange?()
    }

    func stopCollecting() {
        isCollecting = false
        Log.write("stack: stopped collecting, \(items.count) item(s)")
        onChange?()
    }

    /// Appends a clip. Ignored unless collecting is on — the stack never fills
    /// itself behind the user's back.
    func append(_ text: String) {
        guard isCollecting else { return }
        items.append(text)
        Log.write("stack: appended, \(items.count) item(s)")
        onChange?()
    }

    /// Removes and returns the oldest item.
    func popFirst() -> String? {
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        onChange?()
        return item
    }

    /// Removes and returns everything, for a single merged paste.
    func drainAll() -> [String] {
        let all = items
        items.removeAll()
        onChange?()
        return all
    }

    func clear() {
        items.removeAll()
        isCollecting = false
        Log.write("stack: cleared")
        onChange?()
    }
}
