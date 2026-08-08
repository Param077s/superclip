import CoreGraphics

/// Orders on-screen elements the way a person reads a form: top to bottom, then
/// left to right within a row.
///
/// The obvious implementation — a comparator that treats two elements as the
/// same row when their y values are within some tolerance — is subtly broken.
/// With a tolerance of 12, y=0 ties with y=10 and y=10 ties with y=20, but y=0
/// sorts before y=20, so "equal" is not transitive. Swift's sort validates
/// strict weak ordering and traps on exactly this. Quantizing into row bands
/// first makes the relation transitive by construction.
enum ReadingOrder {

    /// Returns the input indices in reading order. Elements with no known frame
    /// keep their original relative order and go last, since nothing can be
    /// inferred about where they belong.
    static func sortedIndices(frames: [CGRect?], rowHeight: CGFloat = 12) -> [Int] {
        precondition(rowHeight > 0)

        struct Key {
            let band: Int
            let x: CGFloat
            let index: Int
        }

        let keys = frames.enumerated().map { index, frame -> Key in
            guard let frame else { return Key(band: .max, x: 0, index: index) }
            return Key(band: Int((frame.minY / rowHeight).rounded(.down)),
                       x: frame.minX,
                       index: index)
        }

        return keys.sorted { lhs, rhs in
            if lhs.band != rhs.band { return lhs.band < rhs.band }
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            return lhs.index < rhs.index // stable, and total
        }.map(\.index)
    }
}
