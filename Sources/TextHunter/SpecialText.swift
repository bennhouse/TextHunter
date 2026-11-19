import AppKit
import Vision

/// Finds text that is set apart from the running text and labels it, so it doesn't get lost or
/// glued to the words around it:
///
/// - superscripts and subscripts (footnote numbers, exponents, chemical formulas):
///   `results[superscript: 17]`, `H[subscript: 2]O`;
/// - text on a coloured bubble or badge: `[blue bubble: Source 1]`.
///
/// Vision alone can't do this: it drops small raised digits or reads them as punctuation, and its
/// word boxes carry no baseline. So the line is examined in the image itself. The glyphs are
/// found as connected areas of ink, the baseline is taken from them, and small glyphs sitting
/// clearly above or below it are read on their own. The line is then read again without them,
/// and the labels are put back where they were.
enum SpecialText {
    // MARK: Bubbles

    // A bubble is a patch of one colour behind some text that differs from the capture's normal
    // background, however little: a light grey tag on white differs by only 7 per channel, a dark
    // grey one on black by 20. Screenshots have exact colours, so small differences are reliable
    // when the patch is uniform and ends, with the normal background on both sides of it.

    /// The colour of the patch behind a box, when it is not the normal background.
    private static func patch(behind box: Box, in bitmap: Bitmap, background: RGB) -> RGB? {
        guard let c = bitmap.dominant(in: box, step: 1, fine: true), c.distance(to: background) >= 12,
              bitmap.share(of: c, in: box, tolerance: 9) > 0.5 else { return nil }
        return c
    }

    /// The normal background comes back left and right of `rect` (Vision pixels): the patch ends
    /// there, so it is a bubble and not a panel, a sidebar or a table row of another colour.
    private static func endsOnBackground(_ rect: CGRect, in bitmap: Bitmap, background: RGB) -> Bool {
        let h = rect.height
        for x in [rect.minX - h * 1.5, rect.maxX + h * 1.5] {
            guard x >= 0, x < CGFloat(bitmap.width) else { continue }   // edge of the capture
            let strip = bitmap.topDown(CGRect(x: x - h * 0.15, y: rect.minY, width: h * 0.3, height: h))
            guard strip.width > 0, let side = bitmap.dominant(in: strip, step: 1, fine: true) else { continue }
            if side.distance(to: background) > 9 { return false }
        }
        return true
    }

    /// The colour name of the bubble behind `rect` (Vision coordinates in pixels, origin
    /// bottom-left), or nil when the text sits on the image's normal background.
    static func bubbleColor(around rect: CGRect, in bitmap: Bitmap, background: RGB) -> String? {
        let area = rect.width * rect.height
        guard area < CGFloat(bitmap.width * bitmap.height) * 0.5 else { return nil }
        let region = bitmap.topDown(rect.insetBy(dx: -rect.height * 0.1, dy: -rect.height * 0.1))
        guard let local = patch(behind: region, in: bitmap, background: background),
              endsOnBackground(rect, in: bitmap, background: background) else { return nil }
        return local.name(on: background)
    }

    /// Bubbles inside a line of normal text (a source tag at the end of a sentence, a badge):
    /// each word is checked for the colour behind it, and runs of words on the same colour that
    /// end on the normal background are labelled. Nil when there are none.
    static func labelInlineBubbles(_ candidate: VNRecognizedText, text: String, imageSize: CGSize,
                                   in bitmap: Bitmap, background: RGB) -> String? {
        struct Word { var text: String; var rect: CGRect?; var color: RGB? }
        var words: [Word] = []
        var from = text.startIndex
        for piece in text.split(separator: " ") {
            guard let range = text.range(of: piece, range: from..<text.endIndex) else { continue }
            from = range.upperBound
            var word = Word(text: String(piece))
            if let b = (try? candidate.boundingBox(for: range))?.boundingBox {
                let r = CGRect(x: b.minX * imageSize.width, y: b.minY * imageSize.height,
                               width: b.width * imageSize.width, height: b.height * imageSize.height)
                word.rect = r
                // The colour behind the word: the most common one in its box (letters are a minority).
                word.color = patch(behind: bitmap.topDown(r.insetBy(dx: -r.height * 0.1, dy: -r.height * 0.15)),
                                   in: bitmap, background: background)
            }
            words.append(word)
        }
        // At least one word on the normal background, or the whole piece is a bubble (handled above).
        guard words.contains(where: { $0.color != nil }), words.contains(where: { $0.color == nil }) else { return nil }
        var out: [String] = []
        var found = false
        var i = 0
        while i < words.count {
            guard let c = words[i].color else { out.append(words[i].text); i += 1; continue }
            var j = i + 1
            while j < words.count, let d = words[j].color, d.distance(to: c) < 12 { j += 1 }
            let run = words[i..<j]
            let rect = run.compactMap(\.rect).reduce(CGRect.null) { $0.union($1) }
            if !rect.isNull, endsOnBackground(rect, in: bitmap, background: background) {
                out.append("[\(c.name(on: background)) bubble: \(run.map(\.text).joined(separator: " "))]")
                found = true
            } else {
                out.append(contentsOf: run.map(\.text))
            }
            i = j
        }
        return found ? out.joined(separator: " ") : nil
    }

