import AppKit
import CoreGraphics
import Foundation
import SuperclipKit

/// Draws Superclip's app icon and writes it out as an `.iconset`, plus contact
/// sheets for looking at the result honestly.
///
/// The icon is generated rather than drawn by hand so that it is reviewable: a
/// `.icns` in a repository is an opaque binary that nobody can diff, and the
/// only way to change it is to have whatever tool made it. This is the tool.
///
///     swift run IconGen iconset Resources/Superclip.iconset
///     swift run IconGen preview  <directory>
///
/// The mark itself is not defined here — it comes from `SuperclipMark` in the
/// app, so the icon and the menu bar cannot disagree about what Superclip
/// looks like.

// MARK: - Palette

/// Near-black rather than black: a pure black icon has no edge against a dark
/// Finder window, and the vertical shift gives the face somewhere to sit.
private let groundTop = CGColor(srgbRed: 0.118, green: 0.133, blue: 0.157, alpha: 1)
private let groundBottom = CGColor(srgbRed: 0.059, green: 0.067, blue: 0.078, alpha: 1)

/// A hairline of light around the inside of the shape. Not a glass effect —
/// it is the same trick every shipped macOS icon uses to keep its silhouette
/// from dissolving into a dark background.
private let rimLight = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07)

/// The three rays are the only colour in the entire app, and they are here
/// because they are the argument: one copy leaves as three different things.
/// They are chosen close in luminance so that at 16px, where the hues are gone,
/// the fan still reads as three strokes of equal weight rather than one bright
/// one and two smudges.
private let iconPalette = SuperclipMark.Palette(
    boundary: CGColor(srgbRed: 0.949, green: 0.957, blue: 0.965, alpha: 1),
    incoming: CGColor(srgbRed: 0.949, green: 0.957, blue: 0.965, alpha: 1),
    rays: [
        CGColor(srgbRed: 0.910, green: 0.682, blue: 0.294, alpha: 1),  // amber
        CGColor(srgbRed: 0.875, green: 0.894, blue: 0.918, alpha: 1),  // undeviated
        CGColor(srgbRed: 0.310, green: 0.702, blue: 0.675, alpha: 1),  // teal
    ]
)

// MARK: - Shape

/// The macOS icon silhouette, as a superellipse rather than a rounded rectangle.
///
/// A rounded rect joins a straight edge to a circular arc, and the curvature
/// jumps at the join — which is exactly the "not quite a Mac app" tell. Apple's
/// shape has continuous curvature. A superellipse with an exponent near 5 is
/// close enough to be indistinguishable at any size this icon is drawn, and it
/// is ten lines instead of a table of Bézier constants copied from somewhere.
private func superellipse(in rect: CGRect, exponent: CGFloat, samples: Int = 1024) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let power = 2 / exponent
    for step in 0...samples {
        let t = CGFloat(step) / CGFloat(samples) * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = CGPoint(
            x: rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), power),
            y: rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), power)
        )
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

// MARK: - The icon

/// Everything below is written in 1024pt coordinates and scaled at the end, so
/// the numbers match Apple's icon template as published.
private let canvas: CGFloat = 1024

/// 824 inside 1024 is the standard proportion. The 100pt margin is not padding
/// for its own sake — it is the room the baked shadow needs.
private let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)

/// How much of the body the mark takes up, and how much its strokes are
/// fattened, at each size the set is drawn at.
///
/// Neither number is constant, because a faithful reduction of the large icon
/// is not a small icon. At 16px the whole body is thirteen pixels; the three
/// rays have to be separated by something a pixel grid can actually represent,
/// so the mark grows into the margin and its ink roughly doubles. Apple's own
/// icons do the same thing, and the alternative is a smear that happens to be
/// geometrically correct.
private func treatment(forPixels pixels: Int) -> (coverage: CGFloat, weight: CGFloat) {
    switch pixels {
    case ...16:  return (0.90, 1.85)
    case ...32:  return (0.83, 1.35)
    case ...64:  return (0.79, 1.15)
    case ...128: return (0.77, 1.06)
    default:     return (0.76, 1.00)
    }
}

