import AppKit
import CoreGraphics

/// The Superclip mark, defined once as geometry rather than shipped as pixels.
///
/// The mark is a refraction: one thick bar arrives at a boundary and three
/// thinner ones leave it, spreading apart. That is the product in a drawing —
/// one copy, three correct outputs, and the boundary is the destination app
/// deciding which output you get.
///
/// It lives here, in the app, because the menu bar needs it at runtime and the
/// icon generator needs the identical shape at 1024pt. Two copies of geometry
/// drift the moment either is touched, and a menu bar icon that no longer
/// matches the app icon is worse than either one being slightly wrong.
///
/// Everything below is expressed in an 18×18 design box — the largest art Apple
/// recommends for a menu bar item — and mapped into whatever rect it is asked
/// to fill. Working in fixed design units means the proportions are readable as
/// written, and the same numbers describe an 18pt status item and a 1024px icon.
public enum SuperclipMark {

    /// What the status item is reporting. The boundary and the incoming bar are
    /// identical in all three, so the mark stays recognisably the same app; only
    /// what leaves the boundary changes, and it changes by a lot.
    public enum State {
        /// Nothing held. The fan is open — copies are flowing straight through.
        case idle
        /// The stack holds items. The fan closes into a stack of parallel bars:
        /// collected, not yet dispersed.
        case holding
        /// Actively collecting. The bars merge into one solid slab, because
        /// "am I still collecting?" has to be answerable from the corner of an
        /// eye, and filled-versus-not is the only difference that survives that.
        case collecting
    }

    /// Ink for each part of the mark. The menu bar only ever uses `.template`
    /// (macOS keeps the alpha and throws the colour away), but the app icon
    /// tints the three outgoing rays differently — that is the whole point of
    /// them, and 1024px is the one place there is room to say it.
    public struct Palette {
        public var boundary: CGColor
        public var incoming: CGColor
        /// Exactly three, ordered top to bottom.
        public var rays: [CGColor]

        public init(boundary: CGColor, incoming: CGColor, rays: [CGColor]) {
            precondition(rays.count == 3, "the mark has exactly three outgoing rays")
            self.boundary = boundary
            self.incoming = incoming
            self.rays = rays
        }

        /// Flat black. Template images are masks, so only the coverage matters.
        public static let template = Palette(
            boundary: CGColor(gray: 0, alpha: 1),
            incoming: CGColor(gray: 0, alpha: 1),
            rays: Array(repeating: CGColor(gray: 0, alpha: 1), count: 3)
        )
    }

    // MARK: - Geometry, in an 18×18 design box

    /// The side of the design box. Not the size anything is drawn at.
    public static let designBox: CGFloat = 18

    /// The boundary: the surface the copy hits. It sits left of centre because
    /// the fan is the part worth looking at and wants the room; a boundary in
    /// the middle splits the mark into two equal halves and reads as a plus.
    ///
    /// Its height is set by the fan rather than by the box: tall enough to
    /// contain the outermost rays and no taller. A boundary that overshoots them
    /// stops reading as a surface the rays leave and starts reading as the long
    /// arm of a cross, which is the wrong picture entirely.
    private static let boundaryX: CGFloat = 6.3
    private static let boundaryBottom: CGFloat = 3.4
    private static let boundaryTop: CGFloat = 14.6

    /// The line the incoming bar and the middle ray share.
    private static let axis: CGFloat = 9.0

    private static let incomingStartX: CGFloat = 1.9

    /// The rays start well clear of the boundary rather than touching it, for
    /// two reasons. Three lines converging on a point fill in below about 20pt
    /// and the fan becomes a blob. And the middle ray is collinear with the
    /// incoming bar — physically right, it is the undeviated one — so without a
    /// frank gap the two join into a single horizontal that crosses the boundary
    /// and the whole mark reads as a plus sign.
    private static let rayStartX: CGFloat = 9.4
    private static let rayEndX: CGFloat = 16.3

    /// How far the outer rays sit off the axis where they begin, and where they
    /// end. The spread more than doubles over the length of the ray, which is
    /// what makes it read as diverging rather than as three parallel lines.
    ///
    /// The starting spread is also what separates the three bars in the holding
    /// state, and that is the binding constraint: any tighter and on a
    /// non-retina menu bar the gaps between them fall under a pixel, the bars
    /// merge, and holding becomes indistinguishable from collecting.
    private static let raySpreadAtStart: CGFloat = 2.5
    private static let raySpreadAtEnd: CGFloat = 5.4