    // MARK: Text size

    /// The size of the text in a line, measured on the glyphs themselves: Vision's boxes don't
    /// follow the font size closely.
    static func textSize(in rect: CGRect, of bitmap: Bitmap) -> CGFloat? {
        let h = rect.height
        let region = bitmap.topDown(rect.insetBy(dx: 0, dy: -h * 0.15))
        guard region.width > 4, region.height > 4, let bg = bitmap.dominant(in: region, step: 2) else { return nil }
        let glyphs = mergeIntoGlyphs(bitmap.inkComponents(in: region, background: bg).filter {
            $0.box.minY > region.minY && $0.box.maxY < region.maxY - 1
        })
        guard glyphs.count >= 3 else { return nil }
        // The height of the tall letters (capitals, digits, d, l, t…), which nearly every line has:
        // steadier than the lowercase height, which a line full of capitals would push up.
        let heights = glyphs.map { CGFloat($0.box.height) }.sorted()
        let tall = heights[min(heights.count - 1, Int(CGFloat(heights.count) * 0.85))]
        return tall > 2 ? tall : nil
    }

    /// The colour of the letters in a line (the average of the pixels that are clearly ink).
    static func inkColor(in rect: CGRect, of bitmap: Bitmap) -> RGB? {
        let region = bitmap.topDown(rect)
        guard region.width > 2, region.height > 2, let bg = bitmap.dominant(in: region, step: 2) else { return nil }
        var r = 0, g = 0, b = 0, n = 0
        var y = region.minY
        while y <= region.maxY {
            var x = region.minX
            while x <= region.maxX {
                let p = bitmap.pixel(x, y)
                if p.distance(to: bg) > 200 { r += p.r; g += p.g; b += p.b; n += 1 }
                x += 1
            }
            y += 1
        }
        return n > 10 ? RGB(r: r / n, g: g / n, b: b / n) : nil
    }

    /// Share of the pixels in a box that are not the background: an image (photo, chart,
    /// illustration) is busy, empty space or text is not.
    static func busyShare(_ box: Box, of bitmap: Bitmap, background: RGB) -> Double {
        guard box.width > 4, box.height > 4 else { return 0 }
        var busy = 0, total = 0
        var y = box.minY
        while y <= box.maxY {
            var x = box.minX
            while x <= box.maxX {
                if bitmap.pixel(x, y).distance(to: background) > 30 { busy += 1 }
                total += 1
                x += 2
            }
            y += 2
        }
        return Double(busy) / Double(max(total, 1))
    }

    // MARK: Superscripts and subscripts

