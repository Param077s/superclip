import CoreGraphics
import Testing
@testable import SuperclipKit

/// Reading order for form fields.
///
/// This exists because the obvious implementation — "same row if the y values
/// are within a tolerance" — is not transitive, and Swift's sort traps on
/// exactly that. The fuzz test is the important one: it is what would have
/// caught the crash before any real two-column form did.
@Suite("Reading order")
struct ReadingOrderTests {

    private func rect(_ x: CGFloat, _ y: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: 10, height: 10)
    }

    @Test("Reads a two-column form top to bottom, left to right")
    func twoColumnForm() {
        // Last name sits 4pt off First name — the staggering that breaks a
        // naive tolerance comparator.
        let frames: [CGRect?] = [
            rect(400, 203),  // 0 Ext
            rect(100, 200),  // 1 Phone
            rect(100, 150),  // 2 Email
            rect(400, 104),  // 3 Last name
            rect(100, 100)   // 4 First name
        ]
        #expect(ReadingOrder.sortedIndices(frames: frames) == [4, 3, 2, 1, 0])
    }

    @Test("The non-transitive chain does not trap and orders correctly")
    func nonTransitiveChain() {
        // y = 0, 10, 20 with a 12pt tolerance: 0 ties 10, 10 ties 20, 0 does not
        // tie 20. Quantizing into bands is what makes this well-defined.
        let frames: [CGRect?] = [rect(0, 20), rect(0, 0), rect(5, 10)]
        #expect(ReadingOrder.sortedIndices(frames: frames) == [1, 2, 0])
    }

    @Test("Elements with no frame go last, in their original order")
    func unknownFramesGoLast() {
        let frames: [CGRect?] = [nil, rect(0, 0), nil, rect(0, 50)]
        #expect(ReadingOrder.sortedIndices(frames: frames) == [1, 3, 0, 2])
    }

    @Test("Empty input is handled")
    func empty() {
        #expect(ReadingOrder.sortedIndices(frames: []).isEmpty)
    }

    @Test("Every random layout yields a valid permutation and never traps")
    func fuzz() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let count = Int.random(in: 0...40, using: &generator)
            let frames: [CGRect?] = (0..<count).map { _ in
                Bool.random(using: &generator)
                    ? nil
                    : rect(CGFloat(Int.random(in: 0...50, using: &generator)),
                           CGFloat(Int.random(in: 0...50, using: &generator)))
            }
            let order = ReadingOrder.sortedIndices(frames: frames)
            #expect(order.count == count)
            #expect(Set(order) == Set(0..<count))
        }
    }
}
