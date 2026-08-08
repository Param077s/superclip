import Foundation
import Testing
@testable import SuperclipKit

/// The local search pass.
///
/// Note what the last test asserts: the descriptive queries that motivate the
/// whole feature return *nothing* here. That is the design, not a defect — this
/// pass exists to answer literal queries instantly and to keep search working
/// with no API key, and the model handles everything it cannot.
@Suite("History search")
@MainActor
struct HistorySearchTests {

    private func entry(_ text: String, _ app: String, minutesAgo: Int) -> ClipboardMonitor.Entry {
        ClipboardMonitor.Entry(
            text: text,
            source: AppContext(name: app, bundleID: "test.\(app)", pid: 0, windowTitle: nil),
            capturedAt: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo))
        )
    }

    private var history: [ClipboardMonitor.Entry] {
        [
            entry("412 Kingsway Road, Jalandhar, Punjab 144001", "Notes", minutesAgo: 5),
            entry("postgres://analytics:pw@db.internal:5432/main", "Slack", minutesAgo: 20),
            entry("VR-88231", "Safari", minutesAgo: 60),
            entry("SELECT id, email FROM users WHERE active", "TablePlus", minutesAgo: 120),
            entry("simran@example.com", "Mail", minutesAgo: 200),
            entry("The quarterly review is on Thursday", "Slack", minutesAgo: 400)
        ]
    }

    private func topMatch(_ query: String) -> Int? {
        HistorySearch.rank(query: query, history: history).first?.index
    }

    @Test("Finds an identifier verbatim")
    func literalIdentifier() {
        #expect(topMatch("VR-88231") == 2)
    }

    @Test("Finds by a distinctive content word")
    func contentWord() {
        #expect(topMatch("postgres") == 1)
    }

    @Test("Filters by the app it came from")
    func sourceApp() {
        #expect(topMatch("from TablePlus") == 3)
    }

    @Test("Prefers the item matching more terms")
    func multipleTerms() {
        #expect(topMatch("kingsway jalandhar") == 0)
    }

    @Test("Stopwords alone match nothing")
    func stopwordsOnly() {
        #expect(HistorySearch.rank(query: "the that I copied", history: history).isEmpty)
    }

    @Test("An empty query matches nothing")
    func emptyQuery() {
        #expect(HistorySearch.rank(query: "   ", history: history).isEmpty)
    }

    @Test("An empty history matches nothing")
    func emptyHistory() {
        #expect(HistorySearch.rank(query: "anything", history: []).isEmpty)
    }

    /// The queries this pass is *supposed* to miss. If one of these starts
    /// matching, something has become accidentally clever and the result is
    /// coincidence rather than understanding.
    @Test("Descriptive queries are left to the model", arguments: [
        "the address from last week",
        "that tracking number",
        "the SQL from yesterday"
    ])
    func descriptiveQueriesMiss(_ query: String) {
        #expect(HistorySearch.rank(query: query, history: history).isEmpty)
    }
}