    /// The piece's text with its superscripts and subscripts labelled, or nil when it has none.
    static func labelScripts(in rect: CGRect, of bitmap: Bitmap) -> String? {
        let h = rect.height
        let region = bitmap.topDown(CGRect(x: rect.minX - h * 0.2, y: rect.minY - h * 0.2,
                                           width: rect.width + h * 0.8, height: h * 1.4))
        guard region.width > 4, region.height > 4, let bg = bitmap.dominant(in: region, step: 2) else { return nil }

        let components = bitmap.inkComponents(in: region, background: bg)
        // Ink touching the region's top or bottom edge belongs to the lines above and below.
        func isInside(_ c: Component) -> Bool { c.box.minY > region.minY && c.box.maxY < region.maxY - 1 }
        let inside = components.filter(isInside)
        let glyphs = mergeIntoGlyphs(inside)
        guard glyphs.count >= 3 else { return nil }

        let baseline = median(glyphs.map { CGFloat($0.box.maxY) })
        let topLine = median(glyphs.map { CGFloat($0.box.minY) })
        let body = baseline - topLine
        guard body > 3 else { return nil }

        func kind(_ glyph: Glyph) -> Script? {
            let g = glyph.box
            let height = CGFloat(g.maxY - g.minY + 1)
            // Quotes, apostrophes and degree signs are smaller than any real superscript.
            guard height >= body * 0.65, height <= body * 1.05 else { return nil }
            if CGFloat(g.maxY) < baseline - body * 0.35 { return .superscript }
            if CGFloat(g.minY) > topLine + body * 0.4, CGFloat(g.maxY) > baseline + body * 0.15 { return .`subscript` }
            return nil
        }

        // Neighbouring glyphs of the same kind form one group ("17", not "1" and "7").
        var groups: [(Script, Box, [Component])] = []
        for glyph in glyphs.sorted(by: { $0.box.minX < $1.box.minX }) {
            guard let k = kind(glyph) else { continue }
            if let last = groups.last, last.0 == k, CGFloat(glyph.box.minX - last.1.maxX) < body * 0.6 {
                groups[groups.count - 1] = (k, last.1.union(glyph.box), last.2 + glyph.parts)
            } else {
                groups.append((k, glyph.box, glyph.parts))
            }
        }
        guard !groups.isEmpty else { return nil }

        // Read each group on its own, enlarged.
        var labels: [(Script, Box, String)] = []
        for (k, box, parts) in groups {
            let pad = Int(body * 0.4)
            let crop = Box(minX: box.minX - pad, minY: box.minY - pad, maxX: box.maxX + pad, maxY: box.maxY + pad).clamped(to: region)
            // Only the group's own ink: neighbours (the dot of an i next to it) are painted over.
            let others = components.filter { c in !parts.contains { $0 == c } && c.box.intersects(crop) }
            // A lone character is hard for Vision: it often finds no text at all in the crop. Give it
            // more room, then show it the glyph three times side by side and take what it reads.
            var found: String?
            for (margin, copies) in [(0, 1), (Int(body), 1), (Int(body), 3)] {
                guard let image = bitmap.image(of: crop, scale: 4, erasing: others, with: bg, margin: margin),
                      let tiled = copies > 1 ? Self.repeated(image, copies, bg) : image else { continue }
                let texts = read(tiled, correct: false).map(\.text)
                    .filter { $0.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }
                // The reading most copies agree on.
                if let best = Dictionary(grouping: texts, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key {
                    found = best
                    break
                }
            }
            guard let text = found else { continue }
            labels.append((k, box, text.replacingOccurrences(of: " ", with: "")))
        }
        guard !labels.isEmpty else { return nil }

        // Read the line again without them (and without the neighbouring lines' ink).
        var erase = labels.flatMap { label in groups.first { $0.1 == label.1 }?.2 ?? [] }
        erase += components.filter { !isInside($0) }
        guard let cleaned = bitmap.image(of: region, scale: 1, erasing: erase, with: bg) else { return nil }
        let words = read(cleaned, correct: true).flatMap(\.words).sorted { $0.minX < $1.minX }

        // Whether the label touches the glyphs of the running text on each side: H₂O touches both
        // (it sits inside a word), a footnote number only the word before it.
        let plain = glyphs.filter { kind($0) == nil }
        let touch = body * 0.35
        let placed = labels.map { label -> Label in
            let box = label.1
            let left = plain.contains { $0.box.maxX < box.minX && CGFloat(box.minX - $0.box.maxX) <= touch }
            let right = plain.contains { $0.box.minX > box.maxX && CGFloat($0.box.minX - box.maxX) <= touch }
            return Label(kind: label.0, minX: CGFloat(box.minX - region.minX), maxX: CGFloat(box.maxX - region.minX),
                         text: label.2, touchesLeft: left, touchesRight: right)
        }
        return compose(words: words, labels: placed,
                       glyphStarts: plain.map { CGFloat($0.box.minX - region.minX) }, tolerance: body * 0.3)
    }

    enum Script { case superscript, `subscript` }

    struct Label {
        var kind: Script
        var minX: CGFloat, maxX: CGFloat
        var text: String
        var touchesLeft: Bool, touchesRight: Bool
    }

    /// Puts the labels between (or inside) the words, by horizontal position. Vision's word boxes
    /// are only approximate, so whether a label is glued to a word comes from the ink, not from them.
    private static func compose(words: [Word], labels: [Label], glyphStarts: [CGFloat], tolerance: CGFloat) -> String {
        struct Token { var text: String; var minX: CGFloat; var maxX: CGFloat; var glueLeft = false; var glueRight = false }
        var tokens = words.map { Token(text: $0.text, minX: $0.minX, maxX: $0.maxX) }
        for label in labels {
            let text = "[\(label.kind == .superscript ? "superscript" : "subscript"): \(label.text)]"
            let mid = (label.minX + label.maxX) / 2
            var token = Token(text: text, minX: label.minX, maxX: label.maxX,
                              glueLeft: label.touchesLeft, glueRight: label.touchesRight)
            // Inside a word (H₂O): split it after as many characters as there are glyphs of ink
            // before the label. A label past the word's last glyph goes after it instead.
            var split: (index: Int, at: Int)?
            if label.touchesLeft, label.touchesRight,
               let i = tokens.firstIndex(where: { $0.text.first != "[" && $0.minX < mid && mid < $0.maxX }) {
                let before = glyphStarts.filter { $0 >= tokens[i].minX - tolerance && $0 < label.minX }.count
                if before > 0, before < tokens[i].text.count { split = (i, before) }
            }
            if let (i, at) = split {
                let word = tokens[i]
                let characters = Array(word.text)
                let left = Token(text: String(characters[..<at]), minX: word.minX, maxX: label.minX)
                let right = Token(text: String(characters[at...]), minX: label.maxX, maxX: word.maxX)
                tokens.replaceSubrange(i...i, with: [left, token, right])
            } else {
                // Between words. Glued to a word (x², a footnote number): next to the word whose
                // end (or start) is nearest; otherwise by position.
                let words = tokens.indices.filter { tokens[$0].text.first != "[" }
                var at: Int
                if label.touchesLeft, let i = words.min(by: { abs(tokens[$0].maxX - label.minX) < abs(tokens[$1].maxX - label.minX) }) {
                    at = i + 1
                } else if label.touchesRight, let i = words.min(by: { abs(tokens[$0].minX - label.maxX) < abs(tokens[$1].minX - label.maxX) }) {
                    at = i
                } else {
                    at = tokens.firstIndex { ($0.minX + $0.maxX) / 2 > mid } ?? tokens.count
                }
                // Keep labels that follow each other in order.
                while at < tokens.count, tokens[at].text.first == "[", tokens[at].minX < token.minX { at += 1 }
                tokens.insert(token, at: at)
            }
        }
        var out = ""
        for (i, token) in tokens.enumerated() {
            if i > 0, !token.glueLeft, !tokens[i - 1].glueRight { out += " " }
            out += token.text
        }
        return out
    }

    // MARK: Vision

    /// The image several times side by side.
    private static func repeated(_ image: CGImage, _ copies: Int, _ bg: RGB) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w * copies, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: CGFloat(bg.r) / 255, green: CGFloat(bg.g) / 255, blue: CGFloat(bg.b) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w * copies, height: h))
        for i in 0..<copies { ctx.draw(image, in: CGRect(x: i * w, y: 0, width: w, height: h)) }
        return ctx.makeImage()
    }

    struct Word { var text: String; var minX: CGFloat; var maxX: CGFloat }
    struct Reading { var text: String; var words: [Word] }

    private static func read(_ image: CGImage, correct: Bool) -> [Reading] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = correct
        request.recognitionLanguages = ["it-IT", "en-US"]
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let width = CGFloat(image.width)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: TextRecognizer.blank)
            guard !text.isEmpty else { return nil }
            var words: [Word] = []
            var from = text.startIndex
            for piece in text.split(separator: " ") {
                guard let range = text.range(of: piece, range: from..<text.endIndex) else { continue }
                from = range.upperBound
                let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                words.append(Word(text: String(piece), minX: box.minX * width, maxX: box.maxX * width))
            }
            return Reading(text: text, words: words)
        }.sorted { ($0.words.first?.minX ?? 0) < ($1.words.first?.minX ?? 0) }
    }

    // MARK: Glyphs

    struct Glyph { var box: Box; var parts: [Component] }

    /// Joins components that overlap horizontally (the dot of an i, an accent) into glyphs.
    private static func mergeIntoGlyphs(_ components: [Component]) -> [Glyph] {
        var glyphs: [Glyph] = []
        for c in components.sorted(by: { $0.box.minX < $1.box.minX }) {
            if let i = glyphs.lastIndex(where: { g in
                let overlap = min(g.box.maxX, c.box.maxX) - max(g.box.minX, c.box.minX)
                return CGFloat(overlap) >= CGFloat(min(g.box.width, c.box.width)) * 0.5
            }) {
                glyphs[i].box = glyphs[i].box.union(c.box)
                glyphs[i].parts.append(c)
            } else {
                glyphs.append(Glyph(box: c.box, parts: [c]))
            }
        }
        return glyphs
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let s = values.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }
}

