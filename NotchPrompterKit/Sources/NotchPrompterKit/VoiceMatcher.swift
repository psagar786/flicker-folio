import Foundation

/// Finds your place in the script from the words the recogniser heard.
public struct VoiceMatcher {
    public init() {}

    /// Use locale-specific number words when speech recognition emits digits instead of words.
    public var numberLocale: String?

    private static let conversationalFiller: Set<String> = [
        "about", "actually", "after", "again", "because", "before", "could", "everyone",
        "first", "going", "hello", "maybe", "people", "really", "right", "should", "something",
        "thank", "thanks", "their", "there", "these", "think", "those", "today", "would"
    ]

    /// The script's words (normalised for matching) and where they are in the text.
    public private(set) var words: [(norm: String, range: NSRange)] = []
    /// Index of the next word to say.
    public var cursor = 0
    /// The last heard word (index in the current recognition task) that moved the cursor.
    private var lastUsedSpoken = -1
    private var heardTask = 0
    /// How many words the current recognition task has heard so far.
    private var heardCount = 0
    private var lastTranscript: [String] = []
    private var revisionFloor = -1
    private var lineStarts: Set<Int> = []
    /// How often each word comes up in the script: frequent words say little about where the speaker is.
    private var counts: [String: Int] = [:]

    /// Stage directions like "(pause)" or "[smile]": shown, but not read out loud. Full-width
    /// brackets, as Chinese and Japanese text uses them, count too: "（深呼吸）", "【笑顔】".
    public private(set) var cues: [NSRange] = []
    private var length = 0

    private static let cuePattern = try! NSRegularExpression(
        pattern: #"[(（][^()（）\n]*[)）]|[\[［【][^\[\]［］【】\n]*[\]］】]"#)

    public mutating func setText(_ text: String) {
        let ns = text as NSString
        length = ns.length
        let cues = Self.cuePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        self.cues = cues
        var found: [(norm: String, range: NSRange)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { w, range, _, _ in
            guard let w, !cues.contains(where: { NSLocationInRange(range.location, $0) }) else { return }
            found.append((VoiceMatcher.normalise(w), range))
        }
        words = found
        lineStarts = Set(found.indices.dropFirst().filter { index in
            let previousEnd = NSMaxRange(found[index - 1].range)
            let gap = NSRange(location: previousEnd, length: found[index].range.location - previousEnd)
            return ns.rangeOfCharacter(from: .newlines, options: [], range: gap).location != NSNotFound
        })
        counts = Dictionary(found.map { ($0.norm, 1) }, uniquingKeysWith: +)
        cursor = min(cursor, words.count)
    }

    /// Where the said part of the text ends: everything before the next word to say, so the
    /// punctuation and stage directions after the last said word count as said too. An opening
    /// quote or bracket that belongs to the next word does not.
    public func saidEnd(in text: NSString) -> Int {
        guard cursor > 0, !words.isEmpty else { return 0 }
        guard cursor < words.count else { return length }
        var end = words[cursor].range.location
        let opening = CharacterSet(charactersIn: "\"'“‘«‹([{¿¡-–—（［【「『")
        func before(_ set: CharacterSet) -> Bool {
            end > 0 && UnicodeScalar(text.character(at: end - 1)).map(set.contains) == true
        }
        while before(opening) { end -= 1 }                          // attached to the next word
        while before(.whitespacesAndNewlines) { end -= 1 }
        return max(end, NSMaxRange(words[cursor - 1].range))
    }

    /// Ignore the words heard so far, e.g. after the cursor was moved by hand. The recognition
    /// task keeps running: a new one would need a few seconds to hear again.
    public mutating func resetHeard() {
        lastUsedSpoken = heardCount - 1
        revisionFloor = lastUsedSpoken
    }

    /// Index of the word at a character position.
    public func wordIndex(atCharacter index: Int) -> Int? {
        guard !words.isEmpty else { return nil }
        return words.firstIndex { NSMaxRange($0.range) > index } ?? words.count - 1
    }

    public static func normalise(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Loose word match: exact, a partly heard word, or one letter off in a longer word.
    public static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.count >= 3 && b.count >= 3 && (a.hasPrefix(b) || b.hasPrefix(a)) { return true }
        guard a.count >= 5, b.count >= 5, abs(a.count - b.count) <= 1 else { return false }
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count] <= 1
    }

    /// Move the cursor to just after the script word that the latest heard words line up with.
    /// Returns true when the cursor moved.
    @discardableResult
    public mutating func follow(_ segments: [String], task: Int) -> Bool {
        let heard = segments.flatMap { $0.split { $0.isWhitespace || $0 == "-" } }.map { Self.normalise(String($0)) }
            .filter { !$0.isEmpty }
        if task != heardTask {
            heardTask = task
            lastUsedSpoken = -1
            revisionFloor = -1
            lastTranscript = []
        }
        heardCount = heard.count
        guard !heard.isEmpty else {
            lastTranscript = []
            lastUsedSpoken = revisionFloor
            return false
        }
        // A partial result may correct the last token without adding a word.
        if heard.count <= lastUsedSpoken + 1,
           heard.last != lastTranscript.last, heard.count - 1 > revisionFloor {
            lastUsedSpoken = heard.count - 2
        }
        lastTranscript = heard
        guard heard.count - 1 > lastUsedSpoken, !words.isEmpty else { return false }
        // Try the newest word first. If it was misheard, one of the other new words may still fit,
        // so a burst of words ending in a wrong guess still moves the text.
        for end in stride(from: heard.count - 1, through: max(lastUsedSpoken + 1, heard.count - 4), by: -1) {
            let context = heard[max(0, end - 4)..<end]
            if let p = matchNumber(heard[end], after: context)
                ?? place(heard[end], after: context)
                ?? nextLineAnchor(heard[end], context: context)
                ?? nearbyAnchor(heard[end]) {
                cursor = p + 1
                lastUsedSpoken = end
                return true
            }
        }
        return false
    }

    private func matchNumber(_ last: String, after context: ArraySlice<String>) -> Int? {
        guard let numberLocale, words.indices.contains(cursor) else { return nil }
        let heardNumber = Int(last)
        let writtenNumber = Int(words[cursor].norm)
        guard heardNumber != nil || writtenNumber != nil,
              Locale(identifier: numberLocale).language.languageCode?.identifier == "en" else { return nil }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: numberLocale)
        formatter.numberStyle = .spellOut
        func spelling(_ number: Int) -> [String] {
            guard number >= 0, number <= 999_999,
                  let value = formatter.string(from: NSNumber(value: number)) else { return [] }
            return value.split { $0.isWhitespace || $0 == "-" }
                .map { Self.normalise(String($0)) }.filter { !$0.isEmpty && $0 != "and" }
        }
        if let heardNumber {
            let spoken = spelling(heardNumber)
            guard !spoken.isEmpty else { return nil }
            var end = cursor
            for token in spoken {
                if end > cursor, end < words.count, words[end].norm == "and" { end += 1 }
                guard end < words.count, words[end].norm == token else { return nil }
                end += 1
            }
            return end - 1
        }
        if let writtenNumber {
            let spoken = spelling(writtenNumber)
            let recent = context.filter { $0 != "and" } + [last]
            if !spoken.isEmpty && recent.suffix(spoken.count).elementsEqual(spoken) { return cursor }
        }
        return nil
    }

