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

    /// How many clips are kept, in memory and on disk alike.
    ///
    /// Sized for search rather than for the pull flow, which only ever reads the
    /// top of the list. A search over the last forty clips would rarely contain
    /// the thing being looked for.
    ///
    /// History is persisted by `HistoryStore`, encrypted and expiring. What is
    /// allowed in at all is `SensitiveContent`'s decision, and it is applied
    /// before anything reaches this list — so the store can never contain a clip
    /// the retention rules would have refused.
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

    private var saveTimer: Timer?

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        loadPersisted()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        flush()
    }

    // MARK: - Persistence

    private func loadPersisted() {
        let clips = HistoryStore.load(retentionDays: Settings.retentionDays, cap: Self.capacity)
        history = clips.map { clip in
            Entry(text: clip.text,
                  source: clip.appName.map {
                      // pid and window title are deliberately not persisted, so
                      // a restored entry knows which app it came from and
                      // nothing more.
                      AppContext(name: $0, bundleID: clip.bundleID ?? "unknown",
                                 pid: 0, windowTitle: nil)
                  },
                  capturedAt: clip.capturedAt)
        }
    }

    /// Writes are debounced: copying is bursty, and re-sealing the whole store
    /// on every clip would encrypt and rewrite the file several times a second
    /// during a copy stack run for no benefit.
    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Persists immediately. Called on quit and when the retention setting
    /// changes, where waiting for the debounce would lose the write.
    func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        HistoryStore.save(history.map {
            PersistedClip(text: $0.text,
                          appName: $0.source?.name,
                          bundleID: $0.source?.bundleID,
                          capturedAt: $0.capturedAt)
        }, retentionDays: Settings.retentionDays, cap: Self.capacity)
    }

    /// Drops everything, in memory and on disk.
    func forgetEverything() {
        history.removeAll()
        saveTimer?.invalidate()
        saveTimer = nil
        HistoryStore.purge()
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
        scheduleSave()
        onRetainedClip?(text)
    }

    /// Marks a change as fully handled, so it is never revisited.
    private func commit(_ count: Int) {
        lastChangeCount = count
        pendingChangeCount = nil
        pendingAttempts = 0
    }

}
