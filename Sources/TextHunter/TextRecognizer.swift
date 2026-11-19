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
        return groupIntoLines(pieces)
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
