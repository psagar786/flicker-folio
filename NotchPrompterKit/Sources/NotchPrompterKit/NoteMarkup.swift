import Foundation

/// Lightweight formatting shared by the notes preview, prompt, and plain-text export.
public struct NoteMarkup {
    public struct Style: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let heading = Self(rawValue: 1)
        public static let bold = Self(rawValue: 2)
        public static let italic = Self(rawValue: 4)
        public static let underline = Self(rawValue: 8)
    }

    public struct Run {
        public let range: NSRange
        public let style: Style
    }

    public private(set) var text = ""
    public private(set) var runs: [Run] = []

    private static let inline = try! NSRegularExpression(pattern: #"\*\*\*(.+?)\*\*\*|\*\*(.+?)\*\*|(?<!\*)\*([^*]+?)\*(?!\*)|<u>(.+?)</u>"#)
    private static let heading = try! NSRegularExpression(pattern: #"^#{1,6}[ \t]+"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*+]|[0-9]+\.)[ \t]+"#)

    public init(_ source: String, skipBlankLines: Bool = false) {
        let sourceLines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        let lines = skipBlankLines
            ? sourceLines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            : sourceLines
        for (index, line) in lines.enumerated() {
            if index > 0 { text += "\n" }
            let ns = String(line) as NSString
            let full = NSRange(location: 0, length: ns.length)
            let heading = Self.heading.firstMatch(in: String(line), range: full)
            let bullet = Self.bullet.firstMatch(in: String(line), range: full)
            let start = heading?.range.length ?? bullet?.range.length ?? 0
            if bullet != nil { text += "• " }
            appendInline(ns.substring(from: start), style: heading == nil ? [] : .heading)
        }
    }

    private mutating func appendInline(_ string: String, style: Style) {
        let ns = string as NSString
        let range = NSRange(location: 0, length: ns.length)
        let styles: [Style] = [[.bold, .italic], .bold, .italic, .underline]
        var offset = 0
        for match in Self.inline.matches(in: string, range: range) {
            append(ns.substring(with: NSRange(location: offset, length: match.range.location - offset)), style: style)
            for (index, trait) in styles.enumerated() {
                let captured = match.range(at: index + 1)
                if captured.location != NSNotFound {
                    appendInline(ns.substring(with: captured), style: style.union(trait))
                    break
                }
            }
            offset = NSMaxRange(match.range)
        }
        append(ns.substring(from: offset), style: style)
    }

    private mutating func append(_ string: String, style: Style) {
        guard !string.isEmpty else { return }
        let range = NSRange(location: text.utf16.count, length: string.utf16.count)
        text += string
        if !style.isEmpty { runs.append(Run(range: range, style: style)) }
    }
}
