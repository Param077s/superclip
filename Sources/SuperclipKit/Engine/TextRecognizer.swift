import CoreGraphics
import Foundation
import Vision

/// On-device OCR. This runs first on every capture because it is free, offline,
/// and finishes in tens of milliseconds — for the common case (an error dialog,
/// a locked PDF, a label you can see but not select) it is the whole answer.
/// The model is only worth paying for when this comes back empty or unsure.
enum TextRecognizer {

    struct Result {
        let text: String
        /// Mean confidence across recognized fragments, 0…1.
        let confidence: Float
        /// True when column gaps were detected and turned into tabs. Surfaced to
        /// the user as a nudge to check the columns before pasting — the gap
        /// heuristic handles single-line cells well but cannot see that a cell
        /// wrapped onto a second visual line.
        let looksTabular: Bool

        var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        /// Whether this result is good enough to hand the user directly, rather
        /// than spending a model call and the latency that comes with it.
        var isTrustworthy: Bool { !isEmpty && confidence >= 0.6 }

        static let empty = Result(text: "", confidence: 0, looksTabular: false)
    }

    private struct Fragment {
        let text: String
        let confidence: Float
        let box: CGRect // normalized, bottom-left origin
    }

    static func recognize(_ image: CGImage) -> Result {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Log.write("ocr: vision failed — \(error.localizedDescription)")
            return .empty
        }

        let fragments: [Fragment] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return Fragment(text: candidate.string,
                            confidence: candidate.confidence,
                            box: observation.boundingBox)
        }
        guard !fragments.isEmpty else { return .empty }

        let (text, tabbed) = assemble(fragments)
        let confidence = fragments.map(\.confidence).reduce(0, +) / Float(fragments.count)
        return Result(text: text, confidence: confidence, looksTabular: tabbed)
    }

    /// Vision returns fragments in no useful order, so they are grouped into
    /// visual lines by vertical position and then read left to right. A wide
    /// horizontal gap between two fragments on the same line becomes a tab —
    /// which is what turns a screenshot of a table straight into pasteable TSV.
    private static func assemble(_ fragments: [Fragment]) -> (text: String, tabbed: Bool) {
        let medianHeight = median(fragments.map { $0.box.height })
        let lineTolerance = max(medianHeight * 0.6, 0.004)
        let columnGap = 0.035 // fraction of image width

        let sorted = fragments.sorted { $0.box.midY > $1.box.midY }

        var lines: [[Fragment]] = []
        for fragment in sorted {
            if var last = lines.last,
               let reference = last.first,
               abs(reference.box.midY - fragment.box.midY) <= lineTolerance {
                last.append(fragment)
                lines[lines.count - 1] = last
            } else {
                lines.append([fragment])
            }
        }

        var usedTab = false
        let rendered = lines.map { line -> String in
            let ordered = line.sorted { $0.box.minX < $1.box.minX }
            var text = ""
            var previous: Fragment?
            for fragment in ordered {
                if let previous {
                    let gap = fragment.box.minX - previous.box.maxX
                    if gap > columnGap {
                        text += "\t"
                        usedTab = true
                    } else {
                        text += " "
                    }
                }
                text += fragment.text
                previous = fragment
            }
            return text
        }

        return (rendered.joined(separator: "\n"), usedTab)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