// MARK: - Pixels

struct RGB: Equatable {
    var r: Int, g: Int, b: Int

    func distance(to other: RGB) -> Int {
        abs(r - other.r) + abs(g - other.g) + abs(b - other.b)
    }

    /// A plain colour name for labels. Greys are named against the background: a dark grey
    /// bubble on black is "grey", not "dark".
    func name(on background: RGB) -> String {
        let color = NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        let hue = color.hueComponent * 360, saturation = color.saturationComponent, brightness = color.brightnessComponent
        if saturation < 0.2 {
            let lighter = r + g + b > background.r + background.g + background.b
            if lighter { return brightness > 0.9 ? "white" : "grey" }
            return brightness < 0.06 ? "black" : (brightness < 0.3 ? "dark" : "grey")
        }
        switch hue {
        case ..<15, 345...: return "red"
        case ..<40: return "orange"
        case ..<65: return "yellow"
        case ..<170: return "green"
        case ..<195: return "teal"
        case ..<255: return "blue"
        case ..<290: return "purple"
        default: return "pink"
        }
    }
}

/// An integer pixel rectangle, top-down, bounds inclusive.
struct Box: Equatable {
    var minX: Int, minY: Int, maxX: Int, maxY: Int
    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }

    func union(_ o: Box) -> Box {
        Box(minX: min(minX, o.minX), minY: min(minY, o.minY), maxX: max(maxX, o.maxX), maxY: max(maxY, o.maxY))
    }

    func intersects(_ o: Box) -> Bool {
        minX <= o.maxX && o.minX <= maxX && minY <= o.maxY && o.minY <= maxY
    }

    func clamped(to o: Box) -> Box {
        Box(minX: max(minX, o.minX), minY: max(minY, o.minY), maxX: min(maxX, o.maxX), maxY: min(maxY, o.maxY))
    }
}

