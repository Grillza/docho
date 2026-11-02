import Foundation

/// Renames chapters the way the user renamed another one (Android's `RenameLike`). `learn` reads
/// the style from that example, e.g. "Chainsaw v10 ch 10-15" renamed to "Vol. 10 - Chainsaw" gives
/// "Vol. {volume} - Chainsaw", and `apply` fills it in from each chapter's own name, so "Chainsaw
/// v11 ch 16-20" becomes "Vol. 11 - Chainsaw". The style keeps the example's volume number, chapter
/// number (or range, like 10-15) and the title after them where it used them, and its zero padding.
enum RenameLike {
    /// A number in a name as written ("03", "10-15"), `value` being its first number.
    struct Number: Equatable {
        var text: String
        var value: Double
        var range: NSRange
    }

    /// What a name says: its volume, its chapter, a number with no label, and the title after them.
    struct Parts: Equatable {
        var volume: Number?
        var chapter: Number?
        var bare: Number?
        var title: String?
    }

    enum Piece: Equatable {
        case text(String)
        case volume(pad: Int)
        /// `range` is whether the example kept a range like 10-15 whole, rather than its first number.
        case chapter(pad: Int, range: Bool)
        case title
    }

    /// The pieces a new name is made of, and whether the example was a volume.
    struct Style: Equatable {
        var pieces: [Piece]
        var volume: Bool

        var usesVolume: Bool { pieces.contains { if case .volume = $0 { true } else { false } } }
        var usesChapter: Bool { pieces.contains { if case .chapter = $0 { true } else { false } } }
    }

    struct Renamed: Equatable {
        var name: String
        var number: Double
    }

