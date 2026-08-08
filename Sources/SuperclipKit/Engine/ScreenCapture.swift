import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case noDisplay
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Could not find the display to capture."
        case .failed(let reason): return "Capture failed: \(reason)"
        }
    }
}

/// Grabs a rectangle of the screen as an image.
@MainActor
enum ScreenCapture {

    /// Captures `globalRect` (screen coordinates, bottom-left origin) from `screen`
    /// at native pixel density. Superclip's own windows are excluded, so the
    /// selection overlay never ends up baked into the image.
    static func capture(globalRect: NSRect, on screen: NSScreen) async throws -> CGImage {
        guard let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID else {
            throw ScreenCaptureError.noDisplay
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.noDisplay
        }

        let ourApps = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: ourApps,
                                     exceptingWindows: [])

        // ScreenCaptureKit wants the rect in points relative to the display's
        // top-left corner; NSScreen hands us global bottom-left coordinates.
        let frame = screen.frame
        let sourceRect = CGRect(
            x: globalRect.minX - frame.minX,
            y: frame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )

        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = max(1, Int(sourceRect.width * scale))
        config.height = max(1, Int(sourceRect.height * scale))
        config.captureResolution = .best
        config.showsCursor = false
        config.scalesToFit = false

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                              configuration: config)
        } catch {
            throw ScreenCaptureError.failed(error.localizedDescription)
        }
    }

    /// PNG bytes, downscaled if needed to stay within the model's high-resolution
    /// image tier (2576px on the long edge). Anything larger is billed as more
    /// image tokens without adding readable detail.
    static func pngData(from image: CGImage, maxLongEdge: Int = 2576) -> Data? {
        let scaled = downscale(image, maxLongEdge: maxLongEdge) ?? image
        let rep = NSBitmapImageRep(cgImage: scaled)
        return rep.representation(using: .png, properties: [:])
    }

    private static func downscale(_ image: CGImage, maxLongEdge: Int) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxLongEdge else { return nil }

        let ratio = CGFloat(maxLongEdge) / CGFloat(longEdge)
        let width = Int((CGFloat(image.width) * ratio).rounded())
        let height = Int((CGFloat(image.height) * ratio).rounded())

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
