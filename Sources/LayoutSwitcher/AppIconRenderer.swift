import Cocoa

/// Renders the MacKeySwitch app icon — matches the CombinedFlagIcon shown in Settings → About.
/// The design: Ukrainian flag background, Union Jack clipped to the top-left triangle,
/// a white diagonal divider, a keyboard glyph in the center.
enum AppIconRenderer {
    private static let uaBlue = NSColor(red: 0.00, green: 0.35, blue: 0.73, alpha: 1.0)
    private static let uaYellow = NSColor(red: 1.00, green: 0.84, blue: 0.00, alpha: 1.0)
    private static let ukNavy = NSColor(red: 0.00, green: 0.13, blue: 0.40, alpha: 1.0)
    private static let ukRed = NSColor(red: 0.81, green: 0.06, blue: 0.13, alpha: 1.0)

    /// Produce a square NSImage at the requested pixel size.
    static func makeAppIcon(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        // Icon is centered with some padding — matches the CombinedFlagIcon proportions
        // (flag height ≈ 0.67 of icon width; icon is rounded-square).
        let padding = size * 0.08
        let innerSize = size - padding * 2
        let flagHeight = innerSize * 0.67
        let flagY = (size - flagHeight) / 2
        let flagRect = NSRect(x: padding, y: flagY, width: innerSize, height: flagHeight)

        // Rounded-square mask
        let cornerRadius = innerSize * 0.06
        let clip = NSBezierPath(roundedRect: flagRect, xRadius: cornerRadius, yRadius: cornerRadius)
        clip.addClip()

        // --- Ukrainian flag (background) ---
        // Top half: blue, bottom half: yellow. In flipped-no NSImage coords, y=0 is bottom.
        uaBlue.setFill()
        NSRect(x: flagRect.minX, y: flagRect.midY, width: flagRect.width, height: flagRect.height / 2).fill()
        uaYellow.setFill()
        NSRect(x: flagRect.minX, y: flagRect.minY, width: flagRect.width, height: flagRect.height / 2).fill()

        // --- Union Jack clipped to top-left triangle ---
        ctx.saveGState()
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: flagRect.minX, y: flagRect.maxY))
        triangle.line(to: NSPoint(x: flagRect.maxX, y: flagRect.maxY))
        triangle.line(to: NSPoint(x: flagRect.minX, y: flagRect.minY))
        triangle.close()
        triangle.addClip()
        drawUnionJack(in: flagRect)
        ctx.restoreGState()

        // --- White diagonal divider from top-right to bottom-left ---
        NSColor.white.setStroke()
        let divider = NSBezierPath()
        divider.lineWidth = max(2.0, size * 0.012)
        divider.move(to: NSPoint(x: flagRect.maxX, y: flagRect.maxY))
        divider.line(to: NSPoint(x: flagRect.minX, y: flagRect.minY))
        divider.stroke()

        // --- Keyboard glyph in the center ---
        if let kb = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.18, weight: .semibold)
            let configured = kb.withSymbolConfiguration(config) ?? kb
            let glyphSize = NSSize(width: size * 0.32, height: size * 0.32 * 0.75)
            let glyphRect = NSRect(
                x: flagRect.midX - glyphSize.width / 2,
                y: flagRect.midY - glyphSize.height / 2,
                width: glyphSize.width,
                height: glyphSize.height
            )
            // Draw soft shadow
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2.0,
                          color: NSColor.black.withAlphaComponent(0.7).cgColor)
            // Tint white by drawing as template
            configured.isTemplate = true
            NSColor.white.set()
            configured.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1.0,
                            respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            ctx.restoreGState()
        }

        // Border around the flag rect (inside the current clip, so it hugs the rounded corners)
        NSColor.gray.withAlphaComponent(0.4).setStroke()
        let border = NSBezierPath(roundedRect: flagRect, xRadius: cornerRadius, yRadius: cornerRadius)
        border.lineWidth = max(1.0, size * 0.004)
        border.stroke()

        return image
    }

    /// Simplified Union Jack filling the given rect.
    private static func drawUnionJack(in rect: NSRect) {
        // Navy background
        ukNavy.setFill()
        NSBezierPath(rect: rect).fill()

        // White diagonals (saltire) — two thick white lines
        NSColor.white.setStroke()
        let whiteDiag = NSBezierPath()
        whiteDiag.lineWidth = rect.height * 0.18
        whiteDiag.move(to: NSPoint(x: rect.minX, y: rect.minY))
        whiteDiag.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        whiteDiag.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        whiteDiag.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        whiteDiag.stroke()

        // Red diagonals (thinner, inside white)
        ukRed.setStroke()
        let redDiag = NSBezierPath()
        redDiag.lineWidth = rect.height * 0.08
        redDiag.move(to: NSPoint(x: rect.minX, y: rect.minY))
        redDiag.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        redDiag.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        redDiag.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        redDiag.stroke()

        // White cross (horizontal + vertical bars)
        NSColor.white.setFill()
        let horizH = rect.height * 0.28
        let vertW = rect.width * 0.22
        NSRect(x: rect.minX, y: rect.midY - horizH / 2, width: rect.width, height: horizH).fill()
        NSRect(x: rect.midX - vertW / 2, y: rect.minY, width: vertW, height: rect.height).fill()

        // Red cross (thinner, inside white)
        ukRed.setFill()
        let rH = rect.height * 0.18
        let rW = rect.width * 0.13
        NSRect(x: rect.minX, y: rect.midY - rH / 2, width: rect.width, height: rH).fill()
        NSRect(x: rect.midX - rW / 2, y: rect.minY, width: rW, height: rect.height).fill()
    }

    /// Write a PNG of the icon at the given size to `url`. Returns true on success.
    @discardableResult
    static func writePNG(size: CGFloat, to url: URL) -> Bool {
        let image = makeAppIcon(size: size)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try png.write(to: url)
            return true
        } catch {
            print("[MacKeySwitch] Failed to write PNG: \(error)")
            return false
        }
    }

    /// The (filename, pixel size) pairs `iconutil` expects inside an `.iconset` directory.
    private static let iconSetVariants: [(name: String, size: CGFloat)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    /// Populate an `.iconset` directory, so the build script can turn it into the `.icns`
    /// the bundle ships. The icon is drawn from the same code as the About tab, which is
    /// why it is generated here rather than checked in as a binary that can drift.
    static func writeIconSet(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for variant in iconSetVariants {
            let url = directory.appendingPathComponent("\(variant.name).png")
            guard writePNG(size: variant.size, to: url) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }
}
