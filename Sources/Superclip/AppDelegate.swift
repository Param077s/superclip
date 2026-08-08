import AppKit
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var axItem: NSMenuItem!
    private var screenItem: NSMenuItem!
    private var keyItem: NSMenuItem!
    private var fastItem: NSMenuItem!

    private let hotkeys = HotkeyManager()
    private let clipboard = ClipboardMonitor()
    private let transformer = Transformer()
    private let preview = PreviewPanel()
    private let regionSelector = RegionSelector()
    private let stack = CopyStack()
    private let queryPanel = QueryPanel()
    private var stackItem: NSMenuItem!

    /// What the preview panel is currently showing, if anything.
    private enum Flow {
        /// ⇧⌘V — reshaping the clipboard for `target`.
        case paste(target: AppContext, original: String)
        /// ⌥⇧⌘C — text lifted off the screen; the image is kept so the read can
        /// be escalated to the model if the on-device OCR was not good enough.
        case capture(image: CGImage)
        /// ⌃⌘V — the field asked; suggestions are being ranked for it.
        case pull(target: AppContext)
        /// ⌃⇧⌘V — one record spread across a whole form, pending review.
        case fill(target: AppContext)
        /// ⌃⌥F — searching history for something described from memory.
        case search(target: AppContext)
    }

    private var flow: Flow?
    private var streamTask: Task<Void, Never>?
    private var candidates: [PullCandidate] = []
    private var candidateIndex = 0
    private var pendingAssignments: [FieldAssignment] = []
    /// Restored after a capture, so the user lands back where they were.
    private var appBeforeCapture: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.reset()
        Log.write("launch: AX=\(Permissions.hasAccessibility) SR=\(Permissions.hasScreenRecording) key=\(Settings.apiKey != nil)")

        setupStatusItem()

        stack.onChange = { [weak self] in self?.refreshStatusItem() }
        clipboard.onRetainedClip = { [weak self] text in self?.stack.append(text) }
        clipboard.start()

        hotkeys.registerSmartPaste { [weak self] in self?.handleSmartPaste() }
        hotkeys.registerScreenCapture { [weak self] in self?.handleScreenCapture() }
        hotkeys.registerPullPaste { [weak self] in self?.handlePullPaste() }
        hotkeys.registerFillForm { [weak self] in self?.handleFillForm() }
        hotkeys.registerToggleStack { [weak self] in self?.handleToggleStack() }
        hotkeys.registerPopStack { [weak self] in self?.handlePopStack() }
        hotkeys.registerMergeStack { [weak self] in self?.handleMergeStack() }
        hotkeys.registerSearchHistory { [weak self] in self?.handleSearchHistory() }

        if !Permissions.hasAccessibility { Permissions.requestAccessibility() }
    }

    // MARK: - ⇧⌘V — smart paste

    private func handleSmartPaste() {
        guard flow == nil, !regionSelector.isActive else { dismiss(); return }
        guard let clip = clipboard.text,
              !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            Log.write("paste: clipboard empty or non-text")
            return
        }
        beginSmartPaste(clip: clip, source: clipboard.sourceApp, headline: nil)
    }

    /// The shared body of the smart-paste flow. Also reached from the copy
    /// stack's merged paste, which supplies its own joined content.
    private func beginSmartPaste(clip: String, source: AppContext?, headline: String?) {
        guard let target = AppContext.frontmost() else { NSSound.beep(); return }
        guard Settings.apiKey != nil else { promptForAPIKey(); return }

        let destination = Destination.profile(for: target)
        flow = .paste(target: target, original: clip)

        preview.onPrimary = { [weak self] text in self?.acceptPaste(text) }
        preview.onSecondary = { [weak self] in self?.pasteOriginal() }
        preview.onCancel = { [weak self] in self?.dismiss() }
        preview.onCycle = nil

        let route = headline ?? source.map { "\($0.name) → \(target.name)" } ?? target.name
        preview.show(headline: route,
                     subtitle: destination.label,
                     primaryAction: "Paste",
                     secondaryAction: "Paste original")
        Log.write("paste: \(route) \(destination.label), \(clip.count) chars")

        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.runStream {
                try await self.transformer.stream(
                    clip: clip, source: source, target: target, destination: destination
                ) { [weak self] delta in self?.preview.append(delta) }
            }
        }
    }

    private func acceptPaste(_ text: String) {
        guard case .paste(let target, _) = flow else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { dismiss(); return }
        dismiss()
        performPaste(trimmed, into: target)
    }

    private func pasteOriginal() {
        guard case .paste(let target, let original) = flow else { return }
        dismiss()
        performPaste(original, into: target)
    }

    /// Every paste goes through here so the monitor can be muted for its
    /// duration — otherwise Superclip's own write lands back in the history, and
    /// during a stack drain the stack would refill from its own output.
    private func performPaste(_ text: String, into target: AppContext) {
        clipboard.isSuppressed = true
        Task { [weak self] in
            await PasteEngine.paste(text, into: target)
            self?.clipboard.isSuppressed = false
        }
    }

    // MARK: - ⌥⇧⌘C — copy anything on screen

    private func handleScreenCapture() {
        guard flow == nil, !regionSelector.isActive else { dismiss(); return }

        guard Permissions.hasScreenRecording else {
            Permissions.requestScreenRecording()
            // The grant only takes effect on relaunch, so say so rather than
            // letting the next attempt fail silently.
            notifyPermissionNeeded()
            return
        }

        appBeforeCapture = NSWorkspace.shared.frontmostApplication
        regionSelector.begin(
            onSelect: { [weak self] rect, screen in self?.captureRegion(rect, on: screen) },
            onCancel: { [weak self] in self?.restorePreviousApp() }
        )
    }

    private func captureRegion(_ rect: NSRect, on screen: NSScreen) {
        Task { [weak self] in
            guard let self else { return }
            // The overlay windows are ordered out, but the compositor needs a
            // frame to actually stop drawing them — otherwise the dimming ends
            // up baked into the captured image.
            try? await Task.sleep(for: .milliseconds(90))

            do {
                let image = try await ScreenCapture.capture(globalRect: rect, on: screen)
                Log.write("capture: \(image.width)×\(image.height)px")
                self.presentCapture(image)
            } catch {
                Log.write("capture: failed — \(error.localizedDescription)")
                self.restorePreviousApp()
                NSSound.beep()
            }
        }
    }

    private func presentCapture(_ image: CGImage) {
        flow = .capture(image: image)

        preview.onPrimary = { [weak self] text in self?.acceptCopy(text) }
        preview.onSecondary = { [weak self] in self?.escalateToModel() }
        preview.onCancel = { [weak self] in self?.dismiss() }
        preview.onCycle = nil

        let ocr = TextRecognizer.recognize(image)
        let ink = InkAnalysis.classify(image: image, ocr: ocr)
        Log.write("ocr: \(ocr.text.count) chars, confidence=\(String(format: "%.2f", ocr.confidence)), tabular=\(ocr.looksTabular), ink=\(ink.content.rawValue) (\(String(format: "%.3f", ink.inkCoverage)))")

        // On-device OCR is instant, free, and offline, so it always runs first
        // and its result is what the user sees. The model is only spent when
        // Vision came back empty or unsure — or when the user asks for it with
        // ⌘↩, which is the escape hatch for layouts the gap heuristic mangles.
        let canUseModel = Settings.apiKey != nil

        // A region with no marks on it is not worth a model call. But a small
        // amount of writing inside a large selection sits at the same level as
        // compression noise and cannot be told apart from it, so this verdict is
        // offered rather than enforced — ⌘↩ reads it anyway.
        if ink.content == .blank {
            preview.show(headline: "Copied from screen",
                         subtitle: "nothing to read here",
                         primaryAction: "Dismiss",
                         secondaryAction: canUseModel ? "Read anyway" : nil,
                         isStreaming: false)
            preview.onPrimary = { [weak self] _ in self?.dismiss() }
            preview.onSecondary = { [weak self] in self?.forceHandwritingRead() }
            preview.showError("No text or writing found in that region.")
            return
        }

        // Marks Vision could not resolve are, in practice, handwriting.
        if ink.content == .handwritten && canUseModel {
            preview.show(headline: "Copied from screen",
                         subtitle: "reading handwriting…",
                         primaryAction: "Copy",
                         secondaryAction: nil)
            runHandwritingRead()
            return
        }

        if ocr.isTrustworthy || !canUseModel {
            let subtitle: String
            if ocr.isEmpty {
                subtitle = "no text found"
            } else if ocr.looksTabular {
                subtitle = "read on-device · columns detected"
            } else {
                subtitle = "read on-device"
            }
            preview.show(headline: "Copied from screen",
                         subtitle: subtitle,
                         primaryAction: "Copy",
                         secondaryAction: canUseModel ? "Read with AI" : nil,
                         isStreaming: false)
            preview.setText(ocr.text)
        } else {
            preview.show(headline: "Copied from screen",
                         subtitle: ocr.isEmpty ? "reading…" : "rechecking…",
                         primaryAction: "Copy",
                         secondaryAction: nil)
            runModelRead()
        }
    }

    private func escalateToModel() {
        guard case .capture = flow, Settings.apiKey != nil else { return }
        preview.setSubtitle("rereading…")
        preview.setSecondaryAction(nil)
        preview.beginStreaming()
        runModelRead()
    }

    private func runModelRead() {
        guard case .capture(let image) = flow else { return }
        guard let png = ScreenCapture.pngData(from: image) else {
            preview.showError("Could not encode the captured image.")
            return
        }

        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.runStream(onSuccess: { self.preview.setSubtitle("read with AI") }) {
                try await self.transformer.streamScreenRead(png: png) { [weak self] delta in
                    self?.preview.append(delta)
                }
            }
        }
    }

    /// Overrides a "blank" verdict at the user's request.
    private func forceHandwritingRead() {
        guard case .capture = flow, Settings.apiKey != nil else { return }
        preview.onPrimary = { [weak self] text in self?.acceptCopy(text) }
        preview.setSubtitle("reading handwriting…")
        preview.setSecondaryAction(nil)
        preview.setPrimaryAction("Copy")
        preview.beginStreaming()
        Log.write("handwriting: forced read over blank verdict")
        runHandwritingRead()
    }

    /// The handwriting path does not stream, so the panel sits on its spinner
    /// until the whole transcription lands. That is the right trade here: the
    /// alternative is streaming text with no way to say which words are guesses.
    private func runHandwritingRead() {
        guard case .capture(let image) = flow else { return }
        guard let png = ScreenCapture.pngData(from: image) else {
            preview.showError("Could not encode the captured image.")
            return
        }

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let read = try await self.transformer.readHandwriting(png: png)
                guard !Task.isCancelled else { return }
                self.preview.finishStreaming()

                guard !read.isEmpty else {
                    self.preview.showError("Could not make out any writing in that region.")
                    Log.write("handwriting: nothing legible")
                    return
                }

                // What gets copied is the transcription and nothing else. The
                // uncertain readings are surfaced in the header instead, so the
                // user knows what to double-check without it polluting the clip.
                self.preview.setText(read.text)
                self.preview.setSubtitle(Self.handwritingSubtitle(for: read))
                Log.write("handwriting: \(read.text.count) chars, \(read.uncertain.count) uncertain")
            } catch is CancellationError {
                // Cancelled by the user; the panel is already gone.
            } catch {
                if !Task.isCancelled {
                    self.preview.showError(error.localizedDescription)
                    Log.write("handwriting: failed — \(error.localizedDescription)")
                }
            }
        }
    }

    private static func handwritingSubtitle(for read: HandwritingRead) -> String {
        guard !read.uncertain.isEmpty else { return "handwriting · read cleanly" }
        let shown = read.uncertain.prefix(3).joined(separator: ", ")
        let more = read.uncertain.count > 3 ? " +\(read.uncertain.count - 3) more" : ""
        return "handwriting · check: \(shown)\(more)"
    }

    private func acceptCopy(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { dismiss(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
        Log.write("capture: copied \(trimmed.count) chars")
        dismiss()
    }

    // MARK: - ⌃⌘V — pull: paste without copy

    private func handlePullPaste() {
        guard flow == nil, !regionSelector.isActive else { dismiss(); return }

        guard Permissions.hasAccessibility else {
            Permissions.requestAccessibility()
            NSSound.beep()
            Log.write("pull: needs Accessibility to read the field")
            return
        }
        guard let target = AppContext.frontmost() else { NSSound.beep(); return }
        guard Settings.apiKey != nil else { promptForAPIKey(); return }

        let field = FieldIntent.focused(in: target)
            ?? FieldIntent(app: target, role: nil, subrole: nil, label: nil, existingValue: nil)

        flow = .pull(target: target)
        candidates = []
        candidateIndex = 0
        preview.onPrimary = { [weak self] text in self?.acceptPull(text) }
        preview.onSecondary = nil
        preview.onCancel = { [weak self] in self?.dismiss() }
        preview.onCycle = { [weak self] delta in self?.cycleCandidate(by: delta) }

        // Password fields are a hard no. A clipboard tool guessing at credentials
        // is the single fastest way to stop being trusted with a clipboard.
        guard !field.isSecure else {
            preview.onPrimary = { [weak self] _ in self?.dismiss() }
            preview.show(headline: "Pull into \(target.name)",
                         subtitle: "secure field",
                         primaryAction: "Dismiss",
                         secondaryAction: nil,
                         isStreaming: false)
            preview.showError("Superclip never fills password fields — use your password manager.")
            Log.write("pull: refused, secure field")
            return
        }

        let history = clipboard.history
        guard !history.isEmpty else {
            preview.show(headline: "Pull into \(target.name)",
                         subtitle: field.shortLabel,
                         primaryAction: "Dismiss",
                         secondaryAction: nil,
                         isStreaming: false)
            preview.showError("Nothing copied yet this session — there is nothing to pull from.")
            return
        }

        preview.show(headline: "Pull into \(target.name)",
                     subtitle: field.shortLabel,
                     primaryAction: "Insert",
                     secondaryAction: nil)
        Log.write("pull: field=\(field.shortLabel) role=\(field.role ?? "?") history=\(history.count)")

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let matches = try await self.transformer.pullCandidates(field: field,
                                                                        history: history)
                guard !Task.isCancelled else { return }
                self.presentCandidates(matches, field: field)
            } catch is CancellationError {
                // Cancelled by the user; the panel is already gone.
            } catch {
                if !Task.isCancelled {
                    self.preview.showError(error.localizedDescription)
                    Log.write("pull: failed — \(error.localizedDescription)")
                }
            }
        }
    }

    private func presentCandidates(_ matches: [PullCandidate], field: FieldIntent) {
        preview.finishStreaming()
        candidates = matches
        candidateIndex = 0

        guard !matches.isEmpty else {
            // An empty result is a correct answer, not a failure. Saying so
            // plainly beats offering something that does not belong here.
            preview.showError("Nothing in your recent clipboard fits \(field.shortLabel).")
            Log.write("pull: no candidates fit")
            return
        }
        showCandidate(at: 0)
        Log.write("pull: \(matches.count) candidate(s)")
    }

    private func showCandidate(at index: Int) {
        guard candidates.indices.contains(index) else { return }
        candidateIndex = index
        preview.setText(candidates[index].content)
        preview.setSubtitle(candidates[index].label)
        preview.setCycleHint(candidates.count > 1 ? "\(index + 1) of \(candidates.count)" : nil)
    }

    private func cycleCandidate(by delta: Int) {
        guard !candidates.isEmpty else { return }
        showCandidate(at: (candidateIndex + delta + candidates.count) % candidates.count)
    }

    private func acceptPull(_ text: String) {
        guard case .pull(let target) = flow else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { dismiss(); return }
        dismiss()
        performPaste(trimmed, into: target)
    }

    // MARK: - ⌃⌥C / ⌃⌥V — the copy stack

    private func handleToggleStack() {
        if stack.isCollecting {
            stack.stopCollecting()
        } else {
            // Seed with whatever is on the clipboard: in practice people copy
            // the first thing and only then realize they want a stack.
            stack.startCollecting(seed: clipboard.text)
        }
    }

    /// Pastes the next item. No model call, no network, no preview — the user
    /// already chose these values, and the whole point is that one press equals
    /// one field.
    private func handlePopStack() {
        guard flow == nil, !regionSelector.isActive else { dismiss(); return }
        guard let target = AppContext.frontmost() else { NSSound.beep(); return }
        guard !stack.isEmpty else {
            NSSound.beep()
            Log.write("stack: pop on empty stack")
            return
        }
        // Draining implies the collection is finished.
        if stack.isCollecting { stack.stopCollecting() }
        guard let item = stack.popFirst() else { return }
        Log.write("stack: popped, \(stack.count) remaining")
        performPaste(item, into: target)
    }

    /// Pastes everything left as one block, through the ordinary smart-paste
    /// pipeline so it still gets shaped for wherever it lands — a stack of rows
    /// merged into a spreadsheet is different from the same rows merged into a
    /// chat window.
    private func handleMergeStack() {
        guard flow == nil, !regionSelector.isActive else { dismiss(); return }
        guard !stack.isEmpty else {
            NSSound.beep()
            Log.write("stack: merge on empty stack")
            return
        }
        if stack.isCollecting { stack.stopCollecting() }
        let items = stack.drainAll()
        Log.write("stack: merging \(items.count) item(s)")
        beginSmartPaste(clip: items.joined(separator: "\n"),
                        source: nil,
                        headline: "Stack of \(items.count) → \(AppContext.frontmost()?.name ?? "app")")
    }

    @objc private func clearStack() { stack.clear() }

    // MARK: - ⌃⌥F — ask for something you copied

    private func handleSearchHistory() {
        guard flow == nil, !regionSelector.isActive else { dismiss(); return }
        guard !queryPanel.isVisible else { queryPanel.hide(); return }
        guard let target = AppContext.frontmost() else { NSSound.beep(); return }
        guard !clipboard.history.isEmpty else {
            NSSound.beep()
            Log.write("search: history empty")
            return
        }

        queryPanel.onCancel = { [weak self] in self?.queryPanel.hide() }
        queryPanel.onSubmit = { [weak self] query in
            self?.queryPanel.hide()
            self?.runSearch(query: query, target: target)
        }
        queryPanel.show(placeholder: "Search what you've copied…")
    }

    private func runSearch(query: String, target: AppContext) {
        let history = clipboard.history
        flow = .search(target: target)
        candidates = []
        candidateIndex = 0
        preview.onPrimary = { [weak self] text in self?.acceptSearchResult(text) }
        preview.onSecondary = nil
        preview.onCancel = { [weak self] in self?.dismiss() }
        preview.onCycle = { [weak self] delta in self?.cycleCandidate(by: delta) }

        // The local pass runs first and always. It answers literal queries with
        // no network at all, and it is what keeps the feature working when there
        // is no API key.
        let lexical = HistorySearch.rank(query: query, history: history)
        Log.write("search: \"\(query)\" over \(history.count) item(s), \(lexical.count) lexical hit(s)")

        guard Settings.apiKey != nil else {
            preview.show(headline: "Search: \(query)",
                         subtitle: "matched on text only",
                         primaryAction: "Paste",
                         secondaryAction: nil,
                         isStreaming: false)
            presentSearchResults(lexical.prefix(5).map {
                PullCandidate(label: "from \(history[$0.index].sourceName)",
                              content: history[$0.index].text)
            })
            return
        }

        preview.show(headline: "Search: \(query)",
                     subtitle: "looking…",
                     primaryAction: "Paste",
                     secondaryAction: nil)

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let matches = try await self.transformer.searchHistory(query: query, history: history)
                guard !Task.isCancelled else { return }
                self.preview.finishStreaming()
                // Content comes from history, never from the model — the model
                // only ever chose which items.
                self.presentSearchResults(matches.map {
                    PullCandidate(label: $0.label, content: history[$0.index].text)
                })
            } catch is CancellationError {
                // Cancelled by the user; the panel is already gone.
            } catch {
                if !Task.isCancelled {
                    self.preview.showError(error.localizedDescription)
                    Log.write("search: failed — \(error.localizedDescription)")
                }
            }
        }
    }

    private func presentSearchResults(_ results: [PullCandidate]) {
        preview.finishStreaming()
        candidates = results
        candidateIndex = 0
        guard !results.isEmpty else {
            preview.showError("Nothing in your recent history matches that.")
            Log.write("search: no matches")
            return
        }
        showCandidate(at: 0)
        Log.write("search: \(results.count) match(es)")
    }

    private func acceptSearchResult(_ text: String) {
        guard case .search(let target) = flow else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { dismiss(); return }
        dismiss()
        performPaste(trimmed, into: target)
    }

    // MARK: - ⌃⇧⌘V — fill a whole form from one copied record

    private func handleFillForm() {
        guard flow == nil, !regionSelector.isActive else { dismiss(); return }

        guard Permissions.hasAccessibility else {
            Permissions.requestAccessibility()
            NSSound.beep()
            Log.write("fill: needs Accessibility to read the form")
            return
        }
        guard let target = AppContext.frontmost() else { NSSound.beep(); return }
        guard let record = clipboard.text,
              !record.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            Log.write("fill: clipboard empty")
            return
        }
        guard Settings.apiKey != nil else { promptForAPIKey(); return }

        flow = .fill(target: target)
        pendingAssignments = []
        preview.onPrimary = { [weak self] _ in self?.commitFill() }
        preview.onSecondary = nil
        preview.onCancel = { [weak self] in self?.dismiss() }
        preview.onCycle = nil

        // Only empty fields are offered. Overwriting something the user already
        // typed is the worst failure this feature can have, so it is simply not
        // on the table — clear a field and run again to replace it.
        let allFields = FormScanner.scan(app: target)
        let fields = allFields.filter(\.isEmpty)
        let occupied = allFields.count - fields.count

        preview.show(headline: "Fill form in \(target.name)",
                     subtitle: "\(fields.count) empty field\(fields.count == 1 ? "" : "s")",
                     primaryAction: "Fill",
                     secondaryAction: nil)

        guard !fields.isEmpty else {
            preview.showError(allFields.isEmpty
                ? "No writable fields found in this window."
                : "All \(occupied) field\(occupied == 1 ? "" : "s") here already have content.")
            return
        }

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let mapped = try await self.transformer.mapFields(record: record, fields: fields)
                guard !Task.isCancelled else { return }
                self.presentFillPlan(mapped, fields: fields, occupied: occupied)
            } catch is CancellationError {
                // Cancelled by the user; the panel is already gone.
            } catch {
                if !Task.isCancelled {
                    self.preview.showError(error.localizedDescription)
                    Log.write("fill: failed — \(error.localizedDescription)")
                }
            }
        }
    }

    private func presentFillPlan(_ mapped: [(index: Int, value: String)],
                                 fields: [FormField],
                                 occupied: Int) {
        preview.finishStreaming()
        pendingAssignments = mapped.map { FieldAssignment(field: fields[$0.index], value: $0.value) }

        guard !pendingAssignments.isEmpty else {
            preview.showError("Nothing in the clipboard maps onto this form.")
            Log.write("fill: no assignments")
            return
        }

        // Nothing is written until the user has seen exactly what will change.
        // This is the most destructive thing Superclip can do, and it happens in
        // someone else's app, so the review step is not optional.
        let width = pendingAssignments
            .map { ($0.field.label ?? "unlabelled").count }
            .max() ?? 0
        var lines = pendingAssignments.map { assignment in
            let label = assignment.field.label ?? "unlabelled"
            let padding = String(repeating: " ", count: max(0, width - label.count))
            return "\(label)\(padding)  →  \(assignment.value)"
        }
        let untouched = fields.count - pendingAssignments.count
        if untouched > 0 || occupied > 0 {
            lines.append("")
            if untouched > 0 { lines.append("\(untouched) empty field(s) left alone — no match in the record.") }
            if occupied > 0 { lines.append("\(occupied) field(s) already had content and were not offered.") }
        }
        preview.setText(lines.joined(separator: "\n"))
        preview.setSubtitle("review before filling")
        preview.setPrimaryAction("Fill \(pendingAssignments.count) field\(pendingAssignments.count == 1 ? "" : "s")")
        Log.write("fill: planned \(pendingAssignments.count) assignment(s)")
    }

    private func commitFill() {
        guard case .fill(let target) = flow, !pendingAssignments.isEmpty else { dismiss(); return }
        let assignments = pendingAssignments
        dismiss()
        // The filler falls back to pasting, so mute the monitor for the duration.
        clipboard.isSuppressed = true
        Task { [weak self] in
            let report = await FormFiller.fill(assignments, in: target)
            self?.clipboard.isSuppressed = false
            if !report.skipped.isEmpty {
                Log.write("fill: skipped \(report.skipped.map(\.label).joined(separator: ", "))")
            }
        }
    }

    // MARK: - Shared streaming + teardown

    private func runStream(onSuccess: (() -> Void)? = nil,
                           _ work: () async throws -> Void) async {
        do {
            try await work()
            if !Task.isCancelled {
                preview.finishStreaming()
                onSuccess?()
            }
        } catch is CancellationError {
            // Cancelled by the user; the panel is already gone.
        } catch {
            if !Task.isCancelled {
                preview.showError(error.localizedDescription)
                Log.write("stream: failed — \(error.localizedDescription)")
            }
        }
    }

    /// Tears down whatever is in flight and hides the panel.
    private func dismiss() {
        streamTask?.cancel()
        streamTask = nil
        regionSelector.end()
        queryPanel.hide()
        if case .capture = flow { restorePreviousApp() }
        flow = nil
        candidates = []
        candidateIndex = 0
        pendingAssignments = []
        preview.hide()
    }

    /// The region overlay has to activate Superclip to receive Escape, which
    /// steals focus. Hand it back so the user can paste where they were.
    private func restorePreviousApp() {
        appBeforeCapture?.activate()
        appBeforeCapture = nil
    }

    private func notifyPermissionNeeded() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Superclip needs Screen Recording to read text out of a region of your screen. Grant it in System Settings, then quit and reopen Superclip — macOS only applies the change on relaunch."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openScreenRecordingSettings()
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshStatusItem()

        let menu = NSMenu()
        menu.delegate = self

        for title in ["⇧⌘V   Paste smart",
                      "⌥⇧⌘C   Copy from screen",
                      "⌃⌘V   Pull into this field",
                      "⌃⇧⌘V   Fill this form",
                      "⌃⌥C   Start / stop collecting",
                      "⌃⌥V   Paste next from stack",
                      "⌃⌥⇧V   Paste stack merged",
                      "⌃⌥F   Search what you've copied"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        stackItem = NSMenuItem(title: "Clear stack", action: #selector(clearStack), keyEquivalent: "")
        stackItem.target = self
        menu.addItem(stackItem)
        menu.addItem(.separator())

        keyItem = NSMenuItem(title: "Set API Key…", action: #selector(promptForAPIKey), keyEquivalent: "")
        keyItem.target = self
        menu.addItem(keyItem)

        fastItem = NSMenuItem(title: "Fast mode", action: #selector(toggleFastMode), keyEquivalent: "")
        fastItem.target = self
        menu.addItem(fastItem)

        menu.addItem(.separator())

        axItem = NSMenuItem(title: "Accessibility", action: #selector(openAccessibility), keyEquivalent: "")
        axItem.target = self
        menu.addItem(axItem)

        screenItem = NSMenuItem(title: "Screen Recording", action: #selector(openScreenRecording), keyEquivalent: "")
        screenItem.target = self
        menu.addItem(screenItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Superclip",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    /// The stack is the one piece of hidden state Superclip holds, so it is made
    /// unmistakable in the menu bar: a different icon while collecting, and a
    /// live count whenever anything is queued.
    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        if stack.isCollecting {
            symbol = "square.stack.3d.up.fill"
        } else if !stack.isEmpty {
            symbol = "square.stack.3d.up"
        } else {
            symbol = "doc.on.clipboard"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Superclip")
        button.title = stack.isEmpty ? "" : " \(stack.count)"
    }

    func menuWillOpen(_ menu: NSMenu) {
        if stack.isCollecting {
            stackItem.title = "Collecting — \(stack.count) item(s) · Clear"
        } else if stack.isEmpty {
            stackItem.title = "Stack empty"
        } else {
            stackItem.title = "Clear stack (\(stack.count) item(s))"
        }
        stackItem.isEnabled = !stack.isEmpty || stack.isCollecting

        axItem.title = Permissions.hasAccessibility
            ? "Accessibility ✓" : "Accessibility — grant access…"
        screenItem.title = Permissions.hasScreenRecording
            ? "Screen Recording ✓" : "Screen Recording — grant access…"
        keyItem.title = Settings.apiKey != nil ? "Change API Key…" : "Set API Key…"
        fastItem.state = Settings.fastMode ? .on : .off
    }

    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func openScreenRecording() { Permissions.openScreenRecordingSettings() }

    @objc private func toggleFastMode() {
        Settings.fastMode.toggle()
        Log.write("settings: fastMode=\(Settings.fastMode)")
    }

    @objc private func promptForAPIKey() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Anthropic API key"
        alert.informativeText = "Stored in your login keychain. Superclip sends the clipboard contents, or the region of the screen you select, plus the name of the app you are pasting into."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { Settings.setAPIKey(value) }
        }
    }
}
