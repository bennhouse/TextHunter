import CoreGraphics
import Vision

/// One visual line of recognised text. Coordinates are in image pixels, origin bottom-left.
struct TextLine {
    var text: String
    var rect: CGRect
    /// Text set apart from the main text (a title, a caption, a note): it keeps its own
    /// paragraph, separated by empty lines, instead of being labelled.
    var apart: Apart? = nil

    enum Apart {
        case title, subtitle, caption, note
        /// Titles and subtitles one under the other belong together, and so do captions and notes.
        var isHeading: Bool { self == .title || self == .subtitle }
    }
}

enum TextRecognizer {
    /// Spaces, line breaks and invisible characters (zero-width space, BOM) trimmed from every line.
    static let blank = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}"))

    /// Recognises the text in `image` with Apple's on-device OCR and returns it as visual lines,
    /// top to bottom. Pieces of text that Vision reports separately but that sit on the same
    /// line are merged left to right. With `labelSpecialText`, superscripts, subscripts and text
    /// on coloured bubbles are labelled (see `SpecialText`).
    static func recognize(_ image: CGImage, labelSpecialText: Bool = false) throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["it-IT", "en-US"]

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let w = CGFloat(image.width), h = CGFloat(image.height)
        var candidates: [VNRecognizedText] = []
        var pieces: [TextLine] = (request.results ?? []).compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: Self.blank)
            guard !text.isEmpty else { return nil }
            candidates.append(candidate)
            let b = obs.boundingBox
            return TextLine(text: text, rect: CGRect(x: b.minX * w, y: b.minY * h, width: b.width * w, height: b.height * h))
        }
        if labelSpecialText, let bitmap = Bitmap(image), let background = bitmap.dominant(in: bitmap.whole, step: 4, fine: true) {
            pieces = zip(pieces, candidates).map { piece, candidate in
                var piece = piece
                if let color = SpecialText.bubbleColor(around: piece.rect, in: bitmap, background: background) {
                    piece.text = "[\(color) bubble: \(piece.text)]"
                } else if let labelled = SpecialText.labelInlineBubbles(candidate, text: candidate.string, imageSize: CGSize(width: w, height: h),
                                                                         in: bitmap, background: background) {
                    piece.text = labelled
                } else if let labelled = SpecialText.labelScripts(in: piece.rect, of: bitmap) {
                    piece.text = labelled
                }
                return piece
            }
        }
        let lines = groupIntoLines(pieces)
        if labelSpecialText, let bitmap = Bitmap(image), let background = bitmap.dominant(in: bitmap.whole, step: 4, fine: true) {
            return Roles.label(lines, bitmap: bitmap, background: background)
        }
        return lines
    }

    /// Groups pieces whose vertical centres are close into one line, ordered top to bottom.
    static func groupIntoLines(_ pieces: [TextLine]) -> [TextLine] {
        let sorted = pieces.sorted { $0.rect.midY > $1.rect.midY }
        var lines: [[TextLine]] = []
        for piece in sorted {
            if let last = lines.last?.first,
               abs(last.rect.midY - piece.rect.midY) < min(last.rect.height, piece.rect.height) * 0.5 {
                lines[lines.count - 1].append(piece)
            } else {
                lines.append([piece])
            }
        }
        return lines.map { group in
            let ordered = group.sorted { $0.rect.minX < $1.rect.minX }
            return TextLine(text: ordered.map(\.text).joined(separator: " "),
                            rect: ordered.dropFirst().reduce(ordered[0].rect) { $0.union($1.rect) })
        }
    }
}

/// The parts of a capture set apart from the main text. The main text (the style, size and colour,
/// that holds the most characters) is left as it is; the rest is marked by its role:
/// - bigger: the biggest size is the title, other bigger sizes are subtitles;
/// - smaller, next to an image: a caption;
/// - smaller or fainter, elsewhere: a note (a remark, a footnote, a detail).
/// None of them is labelled: each becomes a paragraph of its own, set apart by empty lines (see
/// `ParagraphJoiner`), so the copied text keeps the page's visual hierarchy. A block that wraps
/// onto several lines stays one.
enum Roles {
    struct Style { var size: CGFloat; var ink: RGB? }