    private static let num = #"\d+(?:\.\d+)?"#
    private static let range = num + "(?:[-–~]" + num + ")?"
    private static let volumeRegex = regex(#"(?<![\p{L}\d])(?:volume|vol|v)\.?\s*("# + num + ")")
    private static let chapterRegex = regex(#"(?<![\p{L}\d])(?:chapter|chap|ch|c|episode|ep|#)\.?\s*("# + range + ")")
    private static let bareRegex = regex(#"(?<![\p{L}\d.])("# + range + #")(?![\p{L}\d])"#)
    private static let numberRegex = regex(#"(?<![\d.])"# + range + #"(?!\d)"#)
    private static let volumeLabel = regex(#"(?<!\p{L})(?:volume|vol|v)\.?\s*$"#)
    private static let chapterLabel = regex(#"(?<!\p{L})(?:chapter|chap|ch|c|episode|ep|#)\.?\s*$"#)
    private static let rangeSeparators = CharacterSet(charactersIn: "-–~")
    private static let separators = CharacterSet(charactersIn: " \t-–—:·|_,;").union(.whitespaces)

    static func parse(_ name: String, seriesTitle: String) -> Parts {
        let text = name as NSString
        let masked = titleRanges(name, seriesTitle)
        func free(_ range: NSRange) -> Bool { !masked.contains { overlaps($0, range) } }

        let volumeMatch = matches(volumeRegex, name).first { free($0.range) }
        let chapterMatch = matches(chapterRegex, name).first { match in
            free(match.range) && !(volumeMatch.map { overlaps($0.range, match.range) } ?? false)
        }
        let used = [volumeMatch, chapterMatch].compactMap { $0 }
        let bareMatch = matches(bareRegex, name).first { match in
            free(match.range) && !used.contains { overlaps($0.range, match.range) }
        }
        func number(_ match: NSTextCheckingResult) -> Number {
            let range = match.range(at: 1)
            let written = text.substring(with: range)
            return Number(text: written, value: firstValue(written) ?? -1, range: range)
        }
        var title: String?
        if let end = [volumeMatch, chapterMatch, bareMatch].compactMap({ $0.map { NSMaxRange($0.range) } }).max() {
            // Tags like "(2024)" or "[Digital]" after the numbers aren't part of a title.
            var rest = text.substring(from: end)
                .replacingOccurrences(of: #"\s*(?:\([^)]*\)|\[[^\]]*\])"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: separators)
            while rest.hasSuffix(")") || rest.hasSuffix("]") { rest.removeLast() }
            rest = rest.trimmingCharacters(in: separators)
            if !rest.isEmpty, rest.caseInsensitiveCompare(seriesTitle) != .orderedSame { title = rest }
        }
        return Parts(volume: volumeMatch.map(number), chapter: chapterMatch.map(number), bare: bareMatch.map(number), title: title)
    }

    /// The style of `renamed`, which the user renamed from `original` (or named so themselves, if
    /// that's nil), as a volume if `volume`. Nil when it uses neither the volume nor the chapter
    /// number, so every chapter would get the same name.
    static func learn(original: String?, renamed: String, seriesTitle: String, volume: Bool) -> Style? {
        let from = original.flatMap { $0 == renamed ? nil : parse($0, seriesTitle: seriesTitle) }
        let fromVolume = from?.volume ?? (volume && from?.chapter == nil ? from?.bare : nil)
        let fromChapter = from?.chapter ?? (fromVolume != nil && fromVolume == from?.bare ? nil : from?.bare)
        let text = renamed as NSString
        let masked = titleRanges(renamed, seriesTitle)
        var titleRange: NSRange?
        if let title = from?.title, title.count >= 2 {
            let found = text.range(of: title, options: .caseInsensitive)
            if found.location != NSNotFound { titleRange = found }
        }

        var slots: [(range: NSRange, piece: Piece)] = []
        if let titleRange { slots.append((titleRange, .title)) }
        var usedVolume = false
        var usedChapter = false
        for match in matches(numberRegex, renamed) {
            let range = match.range
            if masked.contains(where: { overlaps($0, range) }) || (titleRange.map { overlaps($0, range) } ?? false) { continue }
            let parts = splitRange(text.substring(with: range))
            guard let value = Double(parts[0]) else { continue }
            let isRange = parts.count > 1
            let before = text.substring(to: range.location)
            let label: Bool? = has(volumeLabel, before) ? true : has(chapterLabel, before) ? false : nil
            let asVolume: Bool?
            if from != nil {
                let isVolume = !isRange && fromVolume?.value == value
                let isChapter = fromChapter?.value == value
                asVolume = isVolume && isChapter ? (label ?? (volume && !usedVolume))
                    : isVolume ? true : isChapter ? false : nil
            } else {
                asVolume = label ?? (volume && !usedVolume ? true : !volume && !usedChapter ? false : nil)
            }
            switch asVolume {
            case true?:
                slots.append((range, .volume(pad: padOf(parts[0]))))
                usedVolume = true
            case false?:
                slots.append((range, .chapter(pad: padOf(parts[0]), range: isRange)))
                usedChapter = true
            case nil:
                continue
            }
        }
        guard usedVolume || usedChapter else { return nil }

        var pieces: [Piece] = []
        var position = 0
        for slot in slots.sorted(by: { $0.range.location < $1.range.location }) {
            if slot.range.location < position { continue }
            if slot.range.location > position {
                pieces.append(.text(text.substring(with: NSRange(location: position, length: slot.range.location - position))))
            }
            pieces.append(slot.piece)
            position = NSMaxRange(slot.range)
        }
        if position < text.length { pieces.append(.text(text.substring(from: position))) }
        return Style(pieces: pieces, volume: volume)
    }

    /// `name` in `style`, or nil when it doesn't say the volume or chapter number the style needs.
    static func apply(_ style: Style, to name: String, seriesTitle: String) -> Renamed? {
        let parts = parse(name, seriesTitle: seriesTitle)
        let volume = parts.volume ?? (style.volume && parts.chapter == nil ? parts.bare : nil)
        let chapter = parts.chapter ?? (volume != nil && volume == parts.bare ? nil : parts.bare)
        if style.usesVolume && volume == nil { return nil }
        if style.usesChapter && chapter == nil { return nil }

        var result = ""
        var trimNext = false
        for piece in style.pieces {
            switch piece {
            case .text(let text):
                result += trimNext ? String(text.drop { isSeparator($0) }) : text
            case .volume(let pad):
                result += format(splitRange(volume!.text)[0], pad: pad)
            case .chapter(let pad, let keepsRange):
                let written = chapter!.text
                let numbers = splitRange(written)
                let separator = written.first { $0 == "-" || $0 == "–" || $0 == "~" }.map(String.init) ?? "-"
                result += (keepsRange ? numbers : Array(numbers.prefix(1))).map { format($0, pad: pad) }.joined(separator: separator)
            case .title:
                if let title = parts.title {
                    result += title
                } else {
                    // No title: drop the separator that led up to it, and the one after if it began the name
                    while let last = result.last, isSeparator(last) { result.removeLast() }
                    trimNext = result.isEmpty
                    continue
                }
            }
            trimNext = false
        }
        let newName = result
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: separators)
        guard !newName.isEmpty else { return nil }
        let number: Double = if style.volume, let volume {
            volume.value
        } else if let chapter {
            chapter.value
        } else if let volume {
            volume.value
        } else {
            ChapterNumber.parse(seriesTitle: seriesTitle, chapterName: newName)
        }
        return Renamed(name: newName, number: number)
    }

    /// `name` as a volume ("Vol. 10", or "Vol. 10 - Title" when the name has a title after its
    /// numbers) or a chapter ("Ch. 74-81 - Title"), from the volume or chapter number in it, else
    /// `fallbackNumber`. Nil when there's no number to use.
    static func asKind(_ name: String, seriesTitle: String, volume: Bool, fallbackNumber: Double) -> Renamed? {
        let parts = parse(name, seriesTitle: seriesTitle)
        let found = volume ? (parts.volume ?? (parts.chapter == nil ? parts.bare : nil)) : (parts.chapter ?? parts.bare)
        let written: String
        if let found {
            let numbers = splitRange(found.text)
            let separator = found.text.first { $0 == "-" || $0 == "–" || $0 == "~" }.map(String.init) ?? "-"
            written = (volume ? Array(numbers.prefix(1)) : numbers).map { format($0, pad: 0) }.joined(separator: separator)
        } else if fallbackNumber >= 0 {
            written = formatNumber(fallbackNumber)
        } else {
            return nil
        }
        let label = volume ? "Vol." : "Ch."
        let title = found != nil ? parts.title : nil
        return Renamed(name: title.map { "\(label) \(written) - \($0)" } ?? "\(label) \(written)", number: found?.value ?? fallbackNumber)
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are fixed, so a bad one is a bug caught by the tests.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func has(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// Where `title` appears in `name`, so a number in a series title like "Kaiju No. 8" isn't read
    /// as a chapter.
    private static func titleRanges(_ name: String, _ title: String) -> [NSRange] {
        guard !title.isBlank, title.contains(where: \.isNumber) else { return [] }
        let text = name as NSString
        var ranges: [NSRange] = []
        var search = NSRange(location: 0, length: text.length)
        while true {
            let found = text.range(of: title, options: .caseInsensitive, range: search)
            if found.location == NSNotFound { break }
            ranges.append(found)
            let next = NSMaxRange(found)
            search = NSRange(location: next, length: text.length - next)
        }
        return ranges
    }

    private static func splitRange(_ text: String) -> [String] {
        text.components(separatedBy: rangeSeparators).filter { !$0.isEmpty }
    }

    private static func firstValue(_ text: String) -> Double? { splitRange(text).first.flatMap(Double.init) }

    private static func padOf(_ number: String) -> Int {
        let digits = number.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? number
        return digits.count > 1 && digits.hasPrefix("0") ? digits.count : 0
    }

    private static func format(_ number: String, pad: Int) -> String {
        let pieces = number.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var whole = String(pieces[0].drop { $0 == "0" })
        if whole.isEmpty { whole = "0" }
        if whole.count < pad { whole = String(repeating: "0", count: pad - whole.count) + whole }
        return pieces.count > 1 && !pieces[1].isEmpty ? "\(whole).\(pieces[1])" : whole
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { separators.contains($0) }
    }

    private static func overlaps(_ a: NSRange, _ b: NSRange) -> Bool {
        a.location < NSMaxRange(b) && b.location < NSMaxRange(a)
    }
}