    /// The incoming bar is the heaviest stroke and the rays the lightest. One
    /// thick line becoming three thin ones carries the direction of the whole
    /// mark without needing an arrowhead. The absolute weights are held down to
    /// roughly what SF Symbols use at this size — heavier than that and the
    /// mark stops looking like it belongs in a menu bar.
    private static let boundaryStroke: CGFloat = 1.4
    private static let incomingStroke: CGFloat = 1.5
    private static let rayStroke: CGFloat = 1.1

    // MARK: - Drawing

    /// Draw the mark into `rect`, preserving the design box's aspect.
    ///
    /// `weight` multiplies every stroke. Below roughly 32px a stroke scaled
    /// honestly lands under one pixel and the anti-aliasing turns it grey, so
    /// the small members of an icon set are drawn deliberately fatter than the
    /// large ones. That is normal icon work, not a fudge.
    public static func draw(
        _ state: State,
        in ctx: CGContext,
        fitting rect: CGRect,
        palette: Palette = .template,
        weight: CGFloat = 1
    ) {
        let scale = min(rect.width, rect.height) / designBox

        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -designBox / 2, y: -designBox / 2)
        ctx.setLineCap(.round)

        ctx.setStrokeColor(palette.boundary)
        ctx.setLineWidth(boundaryStroke * weight)
        ctx.move(to: CGPoint(x: boundaryX, y: boundaryBottom))
        ctx.addLine(to: CGPoint(x: boundaryX, y: boundaryTop))
        ctx.strokePath()

        ctx.setStrokeColor(palette.incoming)
        ctx.setLineWidth(incomingStroke * weight)
        ctx.move(to: CGPoint(x: incomingStartX, y: axis))
        ctx.addLine(to: CGPoint(x: boundaryX, y: axis))
        ctx.strokePath()

        switch state {
        case .idle:
            drawRays(in: ctx, palette: palette, weight: weight, spreadAtEnd: raySpreadAtEnd)
        case .holding:
            // The same three rays, laid flat. Identical start points, so the
            // transition from idle reads as the fan closing rather than as a
            // different picture.
            drawRays(in: ctx, palette: palette, weight: weight, spreadAtEnd: raySpreadAtStart)
        case .collecting:
            let halfHeight = raySpreadAtStart + rayStroke * weight / 2
            let slab = CGRect(
                x: rayStartX - rayStroke * weight / 2,
                y: axis - halfHeight,
                width: rayEndX - rayStartX + rayStroke * weight,
                height: halfHeight * 2
            )
            // The slab is exactly the box the closed fan occupies, so switching
            // collection on fills in what was already there instead of moving it.
            ctx.setFillColor(palette.rays[1])
            ctx.addPath(CGPath(
                roundedRect: slab, cornerWidth: 1.0, cornerHeight: 1.0, transform: nil
            ))
            ctx.fillPath()
        }
    }

    private static func drawRays(
        in ctx: CGContext, palette: Palette, weight: CGFloat, spreadAtEnd: CGFloat
    ) {
        ctx.setLineWidth(rayStroke * weight)
        for (index, colour) in palette.rays.enumerated() {
            let side = CGFloat(1 - index)  // +1 top, 0 middle, -1 bottom
            ctx.setStrokeColor(colour)
            ctx.move(to: CGPoint(x: rayStartX, y: axis + side * raySpreadAtStart))
            ctx.addLine(to: CGPoint(x: rayEndX, y: axis + side * spreadAtEnd))
            ctx.strokePath()
        }
    }

    // MARK: - Menu bar

    /// A template image of the mark for the status item.
    ///
    /// Template is not optional here: macOS discards the colour and re-tints the
    /// alpha, which is what makes the icon black on a light menu bar, white on a
    /// dark one, and inverted while the menu is open. A non-template image gets
    /// none of that and is invisible in one of the two appearances.
    ///
    /// The image draws from a handler rather than being rasterised once, so it
    /// is redrawn at whatever backing scale the display actually has instead of
    /// being a 2x bitmap resampled onto something else.
    public static func menuBarImage(_ state: State) -> NSImage {
        let image = NSImage(
            size: NSSize(width: designBox, height: designBox), flipped: false
        ) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(state, in: ctx, fitting: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityDescription
        return image
    }
}

extension SuperclipMark.State {
    /// VoiceOver reads the status item, and "Superclip" alone would not say the
    /// one thing the icon exists to say.
    var accessibilityDescription: String {
        switch self {
        case .idle:       return "Superclip"
        case .holding:    return "Superclip — copy stack holding items"
        case .collecting: return "Superclip — collecting"
        }
    }
}