private func drawAppIcon(in ctx: CGContext, pixels: Int) {
    ctx.saveGState()
    defer { ctx.restoreGState() }

    let scale = CGFloat(pixels) / canvas
    ctx.scaleBy(x: scale, y: scale)

    let shape = superellipse(in: bodyRect, exponent: 5)

    // The shadow is cast off a flat fill and then switched off, so it does not
    // also get applied to the gradient, the rim, and every stroke of the mark.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -10),
        blur: 22,
        color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.22)
    )
    ctx.addPath(shape)
    ctx.setFillColor(groundBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [groundTop, groundBottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: bodyRect.maxY),
        end: CGPoint(x: 0, y: bodyRect.minY),
        options: []
    )
    // Stroked while clipped, so only the inner half of the line survives and the
    // silhouette stays exactly the superellipse.
    ctx.addPath(shape)
    ctx.setStrokeColor(rimLight)
    ctx.setLineWidth(10)
    ctx.strokePath()
    ctx.restoreGState()

    let treatment = treatment(forPixels: pixels)
    let side = bodyRect.width * treatment.coverage
    SuperclipMark.draw(
        .idle,
        in: ctx,
        fitting: CGRect(
            x: bodyRect.midX - side / 2, y: bodyRect.midY - side / 2,
            width: side, height: side
        ),
        palette: iconPalette,
        weight: treatment.weight
    )
}

// MARK: - Rasterising

private func bitmap(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    body(ctx)
    return ctx.makeImage()!
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

// MARK: - iconset

/// The ten members `iconutil` expects. Every one is drawn at its true pixel
/// size rather than downscaled from 1024, which is the only way the small ones
/// get their heavier ink.
private let iconsetMembers: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

private func writeIconset(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for member in iconsetMembers {
        let image = bitmap(width: member.pixels, height: member.pixels) {
            drawAppIcon(in: $0, pixels: member.pixels)
        }
        try writePNG(image, to: directory.appendingPathComponent("\(member.name).png"))
        print("   \(member.name).png  (\(member.pixels)px)")
    }
}

// MARK: - Contact sheets

private func label(_ text: String, at point: CGPoint, in ctx: CGContext, size: CGFloat = 11) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    (text as NSString).draw(at: point, withAttributes: [
        .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
        .foregroundColor: NSColor(white: 0.45, alpha: 1),
    ])
    NSGraphicsContext.restoreGraphicsState()
}

/// Every cell is rendered at its true pixel size and then blown up with
/// interpolation switched off. Smoothing the enlargement would hide precisely
/// the thing being checked — whether a 1px stroke landed on a pixel or between
/// two of them.
private func drawMagnified(_ image: CGImage, at origin: CGPoint, zoom: CGFloat, in ctx: CGContext) {
    ctx.saveGState()
    ctx.interpolationQuality = .none
    ctx.setShouldAntialias(false)
    ctx.draw(image, in: CGRect(
        x: origin.x, y: origin.y,
        width: CGFloat(image.width) * zoom, height: CGFloat(image.height) * zoom
    ))
    ctx.restoreGState()
}

