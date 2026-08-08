import AppKit
import Testing
@testable import SuperclipKit

/// On-device recognition and routing, exercised against real rendered images
/// rather than fixtures — Vision is doing actual work in these.
@Suite("Recognition and routing")
struct RecognitionTests {

    // MARK: - Image builders

    private static let size = NSSize(width: 600, height: 300)

    private func canvas(background: NSColor, _ draw: () -> Void) -> CGImage {
        let image = NSImage(size: Self.size)
        image.lockFocus()
        background.setFill()
        NSRect(origin: .zero, size: Self.size).fill()
        draw()
        image.unlockFocus()
        var rect = NSRect(origin: .zero, size: Self.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    }

    private func printedText(_ color: NSColor) -> () -> Void {
        {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 28), .foregroundColor: color
            ]
            "Shipment VR-88231".draw(at: NSPoint(x: 30, y: 200), withAttributes: attributes)
            "Delivered Tuesday".draw(at: NSPoint(x: 30, y: 150), withAttributes: attributes)
            "412 Kingsway Road".draw(at: NSPoint(x: 30, y: 100), withAttributes: attributes)
        }
    }

    /// Wobbly pen strokes — what handwriting looks like to an OCR engine that
    /// cannot read it.
    private func strokes(ink: NSColor, seed: UInt64) -> () -> Void {
        {
            var generator = SeededGenerator(seed: seed)
            ink.setStroke()
            for line in 0..<5 {
                let path = NSBezierPath()
                path.lineWidth = 2.5
                var x: CGFloat = 30
                let y = CGFloat(40 + line * 48)
                path.move(to: NSPoint(x: x, y: y))
                while x < 560 {
                    let next = x + CGFloat.random(in: 8...22, using: &generator)
                    path.curve(
                        to: NSPoint(x: next, y: y + CGFloat.random(in: -13...13, using: &generator)),
                        controlPoint1: NSPoint(x: x + 4, y: y + CGFloat.random(in: -18...18, using: &generator)),
                        controlPoint2: NSPoint(x: next - 4, y: y + CGFloat.random(in: -18...18, using: &generator))
                    )
                    x = next
                }
                path.stroke()
            }
        }
    }

    // MARK: - OCR

    @Test("Reads a table into tab-separated values with no model call")
    func tableBecomesTSV() {
        let columns: [CGFloat] = [40, 420, 700]
        let rows = [["Region", "Q3", "Q4"], ["North", "1200", "1450"], ["South", "980", "1130"]]

        let image = NSImage(size: NSSize(width: 900, height: 260))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 260).fill()
        var y: CGFloat = 200
        for row in rows {
            for (index, cell) in row.enumerated() {
                cell.draw(at: NSPoint(x: columns[index], y: y), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black
                ])
            }
            y -= 50
        }
        image.unlockFocus()
        var rect = NSRect(x: 0, y: 0, width: 900, height: 260)
        let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!

        let result = TextRecognizer.recognize(cgImage)
        #expect(result.looksTabular)
        #expect(result.text.contains("Region\tQ3\tQ4"))
        #expect(result.text.contains("North\t1200\t1450"))
    }

    @Test("Reads prose confidently enough to skip the model")
    func proseIsTrustworthy() {
        let result = TextRecognizer.recognize(canvas(background: .white, printedText(.black)))
        #expect(result.isTrustworthy)
        #expect(!result.looksTabular)
        #expect(result.text.contains("VR-88231"))
    }

    @Test("A blank region yields nothing")
    func blankYieldsNothing() {
        #expect(TextRecognizer.recognize(canvas(background: .white) {}).isEmpty)
    }

    // MARK: - Routing

    @Test("Confident text routes to printed")
    func routesPrinted() {
        for background: (NSColor, NSColor) in [(.white, .black), (.black, .white)] {
            let image = canvas(background: background.0, printedText(background.1))
            let ink = InkAnalysis.classify(image: image, ocr: TextRecognizer.recognize(image))
            #expect(ink.content == .printed)
        }
    }

    @Test("Marks Vision cannot read route to handwritten")
    func routesHandwritten() {
        let image = canvas(background: .white, strokes(ink: .black, seed: 7))
        let ink = InkAnalysis.classify(image: image, ocr: TextRecognizer.recognize(image))
        #expect(ink.content == .handwritten)
    }

    @Test("Faint pencil still routes to handwritten")
    func faintPencil() {
        let image = canvas(background: .white,
                           strokes(ink: NSColor(white: 0.45, alpha: 1), seed: 3))
        let ink = InkAnalysis.classify(image: image, ocr: TextRecognizer.recognize(image))
        #expect(ink.content == .handwritten)
    }

    @Test("An empty region routes to blank")
    func routesBlank() {
        for background: NSColor in [.white, .black] {
            let image = canvas(background: background) {}
            let ink = InkAnalysis.classify(image: image, ocr: TextRecognizer.recognize(image))
            #expect(ink.content == .blank)
        }
    }

    /// Ink coverage measures deviation from the region's own median, so the same
    /// marks on a light and a dark background must measure identically. This is
    /// what removes the need for a separate dark-mode path.
    @Test("Detection is independent of light or dark background")
    func polarityIndependent() {
        let light = canvas(background: .white, strokes(ink: .black, seed: 7))
        let dark = canvas(background: .black, strokes(ink: .white, seed: 7))
        #expect(abs(InkAnalysis.inkCoverage(of: light) - InkAnalysis.inkCoverage(of: dark)) < 0.001)
    }
}

/// Deterministic randomness, so a stroke pattern that once caused a failure can
/// be reproduced exactly.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