/// A connected area of ink: its box and its exact pixels (indices into the bitmap).
struct Component: Equatable {
    var box: Box
    var pixels: [Int]

    static func == (a: Component, b: Component) -> Bool { a.box == b.box && a.pixels.count == b.pixels.count }
}

/// The captured image as plain RGBA bytes, rows top to bottom.
final class Bitmap {
    let width: Int, height: Int
    private var bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }

    @inline(__always) func pixel(_ x: Int, _ y: Int) -> RGB {
        let i = (y * width + x) * 4
        return RGB(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]))
    }

    /// Converts a Vision rectangle (pixels, origin bottom-left) to a clamped top-down box.
    func topDown(_ rect: CGRect) -> Box {
        Box(minX: max(0, Int(rect.minX.rounded(.down))),
            minY: max(0, height - Int(rect.maxY.rounded(.up))),
            maxX: min(width - 1, Int(rect.maxX.rounded(.up))),
            maxY: min(height - 1, height - Int(rect.minY.rounded(.down)) - 1))
    }

    var whole: Box { Box(minX: 0, minY: 0, maxX: width - 1, maxY: height - 1) }

    /// Share of the pixels in a box that are close to `color`.
    func share(of color: RGB, in box: Box, tolerance: Int = 24) -> Double {
        guard box.width > 0, box.height > 0 else { return 0 }
        var n = 0
        for y in box.minY...box.maxY { for x in box.minX...box.maxX where pixel(x, y).distance(to: color) < tolerance { n += 1 } }
        return Double(n) / Double(box.width * box.height)
    }

    /// The most common colour in a box (colours grouped in steps of 16).
    /// `fine`: colours grouped in steps of 4 instead of 16, to tell apart greys a few levels apart.
    func dominant(in box: Box, step: Int, fine: Bool = false) -> RGB? {
        guard box.width > 0, box.height > 0 else { return nil }
        var counts: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
        var y = box.minY
        while y <= box.maxY {
            var x = box.minX
            while x <= box.maxX {
                let p = pixel(x, y)
                let shift = fine ? 2 : 4, bits = fine ? 6 : 4
                let r = p.r >> shift, g = p.g >> shift, b = p.b >> shift
                let key: Int = (r << (2 * bits)) | (g << bits) | b
                let c = counts[key] ?? (0, 0, 0, 0)
                counts[key] = (c.n + 1, c.r + p.r, c.g + p.g, c.b + p.b)
                x += step
            }
            y += step
        }
        guard let top = counts.values.max(by: { $0.n < $1.n }) else { return nil }
        return RGB(r: top.r / top.n, g: top.g / top.n, b: top.b / top.n)
    }

    /// Connected areas of pixels that differ clearly from the background.
    func inkComponents(in box: Box, background bg: RGB) -> [Component] {
        let w = box.width, h = box.height
        var ink = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let p = pixel(box.minX + x, box.minY + y)
                ink[y * w + x] = max(abs(p.r - bg.r), abs(p.g - bg.g), abs(p.b - bg.b)) > 70
            }
        }
        var seen = [Bool](repeating: false, count: w * h)
        var result: [Component] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where ink[start] && !seen[start] {
            seen[start] = true
            stack.append(start)
            var b = Box(minX: Int.max, minY: Int.max, maxX: Int.min, maxY: Int.min)
            var pixels: [Int] = []
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                pixels.append((box.minY + y) * width + box.minX + x)
                b = Box(minX: min(b.minX, x), minY: min(b.minY, y), maxX: max(b.maxX, x), maxY: max(b.maxY, y))
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let j = ny * w + nx
                    if ink[j] && !seen[j] {
                        seen[j] = true
                        stack.append(j)
                    }
                }
            }
            if pixels.count >= 4 {
                result.append(Component(box: Box(minX: b.minX + box.minX, minY: b.minY + box.minY,
                                                 maxX: b.maxX + box.minX, maxY: b.maxY + box.minY), pixels: pixels))
            }
        }
        return result
    }

    /// A box of the image as a new image, optionally enlarged, with some components painted
    /// over in the background colour (their exact pixels, plus a 1 px fringe of anti-aliasing).
    func image(of box: Box, scale: Int, erasing: [Component] = [], with bg: RGB? = nil, margin: Int = 0) -> CGImage? {
        guard box.width > 0, box.height > 0 else { return nil }
        var crop = [UInt8](repeating: 0, count: box.width * box.height * 4)
        for y in 0..<box.height {
            for x in 0..<box.width {
                let src = ((box.minY + y) * width + box.minX + x) * 4
                let dst = (y * box.width + x) * 4
                crop[dst] = bytes[src]; crop[dst + 1] = bytes[src + 1]; crop[dst + 2] = bytes[src + 2]; crop[dst + 3] = 255
            }
        }
        if let bg {
            for e in erasing {
                for p in e.pixels {
                    let px = p % width, py = p / width
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let x = px + dx, y = py + dy
                            guard x >= box.minX, x <= box.maxX, y >= box.minY, y <= box.maxY else { continue }
                            // Only the fringe that is not ink of another glyph: lighter than half way.
                            let src = (y * width + x) * 4
                            let d = max(abs(Int(bytes[src]) - bg.r), abs(Int(bytes[src + 1]) - bg.g), abs(Int(bytes[src + 2]) - bg.b))
                            if dx != 0 || dy != 0, d > 70 { continue }
                            let dst = ((y - box.minY) * box.width + x - box.minX) * 4
                            crop[dst] = UInt8(bg.r); crop[dst + 1] = UInt8(bg.g); crop[dst + 2] = UInt8(bg.b)
                        }
                    }
                }
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(crop) as CFData),
              let small = CGImage(width: box.width, height: box.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: box.width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        guard scale > 1 || margin > 0 else { return small }
        // Enlarged, with an optional plain border of background around it.
        let m = margin * scale
        let w = box.width * scale + 2 * m, h = box.height * scale + 2 * m
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        if m > 0, let bg {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(bg.r) / 255, green: CGFloat(bg.g) / 255, blue: CGFloat(bg.b) / 255, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.interpolationQuality = .high
        ctx.draw(small, in: CGRect(x: m, y: m, width: box.width * scale, height: box.height * scale))
        return ctx.makeImage()
    }
}