/// The three menu bar states, on both menu bar appearances, at the sizes macOS
/// will actually ask for. A template image is a mask that the system tints, so
/// the preview tints it the same way rather than pretending it is black art.
private func writeMenuBarSheet(to url: URL) throws {
    let states: [(SuperclipMark.State, String)] = [
        (.idle, "idle"), (.holding, "holding"), (.collecting, "collecting"),
    ]
    let backdrops: [(name: String, ground: CGColor, ink: CGColor)] = [
        ("light menu bar", CGColor(gray: 0.94, alpha: 1), CGColor(gray: 0.08, alpha: 1)),
        ("dark menu bar", CGColor(gray: 0.13, alpha: 1), CGColor(gray: 0.97, alpha: 1)),
        // What macOS shows while the menu is open: the tint inverts against the
        // selection fill, and a mark that only works one way round shows up here.
        ("menu open", CGColor(srgbRed: 0.16, green: 0.42, blue: 0.90, alpha: 1),
         CGColor(gray: 1, alpha: 1)),
    ]
    let sizes = [16, 18, 36]  // 1x menu bar, 1x maximum, and 18pt on a retina display
    let zoom: CGFloat = 5
    let gutter: CGFloat = 16
    let labelColumn: CGFloat = 150
    let cell = CGFloat(sizes.max()!) * zoom + gutter

    // States are columns so they can be compared without moving the eye far —
    // telling them apart at a glance is the whole requirement.
    let width = Int(labelColumn + CGFloat(states.count) * cell + gutter)
    let rowHeights = backdrops.flatMap { _ in sizes.map { CGFloat($0) * zoom + 26 } }
    let height = Int(rowHeights.reduce(0, +) + gutter * 2 + 20)

    let sheet = bitmap(width: width, height: height) { ctx in
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var x = labelColumn
        for (_, name) in states {
            label(name, at: CGPoint(x: x, y: CGFloat(height) - gutter - 12), in: ctx)
            x += cell
        }

        var y = CGFloat(height) - gutter - 20
        for backdrop in backdrops {
            for size in sizes {
                let rowHeight = CGFloat(size) * zoom + 26
                y -= rowHeight
                label(
                    "\(size)px · \(backdrop.name)",
                    at: CGPoint(x: gutter, y: y + rowHeight / 2 - 6), in: ctx, size: 10
                )
                var x = labelColumn
                for (state, _) in states {
                    let tile = bitmap(width: size, height: size) { tileCtx in
                        tileCtx.setFillColor(backdrop.ground)
                        tileCtx.fill(CGRect(x: 0, y: 0, width: size, height: size))
                        SuperclipMark.draw(
                            state, in: tileCtx,
                            fitting: CGRect(x: 0, y: 0, width: size, height: size),
                            palette: SuperclipMark.Palette(
                                boundary: backdrop.ink, incoming: backdrop.ink,
                                rays: Array(repeating: backdrop.ink, count: 3)
                            )
                        )
                    }
                    drawMagnified(tile, at: CGPoint(x: x, y: y + 13), zoom: zoom, in: ctx)
                    x += cell
                }
            }
        }
    }
    try writePNG(sheet, to: url)
}

/// The app icon at the sizes that matter, on a grey that is neither of the two
/// Finder backgrounds so neither one flatters it.
private func writeIconSheet(to url: URL) throws {
    let magnified = [16, 32, 64]
    let actual = [128, 256, 512]
    let zoom: CGFloat = 5
    let gutter: CGFloat = 24

    let topRowHeight = CGFloat(magnified.max()!) * zoom
    let width = Int(gutter * 2 + max(
        CGFloat(magnified.reduce(0) { $0 + CGFloat($1) * zoom + gutter }),
        CGFloat(actual.reduce(0) { $0 + CGFloat($1) + gutter })
    ))
    let height = Int(gutter * 3 + topRowHeight + CGFloat(actual.max()!) + 40)

    let sheet = bitmap(width: width, height: height) { ctx in
        ctx.setFillColor(CGColor(gray: 0.62, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var x = gutter
        let topY = CGFloat(height) - gutter - topRowHeight
        for size in magnified {
            let image = bitmap(width: size, height: size) { drawAppIcon(in: $0, pixels: size) }
            drawMagnified(image, at: CGPoint(x: x, y: topY), zoom: zoom, in: ctx)
            label("\(size)px ×5", at: CGPoint(x: x, y: topY - 16), in: ctx, size: 10)
            x += CGFloat(size) * zoom + gutter
        }

        x = gutter
        for size in actual {
            let image = bitmap(width: size, height: size) { drawAppIcon(in: $0, pixels: size) }
            ctx.draw(image, in: CGRect(x: x, y: gutter, width: CGFloat(size), height: CGFloat(size)))
            x += CGFloat(size) + gutter
        }
    }
    try writePNG(sheet, to: url)
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
let usage = """
usage: IconGen iconset <directory>
       IconGen preview <directory>
"""

guard arguments.count == 2 else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}

let destination = URL(fileURLWithPath: arguments[1])

do {
    switch arguments[0] {
    case "iconset":
        try writeIconset(to: destination)
    case "preview":
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try writeMenuBarSheet(to: destination.appendingPathComponent("menu-bar.png"))
        try writeIconSheet(to: destination.appendingPathComponent("app-icon.png"))
        print("   \(destination.path)/menu-bar.png")
        print("   \(destination.path)/app-icon.png")
    default:
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("IconGen: \(error)\n".utf8))
    exit(1)
}
