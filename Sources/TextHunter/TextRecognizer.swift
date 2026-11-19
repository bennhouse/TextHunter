import CoreGraphics
import Vision

/// One visual line of recognised text. Coordinates are in image pixels, origin bottom-left.
struct TextLine {
    var text: String
    var rect: CGRect
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
        if labelSpecialText, let bitmap = Bitmap(image) {
            return Headings.label(lines, sizes: lines.map { SpecialText.textSize(in: $0.rect, of: bitmap) })
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

/// Titles and subtitles: lines set clearly bigger than the running text. The biggest size is the
/// title, the other bigger sizes are subtitles. A heading that wraps onto two lines stays one.
enum Headings {
    /// `sizes`: the measured text size of each line (nil when it can't be measured).
    static func label(_ lines: [TextLine], sizes: [CGFloat?]) -> [TextLine] {
        guard lines.count >= 3 else { return lines }
        func height(_ i: Int) -> CGFloat { sizes[i] ?? 0 }
        // The running text's size: the size that holds the most characters.
        let weighted = lines.indices.filter { sizes[$0] != nil }
            .flatMap { i in Array(repeating: height(i), count: max(lines[i].text.count / 10, 1)) }.sorted()
        guard !weighted.isEmpty else { return lines }
        let body = weighted[weighted.count / 2]
        guard body > 0 else { return lines }
        // Lines with superscripts or bubbles are taller because of them, not because of their size.
        let big = lines.indices.filter { i in
            height(i) >= body * 1.2 && !lines[i].text.contains("[superscript")
                && !lines[i].text.contains("[subscript") && !lines[i].text.contains(" bubble: ")
        }
        guard !big.isEmpty, big.count * 2 < lines.count else { return lines }

        // Sizes within 12% of each other are the same level.
        var levels: [CGFloat] = []
        for h in big.map({ height($0) }).sorted(by: >) where !levels.contains(where: { abs($0 - h) / $0 < 0.12 }) {
            levels.append(h)
        }
        func level(_ i: Int) -> Int { levels.firstIndex { abs($0 - height(i)) / $0 < 0.12 } ?? 0 }
        func name(_ lvl: Int, onlyLine: Bool) -> String {
            if levels.count > 1 { return lvl == 0 ? "title" : "subtitle" }
            // One bigger size only: a single line at the top is the title, otherwise they are subtitles.
            return onlyLine && big.first == 0 ? "title" : "subtitle"
        }

        var out: [TextLine] = []
        var i = 0
        while i < lines.count {
            guard big.contains(i) else { out.append(lines[i]); i += 1; continue }
            let lvl = level(i)
            var j = i + 1
            var text = lines[i].text, rect = lines[i].rect
            // The next line continues the heading: same size, right below it.
            while j < lines.count, big.contains(j), level(j) == lvl,
                  rect.minY - lines[j].rect.maxY < lines[j].rect.height * 0.6 {
                text += " " + lines[j].text
                rect = rect.union(lines[j].rect)
                j += 1
            }
            out.append(TextLine(text: "[\(name(lvl, onlyLine: big.count == j - i)): \(text)]", rect: rect))
            i = j
        }
        return out
    }
}
