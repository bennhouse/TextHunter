import Cocoa
// TextHunter icon, in the style of Scene: graphite squircle, opaque light materials with a soft
// gradient, a bright top edge, short soft shadows and a faint grain. The motif is the menu bar
// symbol, a viewfinder (four corner brackets) framing three lines of text, drawn by hand.
// Usage: swift scripts/make-icon.swift <folder>  →  <folder>/AppIcon.iconset (+ icon-preview.png)
let out = CommandLine.arguments[1]
let set = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// macOS icon shape: rectangle with continuous corners, 824×824 on 1024 with radius ≈ 22.5%.
func squirclePath(_ r: CGRect) -> CGPath {
    let R = min(r.width, r.height) * 0.225
    let p = CGMutablePath()
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: r.maxX, y: r.minY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: r.minX, y: r.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: r.minX, y: r.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
    ]
    for (i, (c, d1, d2)) in corners.enumerated() {
        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: c.x - d1.dx * u * R + d2.dx * v * R, y: c.y - d1.dy * u * R + d2.dy * v * R)
        }
        if i == 0 { p.move(to: pt(1.52866483, 0)) } else { p.addLine(to: pt(1.52866483, 0)) }
        p.addCurve(to: pt(0.66993427, 0.06549600), control1: pt(1.08849323, 0), control2: pt(0.86840689, 0.02065399))
        p.addLine(to: pt(0.63149399, 0.07491100))
        p.addCurve(to: pt(0.07491100, 0.63149399), control1: pt(0.37282392, 0.16905607), control2: pt(0.16905607, 0.37282392))
        p.addLine(to: pt(0.06549600, 0.66993427))
        p.addCurve(to: pt(0, 1.52866483), control1: pt(0.02065399, 0.86840689), control2: pt(0, 1.08849323))
    }
    p.closeSubpath()
    return p
}

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    func grad(_ cols: [CGColor], _ locs: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)!
    }

    let m = s * 100 / 1024, side = s * 824 / 1024
    let rect = CGRect(x: m, y: m, width: side, height: side)
    let squircle = squirclePath(rect)

    // Outer shadow: wide and faint + tight contact shadow.
    for (off, blur, a) in [(0.014, 0.04, 0.28), (0.003, 0.006, 0.22)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * off), blur: s * blur, color: c(0, 0, 0, a))
        ctx.addPath(squircle); ctx.setFillColor(c(90, 92, 98)); ctx.fillPath()
        ctx.restoreGState()
    }

    // Base: the app colour, lighter at the top.
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    ctx.drawLinearGradient(grad([c(68, 128, 141), c(54, 104, 118), c(34, 77, 91)], [0, 0.5, 1]),
                           start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()

    // 16×16 grid inside the squircle (y up).
    let u = side / 16
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: m + x * u, y: m + y * u) }

    /// Fills `path` with an opaque material: drop shadow, vertical gradient, bright top edge and darker bottom edge.
    func material(_ path: CGPath, top: CGColor, bottom: CGColor, shadowAlpha: CGFloat) {
        let box = path.boundingBoxOfPath
        for (off, blur, a) in [(0.16, 0.22, shadowAlpha), (0.5, 1.0, shadowAlpha * 0.65)] as [(CGFloat, CGFloat, CGFloat)] {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -u * off), blur: u * blur, color: c(20, 20, 26, a * 0.55))
            ctx.addPath(path); ctx.setFillColor(bottom); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        // Body: lighter at the top of each object, darker at its bottom (light from above).
        ctx.drawLinearGradient(grad([top, bottom], [0, 1]),
                               start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
        // Rim: a band of constant width along the inside of the outline. Its colour depends on which way
        // the edge faces: lit where it faces up, in shade where it faces down, fading smoothly on the sides.
        // Each layer paints the part of the band that leaves the shape when moved up (or down) by an
        // increasing distance; flat top edges collect every layer, slanted edges fewer, vertical sides none.
        let lw = max(1, u * 0.085)
        ctx.addPath(path); ctx.setLineWidth(lw * 2); ctx.replacePathWithStrokedPath(); ctx.clip()
        func rim(up: Bool, alpha: CGFloat, _ color: (CGFloat) -> CGColor) {
            let steps = 10
            let a = 1 - pow(1 - alpha, 1 / CGFloat(steps))
            for k in 1...steps {
                let shift = lw * 0.45 * CGFloat(k) * (up ? -1 : 1)
                let band = CGMutablePath()
                band.addRect(box.insetBy(dx: -u * 2, dy: -u * 2))
                band.addPath(path, transform: CGAffineTransform(translationX: 0, y: shift))
                ctx.addPath(band); ctx.setFillColor(color(a)); ctx.fillPath(using: .evenOdd)
            }
        }
        // A faint light line all around, as on Scene's windows, so the rim reads as one continuous edge.
        ctx.setFillColor(c(255, 255, 255, 0.3)); ctx.fill(box.insetBy(dx: -u, dy: -u))
        rim(up: true, alpha: 0.8) { c(255, 255, 255, $0) }
        rim(up: false, alpha: 0.2) { c(0, 0, 0, $0) }
        ctx.restoreGState()
    }

    // Viewfinder: four corner brackets with round ends and rounded corners.
    let lo: CGFloat = 3.3, hi: CGFloat = 12.7, arm: CGFloat = 2.7, r: CGFloat = 1.25, w: CGFloat = 1.05
    var brackets: [CGPath] = []
    for (cx, cy, dx, dy) in [(lo, hi, 1, -1), (hi, hi, -1, -1), (hi, lo, -1, 1), (lo, lo, 1, 1)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        let l = CGMutablePath()
        l.move(to: P(cx, cy + dy * arm))
        l.addArc(tangent1End: P(cx, cy), tangent2End: P(cx + dx * arm, cy), radius: r * u)
        l.addLine(to: P(cx + dx * arm, cy))
        brackets.append(l.copy(strokingWithWidth: w * u, lineCap: .round, lineJoin: .round, miterLimit: 10))
    }

    // Three lines of text, as in the symbol: two long, one short, left aligned.
    let lineH: CGFloat = 0.95, x0: CGFloat = 8 - 5.6 / 2
    let lines: [(CGFloat, CGFloat)] = [(10, 5.6), (8, 5.6), (6, 3.8)]

    let gray = (c(255, 255, 255, 0.36), c(255, 255, 255, 0.29))
    let white = (c(255, 255, 255, 0.60), c(255, 255, 255, 0.50))
    for b in brackets { material(b, top: gray.0, bottom: gray.1, shadowAlpha: 0.38) }
    for (y, len) in lines {
        let rr = CGRect(x: P(x0, y - lineH / 2).x, y: P(x0, y - lineH / 2).y, width: len * u, height: lineH * u)
        material(CGPath(roundedRect: rr, cornerWidth: lineH * u / 2, cornerHeight: lineH * u / 2, transform: nil),
                 top: white.0, bottom: white.1, shadowAlpha: 0.45)
    }

    // Icon rim: light on top, shadow at the bottom.
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    ctx.addPath(squircle); ctx.setLineWidth(max(1, s * 0.006) * 2); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(grad([c(255, 255, 255, 0.55), c(255, 255, 255, 0), c(0, 0, 0, 0), c(0, 0, 0, 0.35)],
                                [0, 0.3, 0.75, 1]),
                           start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()

    // Very faint grain (material texture), inside the squircle only.
    if px >= 128 {
        ctx.saveGState()
        ctx.addPath(squircle); ctx.clip()
        var seed: UInt64 = 0x7E47
        func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 40) / CGFloat(1 << 24) }
        let dot = max(1, s / 512)
        for _ in 0..<(px * px / 6) {
            let v = rnd()
            ctx.setFillColor(v > 0.5 ? c(255, 255, 255, 0.016) : c(0, 0, 0, 0.016))
            ctx.fill(CGRect(x: rect.minX + rnd() * side, y: rect.minY + rnd() * side, width: dot, height: dot))
        }
        ctx.restoreGState()
    }

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
try! draw(512).write(to: URL(fileURLWithPath: "\(out)/icon-preview.png"))
