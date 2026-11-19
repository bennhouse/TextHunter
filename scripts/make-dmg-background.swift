// Draws the DMG window background: a light neutral surface, a straight arrow from the app
// to Applications and one line of text.
//   swift scripts/make-dmg-background.swift <out-dir>   → background.png, background@2x.png
// Layout (points, origin top-left) must match make-dmg.sh: window 640x400,
// TextHunter.app centred at (170, 180), Applications at (470, 180).
import AppKit

let W: CGFloat = 640, H: CGFloat = 400
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func draw(scale: CGFloat) -> Data {
    let px = Int(W * scale), py = Int(H * scale)
    let ctx = CGContext(data: nil, width: px, height: py, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    // Coordinates from the top-left, like Finder.
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)

    // Surface: a barely visible vertical gradient.
    let bg = CGGradient(colorsSpace: nil, colors: [c(248, 248, 250), c(236, 236, 240)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: 0, y: H), options: [])

    // Straight arrow from the app to Applications.
    ctx.setStrokeColor(c(110, 110, 118)); ctx.setLineWidth(1.5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let y: CGFloat = 180
    ctx.move(to: CGPoint(x: 282, y: y)); ctx.addLine(to: CGPoint(x: 358, y: y))
    ctx.move(to: CGPoint(x: 351, y: y - 6)); ctx.addLine(to: CGPoint(x: 358, y: y)); ctx.addLine(to: CGPoint(x: 351, y: y + 6))
    ctx.strokePath()

    // Caption.
    let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.35, green: 0.35, blue: 0.39, alpha: 1),
        .paragraphStyle: para,
    ]
    ("Drag TextHunter to the Applications folder" as NSString)
        .draw(in: CGRect(x: 0, y: 318, width: W, height: 20), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: W, height: H)
    return rep.representation(using: .png, properties: [:])!
}

try! draw(scale: 1).write(to: URL(fileURLWithPath: "\(out)/background.png"))
try! draw(scale: 2).write(to: URL(fileURLWithPath: "\(out)/background@2x.png"))
