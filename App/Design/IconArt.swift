import AppKit

/// The glyph on the app icon, chosen in Settings. Each mark is a single flat
/// shape drawn in the 1024-point icon space, y up, centred on (512, 512) and
/// kept inside the central 600-point box, so it reads at 16 px in menus and
/// the Dock and can also be drawn on its own. Settings lists them in this
/// order, and the first is the bundled icon.
nonisolated enum AppMark: String, CaseIterable, Identifiable {
    case convergence, keystone, fold, focus

    static let key = "appMark"

    /// The default mark, before they choose one. The bundled icon is drawn
    /// from their choice at install (scripts/export-icon), else this.
    static var bundled: AppMark { allCases[0] }

    /// The chosen mark. A stored value that's no longer a mark, like the
    /// retired "steps" or "tide", falls back to the bundled one.
    static var current: AppMark {
        UserDefaults.standard.string(forKey: key).flatMap(AppMark.init(rawValue:)) ?? bundled
    }

    var id: String { rawValue }

    var name: String { rawValue.capitalized }

    /// The square of icon space that `IconArt.markImage` scales to fit.
    static let glyphBox = CGRect(x: 212, y: 212, width: 600, height: 600)

    /// The mark's outline. Each is built once: the knot's crossings take a
    /// few milliseconds, and Settings redraws every mark as the accent moves.
    var path: CGPath { Self.paths[self]! }

    /// CGPath is immutable, so one built here is safe to share across threads.
    private nonisolated(unsafe) static let paths = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.build()) })

    private func build() -> CGPath {
        switch self {
        case .convergence: Glyph.convergence()
        case .keystone: Glyph.keystone()
        case .fold: Glyph.fold()
        case .focus: Glyph.focus()
        }
    }
}