    /// Recover from a skipped or misheard phrase using a unique two-word line opening.
    private func nextLineAnchor(_ last: String, context: ArraySlice<String>) -> Int? {
        guard let first = context.last else { return nil }
        let candidates = lineStarts.filter { index in
            index + 1 < words.count && words[index].norm == first && words[index + 1].norm == last
        }
        guard candidates.count == 1, let index = candidates.first, index >= cursor, index - cursor <= 28
        else { return nil }
        return index + 1
    }

    /// A distinctive exact word can recover a small gap after an ad-lib. Require a unique
    /// occurrence so a repeated cue or a previously said word cannot trigger this shortcut.
    private func nearbyAnchor(_ word: String) -> Int? {
        guard word.count >= 5, counts[word] == 1, !Self.conversationalFiller.contains(word) else { return nil }
        let end = min(words.count, cursor + 18)
        guard cursor < end else { return nil }
        return (cursor..<end).first { words[$0].norm == word }
    }

    /// The script word that a heard word is, judged by the words heard just before it; nil if none fits.
    private func place(_ last: String, after tail: ArraySlice<String>) -> Int? {
        let lo = max(0, cursor - 1), hi = min(words.count - 1, cursor + 40)
        guard lo <= hi else { return nil }
        var best = -1, bestScore = 0.0, bestEvidence = (count: 0, weight: 0.0)
        for p in lo...hi where Self.similar(last, words[p].norm) {
            // Moving on a word or two needs little; jumping further ahead needs words that
            // don't come up all over the script.
            let distance = p - cursor
            let (count, weight) = evidence(p, last, tail)
            let enough = distance <= 1 ? count >= 1 : distance <= 3 ? count >= 2
                : distance <= 10 ? weight >= 1.5 : weight >= 3
            guard enough else { continue }
            let score = weight + Double(count) * 0.1 - Double(abs(distance)) * 0.02
            if score > bestScore { bestScore = score; best = p; bestEvidence = (count, weight) }
        }
        guard best >= 0, best + 1 > cursor else { return nil }
        // Going back to say a part again repeats words that may also come later in the script
        // ("de fleste bare" twice). If the words fit the part just said as well, stay. A move of
        // a word or two needs more words to fit behind, since saying the script also repeats
        // small words.
        for q in max(0, cursor - 60)..<cursor where Self.similar(last, words[q].norm) {
            let behind = evidence(q, last, tail)
            if best > cursor + 1 ? behind.weight >= bestEvidence.weight : behind.count > bestEvidence.count + 1 { return nil }
        }
        return best
    }

    /// How well the heard words line up with the script, ending at script word `p`. Words that
    /// come up all over the script ("and", "the", "du") count less than rare ones. The match allows
    /// a skipped script word or an extra spoken word ("uh"), and stops at two misses in a row.
    private func evidence(_ p: Int, _ last: String, _ tail: ArraySlice<String>) -> (count: Int, weight: Double) {
        func weight(_ w: String) -> Double {
            let n = counts[w, default: 1]
            let rare = n <= 1 ? 1 : n == 2 ? 0.75 : n <= 4 ? 0.5 : 0.25
            return w.count >= 3 || w.first?.isNumber == true ? rare : min(rare, 0.5)
        }
        var count = 1, found = weight(words[p].norm), i = p - 1, misses = 0
        for w in tail.reversed() where i >= 0 {
            if Self.similar(w, words[i].norm) { count += 1; found += weight(words[i].norm); i -= 1; misses = 0 }
            else if i >= 1 && Self.similar(w, words[i - 1].norm) { count += 1; found += weight(words[i - 1].norm); i -= 2; misses = 0 }
            else { misses += 1; if misses == 2 { break } }
        }
        return (count, found)
    }
}
