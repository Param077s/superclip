import AppKit
import Testing
@testable import SuperclipKit

/// The menu bar icon, checked by rasterising it and counting pixels.
///
/// None of this can be seen from a screenshot — a status item cannot be
/// captured without Screen Recording, and by the time anyone notices the icon
/// is wrong it has been wrong for a while. These are pointed at the two ways it
/// fails silently: a mark that is not a template image, which is invisible on
/// one of the two menu bar appearances, and two states that look the same, which
/// makes "am I still collecting?" unanswerable.
@Suite("Menu bar mark")
struct MarkTests {

    /// Drawn at 36px: an 18pt status item on a retina display, which is what
    /// nearly every Mac in use actually renders.
    private static let raster = 36

    /// Alpha at every pixel, row-major, in `raster × raster`.
    private func coverage(of state: SuperclipMark.State) -> [UInt8] {
        let side = Self.raster
        let context = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        SuperclipMark.draw(
            state, in: context,
            fitting: CGRect(x: 0, y: 0, width: side, height: side)
        )
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: side * side * 4)
        return (0..<(side * side)).map { pixels[$0 * 4 + 3] }
    }

    private func inkedPixels(_ state: SuperclipMark.State) -> Int {
        coverage(of: state).count { $0 > 127 }
    }

    @Test("Every state is a template image")
    func statesAreTemplates() {
        // Not cosmetic. macOS tints a template's alpha to suit the menu bar and
        // inverts it while the menu is open; a non-template image is drawn as-is
        // and disappears against one appearance or the other.
        for state in [SuperclipMark.State.idle, .holding, .collecting] {
            #expect(SuperclipMark.menuBarImage(state).isTemplate)
        }
    }

    @Test("Every state draws something")
    func statesDrawInk() {
        for state in [SuperclipMark.State.idle, .holding, .collecting] {
            #expect(inkedPixels(state) > 40)
        }
    }

    @Test("Nothing is clipped by the edge of the image")
    func markStaysInsideItsBox() {
        // The mark is designed with roughly a point of margin all round. If a
        // geometry change eats that, the result is not an error — it is a mark
        // with a shaved edge that looks like a rendering bug.
        let side = Self.raster
        for state in [SuperclipMark.State.idle, .holding, .collecting] {
            let alpha = coverage(of: state)
            for index in 0..<(side * side) {
                let (row, column) = (index / side, index % side)
                let onBorder = row == 0 || column == 0 || row == side - 1 || column == side - 1
                if onBorder {
                    #expect(alpha[index] == 0, "state \(state) touches the image edge")
                }
            }
        }
    }

    @Test("The three states are told apart by weight, not by detail")
    func statesDifferAtAGlance() {
        let idle = inkedPixels(.idle)
        let holding = inkedPixels(.holding)
        let collecting = inkedPixels(.collecting)

        // Collecting fills in exactly the box the closed fan occupies, so it is
        // unambiguously the heaviest — that is the whole signal.
        #expect(collecting > holding)
        #expect(collecting > idle)

        // A quarter more ink is about where a difference survives being seen out
        // of the corner of an eye rather than looked at.
        #expect(Double(collecting) / Double(holding) > 1.25)

        // Idle and holding are close in weight on purpose, so they are separated
        // by shape instead: the open fan spreads over far more rows than the
        // flat stack does.
        #expect(fanRows(.idle) > fanRows(.holding) + 6)
    }

    /// How many scanlines the mark occupies to the right of the boundary — a
    /// cheap proxy for the fan's silhouette.
    ///
    /// Measured only over that half deliberately. The boundary and the incoming
    /// bar are identical in all three states and the boundary is the tallest
    /// thing in the mark, so counting the full width reports the same number
    /// every time and would pass no matter what the fan did.
    private func fanRows(_ state: SuperclipMark.State) -> Int {
        let side = Self.raster
        let alpha = coverage(of: state)
        let fanBegins = Int(Double(side) * 0.55)
        return (0..<side).count { row in
            (fanBegins..<side).contains { alpha[row * side + $0] > 127 }
        }
    }
}
