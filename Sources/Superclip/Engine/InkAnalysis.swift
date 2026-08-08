import CoreGraphics
import Foundation

/// Decides, on-device and in about a millisecond, what kind of thing a captured
/// region contains.
///
/// This exists to answer one routing question: when Vision comes back with
/// nothing, is that because the region is blank — in which case spending a model
/// call is pure waste — or because there are marks on it that Vision could not
/// read, which is what handwriting looks like from the OCR engine's side.
///
/// The signal is deliberately crude. Ink coverage measures how much of the
/// region deviates from its own background, which works on a white page, a dark
/// scan, and an inverted screenshot alike, and does not care what the marks are.
enum InkAnalysis {

    enum Content: String {
        /// Vision read it confidently. No model call needed.
        case printed
        /// Marks are present that Vision could not resolve.
        case handwritten
        /// Nothing meaningful in the region.
        case blank
    }

    struct Result {
        let content: Content
        /// Fraction of pixels that differ from the background, 0…1.
        let inkCoverage: Double
    }

    /// Below this, a region is background and whatever specks remain are noise.
    ///
    /// Set deliberately low, because the two ways of being wrong here are not
    /// equally bad. Calling a photo "handwritten" costs one model call that comes
    /// back empty. Calling faint writing "blank" refuses the user outright and
    /// looks like the feature is broken. So the threshold sits just above sensor
    /// and compression noise rather than anywhere near a judgement call.
    private static let blankThreshold = 0.0005
    /// How far a pixel must sit from the median to count as a mark.
    private static let inkDelta = 0.22

    static func classify(image: CGImage, ocr: TextRecognizer.Result) -> Result {
        // Vision is the authority when it is sure. It is fast, free, and offline,
        // and nothing downstream improves on a confident read.
        if ocr.isTrustworthy {
            return Result(content: .printed, inkCoverage: 1)
        }

        let coverage = inkCoverage(of: image)
        if coverage < blankThreshold && ocr.isEmpty {
            return Result(content: .blank, inkCoverage: coverage)
        }
        return Result(content: .handwritten, inkCoverage: coverage)
    }

    /// Fraction of pixels whose luminance differs from the region's median by
    /// more than `inkDelta`. Using the median as the reference — rather than
    /// assuming a light background — is what makes this work on dark scans and
    /// dark-mode screenshots without a separate code path.
    /// 320 rather than something smaller because the thing most likely to be
    /// missed is a small amount of real writing inside a large selection, and
    /// resolution is what decides whether those few strokes survive sampling.
    /// The cost is a ~50KB greyscale draw, which is not worth optimizing.
    static func inkCoverage(of image: CGImage, sampleWidth: Int = 320) -> Double {
        guard let samples = luminanceSamples(of: image, sampleWidth: sampleWidth),
              !samples.isEmpty else { return 0 }

        let sorted = samples.sorted()
        let median = Double(sorted[sorted.count / 2]) / 255.0

        let marks = samples.reduce(into: 0) { count, sample in
            if abs(Double(sample) / 255.0 - median) > inkDelta { count += 1 }
        }
        return Double(marks) / Double(samples.count)
    }

    /// Draws the image small and grey, and hands back the raw luminance bytes.
    private static func luminanceSamples(of image: CGImage, sampleWidth: Int) -> [UInt8]? {
        let width = min(sampleWidth, image.width)
        guard width > 0, image.height > 0 else { return nil }
        let height = max(1, Int((Double(image.height) / Double(image.width) * Double(width)).rounded()))

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height)
        return Array(UnsafeBufferPointer(start: buffer, count: width * height))
    }
}