    static func label(_ lines: [TextLine], bitmap: Bitmap, background: RGB) -> [TextLine] {
        guard lines.count >= 2 else { return lines }
        let styles = lines.map { l -> Style? in
            SpecialText.textSize(in: l.rect, of: bitmap).map { Style(size: $0, ink: SpecialText.inkColor(in: l.rect, of: bitmap)) }
        }
        func sameStyle(_ a: Style?, _ b: Style?) -> Bool {
            guard let a, let b else { return false }
            guard abs(a.size - b.size) / max(a.size, b.size) < 0.12 else { return false }
            if let x = a.ink, let y = b.ink { return x.distance(to: y) < 90 }
            return true
        }

        // Blocks: lines one below the other with the same style.
        var blocks: [[Int]] = []
        for i in lines.indices {
            if let last = blocks.last?.last, sameStyle(styles[last], styles[i]),
               lines[last].rect.minY - lines[i].rect.maxY < lines[i].rect.height * 0.9 {
                blocks[blocks.count - 1].append(i)
            } else {
                blocks.append([i])
            }
        }
        // The main text: the style with the most characters.
        func chars(_ b: [Int]) -> Int { b.reduce(0) { $0 + lines[$1].text.count } }
        let measured = blocks.filter { styles[$0[0]] != nil }
        guard let mainBlock = measured.max(by: { a, b in
            let ca = measured.filter { sameStyle(styles[$0[0]], styles[a[0]]) }.reduce(0) { $0 + chars($1) }
            let cb = measured.filter { sameStyle(styles[$0[0]], styles[b[0]]) }.reduce(0) { $0 + chars($1) }
            return ca < cb
        }), let main = styles[mainBlock[0]] else { return lines }
        let mainChars = measured.filter { sameStyle(styles[$0[0]], main) }.reduce(0) { $0 + chars($1) }
        // Not enough main text to compare against (a capture of a single heading, a list of labels…).
        guard mainChars >= 60, Double(mainChars) >= Double(lines.reduce(0) { $0 + $1.text.count }) * 0.4 else { return lines }

        // Lines with superscripts or bubbles are measured badly: they are left to their own labels.
        func plain(_ b: [Int]) -> Bool {
            !b.contains { lines[$0].text.contains("[superscript") || lines[$0].text.contains("[subscript") || lines[$0].text.contains(" bubble: ") }
        }
        let bigger = Set(blocks.indices.filter { k in
            plain(blocks[k]) && (styles[blocks[k][0]]?.size ?? 0) >= main.size * 1.2
        })
        var levels: [CGFloat] = []
        for h in bigger.map({ styles[blocks[$0][0]]!.size }).sorted(by: >) where !levels.contains(where: { abs($0 - h) / $0 < 0.12 }) {
            levels.append(h)
        }
        func headingName(_ k: Int) -> String {
            let size = styles[blocks[k][0]]!.size
            let level = levels.firstIndex { abs($0 - size) / $0 < 0.12 } ?? 0
            if levels.count > 1 { return level == 0 ? "title" : "subtitle" }
            // One bigger size only: a single heading at the top is the title, otherwise subtitles.
            return bigger.count == 1 && k == 0 ? "title" : "subtitle"
        }

        /// An image right above or below the block (a busy area with no text in it).
        func nextToImage(_ b: [Int]) -> Bool {
            let rect = b.map { lines[$0].rect }.reduce(CGRect.null) { $0.union($1) }
            let h = lines[b[0]].rect.height
            for area in [CGRect(x: rect.minX, y: rect.maxY + h * 0.3, width: rect.width, height: h * 3),
                         CGRect(x: rect.minX, y: rect.minY - h * 3.3, width: rect.width, height: h * 3)] {
                let clipped = area.intersection(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
                guard clipped.height > h, !lines.contains(where: { $0.rect.intersects(clipped) }) else { continue }
                if SpecialText.busyShare(bitmap.topDown(clipped), of: bitmap, background: background) > 0.3 { return true }
            }
            return false
        }

        /// Fainter than the main text: its letters stand out less from the background.
        func fainter(_ s: Style) -> Bool {
            guard let ink = s.ink, let mainInk = main.ink else { return false }
            return ink.distance(to: background) < mainInk.distance(to: background) - 90
        }

        var out: [TextLine] = []
        for (k, b) in blocks.enumerated() {
            let text = b.map { lines[$0].text }.joined(separator: " ")
            let rect = b.map { lines[$0].rect }.reduce(CGRect.null) { $0.union($1) }
            var role: String?
            if let s = styles[b[0]], plain(b), !sameStyle(s, main) || fainter(s) {
                if bigger.contains(k) {
                    role = headingName(k)
                } else if s.size <= main.size * 0.88 || fainter(s) {
                    role = nextToImage(b) ? "caption" : "note"
                }
            }
            let kinds: [String: TextLine.Apart] = ["title": .title, "subtitle": .subtitle, "caption": .caption, "note": .note]
            if let role, let kind = kinds[role] {
                out.append(TextLine(text: text, rect: rect, apart: kind))
            } else {
                out.append(contentsOf: b.map { lines[$0] })
            }
        }
        return out
    }
}