/// The geometry of each mark, in icon space around `center`.
private nonisolated enum Glyph {
    static let center = CGPoint(x: 512, y: 512)

    static func point(_ radius: CGFloat, _ angle: CGFloat, from origin: CGPoint = center) -> CGPoint {
        CGPoint(x: origin.x + radius * cos(angle), y: origin.y + radius * sin(angle))
    }

    static func offset(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: center.x + x, y: center.y + y)
    }

    static func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    static func stroke(_ path: CGPath, _ width: CGFloat, cap: CGLineCap = .butt) -> CGPath {
        path.copy(strokingWithWidth: width, lineCap: cap, lineJoin: .round, miterLimit: 4)
    }

    static func rotated(_ path: CGPath, by angle: CGFloat, around origin: CGPoint = center) -> CGPath {
        var transform = CGAffineTransform(translationX: origin.x, y: origin.y)
            .rotated(by: angle)
            .translatedBy(x: -origin.x, y: -origin.y)
        return path.copy(using: &transform) ?? path
    }

    static func union(_ paths: [CGPath]) -> CGPath {
        paths.dropFirst().reduce(paths[0]) { $0.union($1) }
    }

    // MARK: Marks

    /// Two families of three nested bands, measured from the design mockup: each
    /// band climbs from the lower left on a straight 45° run, then arcs over
    /// the top a quarter turn. The second family is the first turned half a
    /// turn, so its straight runs fall alongside the first family's cut ends:
    /// money, life and the future converging.
    static func convergence() -> CGPath {
        let band: CGFloat = 44, run: CGFloat = 192
        let hub = offset(-28, -47)
        let shape = CGMutablePath()
        for radius: CGFloat in [274, 192, 111] {
            let corner = point(radius, 3 * .pi / 4, from: hub)
            let line = CGMutablePath()
            line.move(to: CGPoint(x: corner.x - run * 0.7071, y: corner.y - run * 0.7071))
            line.addLine(to: corner)
            line.addArc(center: hub, radius: radius, startAngle: 3 * .pi / 4, endAngle: .pi / 4, clockwise: true)
            shape.addPath(stroke(line, band))
        }
        return shape.union(rotated(shape, by: .pi))
    }

    /// Two solid pieces locked around a square of open space, each with one
    /// corner cut at an angle.
    static func keystone() -> CGPath {
        let outer: CGFloat = 230, inner: CGFloat = 110, cut: CGFloat = 70
        let upper = polygon([
            offset(-outer, outer), offset(inner, outer), offset(inner, inner),
            offset(-inner, inner), offset(-inner, -inner), offset(-outer, -inner + cut)
        ])
        return union([upper, rotated(upper, by: .pi)])
    }

    /// One strip folding back on itself twice into an S, measured from the design
    /// mockup (traced at 3× in its own pixels). `foldParts` keeps the faces
    /// apart so the icon can shade them.
    static func fold() -> CGPath {
        let parts = foldParts()
        return union([parts.top, parts.underside, parts.bottom])
    }

    static func foldParts() -> (top: CGPath, underside: CGPath, bottom: CGPath) {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 512 + (x - 333) * 0.95, y: 512 + (347 - y) * 0.95) }
        /// A closed outline through `corners`, each rounded by its own radius.
        func outline(_ corners: [(CGPoint, CGFloat)]) -> CGPath {
            let path = CGMutablePath()
            let count = corners.count
            let last = corners[count - 1].0, first = corners[0].0
            path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
            for index in 0..<count {
                let (corner, radius) = corners[index]
                let next = corners[(index + 1) % count].0
                if radius > 0 {
                    path.addArc(tangent1End: corner, tangent2End: next, radius: radius * 0.95)
                } else {
                    path.addLine(to: corner)
                }
            }
            path.closeSubpath()
            return path
        }
        // The front of the top run, rising to the right; its left edge is the
        // first fold.
        let top = outline([(p(115, 140), 50), (p(510, 42), 35), (p(553, 198), 20), (p(125, 332), 6), (p(115, 332), 6)])
        // The back of the strip between the folds: from the curl at the left,
        // falling to the right fold, with background showing above and below it.
        let underside = outline([
            (p(115, 325), 0), (p(285, 283), 4), (p(545, 357), 4), (p(290, 432), 4),
            (p(135, 378), 30), (p(115, 350), 22)
        ])
        // The front of the bottom run; its right edge is the second fold.
        let bottom = outline([(p(545, 352), 20), (p(550, 555), 35), (p(165, 652), 40), (p(140, 472), 22)])
        return (top, underside, bottom)
    }

    /// Six thin nested contours, measured from the design mockup: the outer one
    /// a rounded diamond, each one in from it morphing toward a lopsided
    /// four-sided one, so the lines run evenly but no two are alike.
    static func focus() -> CGPath {
        let line: CGFloat = 9, rings = 6
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 512 + (x - 372) * 1.14, y: 512 + (372 - y) * 1.14) }
        // Matching corners, outside and in, with each corner's rounding.
        let outer: [(CGPoint, CGFloat)] = [(p(372, 58), 70), (p(688, 372), 70), (p(372, 688), 70), (p(58, 372), 70)]
        let inner: [(CGPoint, CGFloat)] = [(p(335, 205), 36), (p(556, 420), 44), (p(365, 548), 36), (p(200, 296), 32)]
        let shape = CGMutablePath()
        for ring in 0..<rings {
            let t = CGFloat(ring) / CGFloat(rings - 1)
            let corners = zip(outer, inner).map { o, i in
                (CGPoint(x: o.0.x + (i.0.x - o.0.x) * t, y: o.0.y + (i.0.y - o.0.y) * t), o.1 + (i.1 - o.1) * t)
            }
            let path = CGMutablePath()
            let first = corners[0].0, last = corners[corners.count - 1].0
            path.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
            for index in corners.indices {
                let (corner, radius) = corners[index]
                let next = corners[(index + 1) % corners.count].0
                if radius > 1 {
                    path.addArc(tangent1End: corner, tangent2End: next, radius: radius)
                } else {
                    path.addLine(to: corner)
                }
            }
            path.closeSubpath()
            shape.addPath(stroke(path, line))
        }
        return shape.union(shape)
    }
}

