import AppKit

/// Watches the general pasteboard so every clip carries provenance — which app
/// it came from — and keeps a short recent history for the pull-paste flow.
///
/// The pasteboard has no change notification, so this polls `changeCount`, which
/// is cheap (an integer read, no data copy).
///
/// The source app is whatever was frontmost when the change was noticed. At a
/// 0.25s interval that is correct unless the user copies and switches apps
/// inside the same tick, which is fast enough to be rare and harmless when wrong.
@MainActor
final class ClipboardMonitor {
    struct Entry {
        let text: String
        let source: AppContext?
        let capturedAt: Date

        var sourceName: String { source?.name ?? "unknown app" }
    }

    /// History is deliberately in memory only — it dies with the process and is
    /// never written to disk. Persisting clipboard history is a genuinely
    /// dangerous thing to do casually, and it should not happen before the
    /// safety layer that governs what is allowed to be retained exists.
    /// Sized for search rather than for the pull flow, which only ever reads the
    /// top of the list. Two hundred strings is nothing in memory, and a search
    /// over the last forty clips would rarely have the thing you are looking for.
    private static let capacity = 200

    private var timer: Timer?
    private var lastChangeCount: Int
    /// A change we have seen but not yet been able to read content for.
    private var pendingChangeCount: Int?
    private var pendingAttempts = 0
    /// How many ticks (0.25s each) to wait for a writer to finish before
    /// accepting that a clip simply is not text.
    private static let maxPendingAttempts = 3

    /// The app that produced the current clipboard contents.
    private(set) var sourceApp: AppContext?
    /// Recent clips, newest first.
    private(set) var history: [Entry] = []

    /// Called for every clip that passes the retention filter, so the copy stack
    /// can collect without duplicating the polling or the safety checks.
    var onRetainedClip: ((String) -> Void)?

    /// Set while Superclip is itself writing to the pasteboard. Without this, a
    /// paste performed during a stack drain comes straight back as a new user
    /// clip — and while collecting, the stack would refill itself from its own
    /// output.
    var isSuppressed = false

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The plain-text contents of the clipboard right now.
    var text: String? {
        NSPasteboard.general.string(forType: .string)
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }

        // Our own write. Consume it so it is never revisited, and record nothing.
        guard !isSuppressed else { commit(count); return }

        // Provenance is captured on first sighting, because the user can switch
        // apps during the retry window below.
        if pendingChangeCount != count {
            pendingChangeCount = count
            pendingAttempts = 0
            sourceApp = AppContext.frontmost()
        }
        pendingAttempts += 1

        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Writers bump changeCount inside clearContents() and write the data
            // a moment later. Consuming the change on that first empty read
            // loses the clip permanently, so give the writer a few ticks before
            // concluding this clip is genuinely not text.
            if pendingAttempts >= Self.maxPendingAttempts { commit(count) }
            return
        }
        commit(count)

        // The current clipboard is still usable for an explicit ⇧⌘V — the user
        // copied that deliberately — but history is a durable surface that the
        // pull flow reads from, so it holds a higher bar.
        guard SensitiveContent.mayRetain(text, types: pasteboard.types ?? []) else {
            Log.write("clipboard: changed, not retained (sensitive or transient)")
            return
        }

        if history.first?.text == text { return }
        history.insert(Entry(text: text, source: sourceApp, capturedAt: Date()), at: 0)
        if history.count > Self.capacity { history.removeLast(history.count - Self.capacity) }
        Log.write("clipboard: changed, source=\(sourceApp?.name ?? "unknown"), history=\(history.count)")
        onRetainedClip?(text)
    }

    /// Marks a change as fully handled, so it is never revisited.
    private func commit(_ count: Int) {
        lastChangeCount = count
        pendingChangeCount = nil
        pendingAttempts = 0
    }

}
