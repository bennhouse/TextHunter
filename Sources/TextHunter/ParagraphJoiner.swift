import CoreGraphics
import Foundation

/// Turns recognised lines back into running text. A line break is removed when the line only
/// ended because the text ran out of room (the next word could not fit), and kept when it is a
/// real break: the end of a paragraph, a list item, a heading or a short line.
enum ParagraphJoiner {
    static func text(from lines: [TextLine], joinWrappedLines: Bool) -> String {
        guard joinWrappedLines, lines.count > 1 else {
            return lines.map(\.text).joined(separator: "\n")
        }

        let left = lines.map(\.rect.minX).min()!
        let right = lines.map(\.rect.maxX).max()!
        let charWidth = median(lines.map { $0.rect.width / CGFloat(max($0.text.count, 1)) })
        let lineHeight = median(lines.map(\.rect.height))
        let gaps = zip(lines, lines.dropFirst()).map { $0.rect.minY - $1.rect.maxY }
        let normalGap = median(gaps)
        // Narrow blocks (short list entries, labels, a few words per line) are left as they are:
        // wrapping only makes sense for text set in lines long enough to hold several words.
        let wideEnough = right - left >= charWidth * 20

        var out = lines[0].text
        for i in 1..<lines.count {
            let a = lines[i - 1], b = lines[i]
            let wrapped = wideEnough && isWrap(a, b, gap: gaps[i - 1], normalGap: normalGap, lineHeight: lineHeight,
                                               left: left, right: right, charWidth: charWidth)
            out = wrapped ? join(out, b.text) : out + "\n" + b.text
        }
        return out
    }

    private static func isWrap(_ a: TextLine, _ b: TextLine, gap: CGFloat, normalGap: CGFloat, lineHeight: CGFloat,
                               left: CGFloat, right: CGFloat, charWidth: CGFloat) -> Bool {
        // Titles and subtitles stand on their own line.
        if [a.text, b.text].contains(where: { $0.hasPrefix("[title: ") || $0.hasPrefix("[subtitle: ") }) { return false }
        // Extra vertical space: a new paragraph.
        if gap > normalGap + lineHeight * 0.6 { return false }
        // The next line starts a list item.
        if startsListItem(b.text) { return false }
        // The first word of the next line would have fit at the end of this line: the break was deliberate.
        let firstWord = b.text.split(separator: " ").first.map { $0.count } ?? 0
        if right - a.rect.maxX > charWidth * CGFloat(firstWord + 2) { return false }
        // First-line indent after a finished sentence: a new paragraph.
        let indented = b.rect.minX - left > charWidth * 1.5 && a.rect.minX - left < charWidth
        if indented && endsSentence(a.text) { return false }
        return true
    }

    /// Joins two pieces of a paragraph, mending words split with a hyphen ("infor-" + "mazione").
    private static func join(_ text: String, _ next: String) -> String {
        if let last = text.last, "-‐".contains(last),
           text.dropLast().last?.isLetter == true,
           next.first?.isLowercase == true {
            return String(text.dropLast()) + next
        }
        return text + " " + next
    }

    private static func startsListItem(_ s: String) -> Bool {
        s.range(of: #"^\s*([•·▪‣◦●○■□➢►*–—-]|\d{1,3}[.)]|[a-zA-Z][)])\s+"#, options: .regularExpression) != nil
    }

    private static func endsSentence(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?:;…»\"”".contains(last)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
