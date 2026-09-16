import AppKit
import CoreGraphics

/// Middle's own icon: a mouse seen from above with the middle button called out.
///
/// The shape is described once, as vectors, and used for both the menu bar item
/// and the `.icns` in the bundle — so the two cannot drift apart, and the menu
/// bar glyph needs no image assets at all. `Resources/make-icon.sh` renders the
/// iconset from here; see `--export-icon` in `main.swift`.
enum MiddleIcon {

    // MARK: - Menu bar

    /// Template image for the status item. `engaged` fills the body and leaves
    /// the middle button knocked out, which is what shows the button is
    /// currently held down. Both are built once and reused.
    static func statusBarImage(engaged: Bool) -> NSImage {
        engaged ? engagedStatusBarImage : idleStatusBarImage
    }

    private static let idleStatusBarImage = makeStatusBarImage(engaged: false)
    private static let engagedStatusBarImage = makeStatusBarImage(engaged: true)

    private static func makeStatusBarImage(engaged: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawGlyph(in: ctx, rect: rect, color: NSColor.black.cgColor, filled: engaged)
            return true
        }
        // Template: AppKit recolours it for light, dark and the highlighted menu.
        image.isTemplate = true
        image.accessibilityDescription = engaged ? "Middle (button held)" : "Middle"
        return image
    }

    // MARK: - App icon

    /// One square of the app icon, at a pixel size from the iconset.
    static func renderAppIcon(pixels: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setShouldAntialias(true)
        drawAppIcon(in: ctx, canvas: CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
        return ctx.makeImage()
    }

    /// Writes an `.iconset` directory for `iconutil`.
    static func exportIconset(to directory: URL) throws {
        // The ten sizes `iconutil` expects; @2x is the same art at twice the pixels.
        let sizes: [(name: String, pixels: Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, pixels) in sizes {
            guard let image = renderAppIcon(pixels: pixels),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    private static func drawAppIcon(in ctx: CGContext, canvas: CGRect) {
        // Big Sur proportions: the rounded square covers 80% of the canvas and
        // the rest is the margin the system expects to find empty.
        let plate = canvas.insetBy(dx: canvas.width * 0.10, dy: canvas.height * 0.10)
        let radius = plate.width * 0.225
        let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.addPath(platePath)
        ctx.clip()

        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(
            colorsSpace: space,
            colors: [CGColor(srgbRed: 0.42, green: 0.56, blue: 1.00, alpha: 1),
                     CGColor(srgbRed: 0.13, green: 0.24, blue: 0.78, alpha: 1)] as CFArray,
            locations: [0, 1]) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: plate.midX, y: plate.maxY),
                                   end: CGPoint(x: plate.midX, y: plate.minY),
                                   options: [])
        }

        // Soft light from above, so the plate does not read as flat paint.
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.13))
        ctx.fillEllipse(in: CGRect(x: plate.minX - plate.width * 0.25,
                                   y: plate.midY,
                                   width: plate.width * 1.5,
                                   height: plate.height * 1.1))
        ctx.restoreGState()

        let side = plate.width * 0.64
        let glyph = CGRect(x: plate.midX - side / 2, y: plate.midY - side / 2, width: side, height: side)
        drawGlyph(in: ctx, rect: glyph, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), filled: true)
    }

    // MARK: - The glyph

    /// The mouse, centred in `rect`: a capsule body, the split between the two
    /// buttons, and the middle button between them.
    ///
    /// `filled` inverts it — a solid body with the middle button knocked out —
    /// which is the one difference that still reads at menu bar size.
    private static func drawGlyph(in ctx: CGContext, rect: CGRect, color: CGColor, filled: Bool) {
        let side = min(rect.width, rect.height)
        let body = CGRect(x: rect.midX - side * 0.28, y: rect.midY - side * 0.42,
                          width: side * 0.56, height: side * 0.84)
        // A hair under one pixel of stroke turns to grey mush at 16×16.
        let line = max(side * 0.06, 1)
        let corner = body.width / 2
        // The split sits where the top curve begins, which is what makes the
        // three buttons read as buttons rather than as a divided rectangle.
        let split = body.maxY - corner
        let outline = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)

        let buttonWidth = body.width * 0.30
        let buttonHeight = corner * 0.86
        let button = CGRect(x: body.midX - buttonWidth / 2,
                            y: split + (corner - buttonHeight) / 2,
                            width: buttonWidth, height: buttonHeight)
        let buttonPath = CGPath(roundedRect: button,
                                cornerWidth: buttonWidth / 2, cornerHeight: buttonWidth / 2,
                                transform: nil)

        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(line)
        ctx.setLineJoin(.round)

        if filled {
            // Even-odd so the middle button stays a hole in the solid body.
            let path = CGMutablePath()
            path.addPath(outline)
            path.addPath(buttonPath)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.addPath(outline)
            ctx.strokePath()

            // Clipped to the body so the split stops at the outline rather than
            // crossing it.
            ctx.saveGState()
            ctx.addPath(outline)
            ctx.clip()
            ctx.move(to: CGPoint(x: body.minX, y: split))
            ctx.addLine(to: CGPoint(x: body.maxX, y: split))
            ctx.strokePath()
            ctx.restoreGState()

            ctx.addPath(buttonPath)
            ctx.strokePath()
        }

        ctx.restoreGState()
    }
}