/// The app icon: the chosen mark in paper on an accent rounded square. Drawn
/// in code so it can follow the theme and the mark chosen in Settings.
nonisolated enum IconArt {
    static let paper = NSColor(srgbRed: 0xF7 / 255, green: 0xF5 / 255, blue: 0xF0 / 255, alpha: 1)

    static func image(accent: NSColor, mark: AppMark = .current, size: CGFloat = 1024) -> NSImage {
        let glyph = mark.path
        let fill = accent.cgColor
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, accent: fill, glyph: glyph, size: size)
            return true
        }
    }

    /// The icon drawn into `context`, `size` points square.
    private static func draw(in context: CGContext, accent: CGColor, glyph: CGPath, size: CGFloat) {
        let unit = size / 1024
        context.scaleBy(x: unit, y: unit)
        // Apple's macOS grid: an 824 pt rounded square centred on 1024.
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 24 * unit, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        context.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
        context.setFillColor(accent)
        context.fillPath()
        context.restoreGState()

        if glyph === AppMark.fold.path {
            drawFold(in: context)
            return
        }
        context.addPath(glyph)
        context.setFillColor(paper.cgColor)
        context.fillPath()
    }

    /// The fold, shaded like the design mockup: paper fronts that dim toward each
    /// fold, a cool blue-grey underside lit at the left fold, and a soft
    /// shadow where the bottom run passes under it.
    private static func drawFold(in context: CGContext) {
        let parts = Glyph.foldParts()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // CGColor directly: drawn off the main thread, where NSColor(hex:) can't be called.
        func color(_ hex: UInt32) -> CGColor {
            CGColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        func gradient(_ colors: [UInt32]) -> CGGradient {
            CGGradient(colorsSpace: space, colors: colors.map(color) as CFArray, locations: nil)!
        }
        func fill(_ path: CGPath, _ colors: [UInt32], from start: CGPoint, to end: CGPoint, shadow: Bool = false) {
            context.saveGState()
            if shadow {
                context.setShadow(
                    offset: CGSize(width: 0, height: -14), blur: 30,
                    color: CGColor(gray: 0, alpha: 0.45))
                context.addPath(path)
                context.setFillColor(color(colors[0]))
                context.fillPath()
            }
            context.addPath(path)
            context.clip()
            context.drawLinearGradient(gradient(colors), start: start, end: end, options: [])
            context.restoreGState()
        }
        let top = parts.top.boundingBoxOfPath, bottom = parts.bottom.boundingBoxOfPath
        let under = parts.underside.boundingBoxOfPath
        // Back to front: the bottom run, the underside, the top run, each
        // casting a soft shadow on what's behind it.
        fill(
            parts.bottom, [0xDCE1EC, 0xF4F6FA, 0xFFFFFF], from: CGPoint(x: bottom.minX, y: bottom.maxY),
            to: CGPoint(x: bottom.maxX, y: bottom.minY), shadow: true)
        fill(
            parts.underside, [0xFFFFFF, 0xE4E8F1, 0x9FADCC, 0x8193BD],
            from: CGPoint(x: under.minX, y: under.midY), to: CGPoint(x: under.maxX, y: under.midY))
        fill(
            parts.top, [0xE2E6EE, 0xF7F8FB, 0xFFFFFF], from: CGPoint(x: top.minX, y: top.minY),
            to: CGPoint(x: top.maxX, y: top.maxY), shadow: true)
    }

    /// The icon as an sRGB bitmap, `pixels` square. Safe off the main thread.
    static func bitmap(accent: CGColor, mark: AppMark, pixels: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        draw(in: context, accent: accent, glyph: mark.path, size: CGFloat(pixels))
        return context.makeImage()
    }

    /// The bare mark, with no background, scaled so its 600-point box fills `size`.
    static func markImage(mark: AppMark, color: NSColor, size: CGFloat) -> NSImage {
        let glyph = mark.path
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let box = AppMark.glyphBox
            context.scaleBy(x: size / box.width, y: size / box.height)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.addPath(glyph)
            context.setFillColor(color.cgColor)
            context.fillPath()
            return true
        }
        image.accessibilityDescription = mark.name
        return image
    }

    static func png(accent: NSColor, mark: AppMark = .bundled, pixels: Int) -> Data? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image(accent: accent, mark: mark, size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Shows the themed icon, with the chosen mark, in the Dock while Compass
    /// runs. Always drawn, even for the bundled look: falling back to the
    /// bundle can show a stale cached icon. macOS shows the bundled icon, drawn
    /// from the choice at the last install, in Finder and when Compass isn't running.
    @MainActor static func applyToDock(_ theme: AccentTheme) {
        applyToDock(accent: NSColor(hex: theme.light))
    }

    /// Drawn off the main thread, as a bitmap the size of the Dock's largest
    /// tile (256 points at 2x): handed the 1024-point drawing, AppKit blurred
    /// its shadow and converted its colours on the main thread, about 70 ms
    /// of every launch.
    @MainActor static func applyToDock(accent: NSColor) {
        dockGeneration += 1
        let generation = dockGeneration
        let fill = accent.cgColor
        let mark = AppMark.current
        Task.detached(priority: .userInitiated) {
            guard let bitmap = bitmap(accent: fill, mark: mark, pixels: dockPixels) else { return }
            await MainActor.run {
                // A newer choice may have been made while this one was drawn.
                guard generation == dockGeneration else { return }
                NSApp.applicationIconImage = NSImage(cgImage: bitmap, size: NSSize(width: dockPixels, height: dockPixels))
            }
        }
    }

    private static let dockPixels = 512
    @MainActor private static var dockGeneration = 0
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
