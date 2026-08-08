import Foundation

/// Lexical ranking of clipboard history, on-device.
///
/// The interesting queries — "the address from last week", "that tracking
/// number" — are exactly the ones plain text matching cannot answer, which is
/// why the model does the real work. This exists for two narrower reasons: it
/// answers literal queries instantly and for free, and it means the feature
/// still functions without an API key or a network instead of disappearing.
enum HistorySearch {

    struct Hit {
        let index: Int
        let score: Double
    }

    /// Words too common to carry signal. Deliberately short — an aggressive stop
    /// list starts eating the words that make a query specific.
    private static let noise: Set<String> = [
        "the", "a", "an", "that", "this", "my", "i", "copied", "copy",
        "from", "of", "for", "and", "was", "is", "it", "to", "in", "on"
    ]

    static func rank(query: String, history: [ClipboardMonitor.Entry]) -> [Hit] {
        let terms = tokenize(query).filter { !noise.contains($0) && $0.count > 1 }
        guard !terms.isEmpty else { return [] }

        var hits: [Hit] = []
        for (index, entry) in history.enumerated() {
            let haystack = entry.text.lowercased()
            let source = (entry.source?.name ?? "").lowercased()

            var score = 0.0
            for term in terms {
                if haystack.contains(term) {
                    score += 2
                } else if source.contains(term) {
                    // Naming the app it came from is a weaker signal than the
                    // content itself, but it is how people actually remember.
                    score += 1.5
                } else if tokenize(entry.text).contains(where: { $0.hasPrefix(term) }) {
                    score += 1
                }
            }
            guard score > 0 else { continue }

            // Normalize so a long clip does not win by sheer surface area, then
            // apply a small recency nudge that only ever breaks ties.
            let normalized = score / Double(terms.count)
            let recency = 1.0 - (Double(index) / Double(max(history.count, 1))) * 0.05
            hits.append(Hit(index: index, score: normalized * recency))
        }
        return hits.sorted { $0.score > $1.score }
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
