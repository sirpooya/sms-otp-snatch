import Foundation

public struct ExtractionResult: Equatable, Sendable {
    /// Which strategy produced the code. Logged (the strategy name only, never
    /// the code) and shown as a confidence hint in the UI.
    public enum Strategy: String, Sendable {
        /// The sender's configured regex matched.
        case senderPattern
        /// The Apple/WebOTP domain-bound line matched: `@example.com #123456`.
        case domainBound
        /// A digit run sat immediately after an OTP keyword.
        case keywordAnchored
        /// Nothing anchored it; it was the only plausible digit run left.
        case standalone
    }

    public let code: String
    public let strategy: Strategy

    public init(code: String, strategy: Strategy) {
        self.code = code
        self.strategy = strategy
    }
}

/// Pulls a one-time code out of an SMS body.
///
/// This is deliberately not "one regex". Iranian OTP messages routinely carry
/// three or four other digit runs that a naive `\b(\d{4,8})\b` grabs first: a
/// transaction amount, a validity window (`12:34:56`), a USSD string
/// (`*140*11`), a URL with digits in the path, a support line number, or a
/// promo code. Every rejection rule below exists because a real message in the
/// corpus would otherwise yield the wrong answer.
///
/// Strategy order is confidence order: an authoritative per-sender pattern, then
/// the standardized domain-bound line, then keyword anchoring, then a last
/// resort.
public enum CodeExtractor {

    public static let minDigits = 4
    public static let maxDigits = 8

    // MARK: - Cue tables
    //
    // Cues are matched against the *normalized* body, so all spellings here use
    // Persian yeh/kaf and ASCII digits, and none contain ZWNJ. Longest match at
    // a given position wins, which is what makes "کد تخفیف" (discount code,
    // negative) beat "کد" (code, positive).

    private static let positiveCues: [String] = [
        // Persian
        "رمز یکبار مصرف", "رمز یک بار مصرف", "رمز پویا", "رمز دوم", "رمز عبور", "رمز",
        "کد یکبار مصرف", "کد یک بار مصرف", "کد تایید", "کد ورود", "کد فعالسازی",
        "کد فعال سازی", "کد امنیتی", "کد احراز هویت", "کد اعتبارسنجی", "کد",
        "شناسه ورود",
        // Latin
        "verification code", "one-time code", "one time code", "one-time password",
        "security code", "access code", "auth code", "login code", "passcode",
        "verification", "code", "otp", "pin",
    ]

    private static let negativeCues: [String] = [
        // Phrases that look like a code cue but are not.
        "کد تخفیف", "کدتخفیف", "کد دستوری", "کددستوری", "کد پیگیری", "کد رهگیری",
        "کد معرف", "کد شارژ", "رمز کارت شارژ", "کارت شارژ", "کد بن", "کد فروشگاه",
        "discount code", "promo code", "coupon",
        // Money and quantity.
        "مبلغ", "قیمت", "بدهی", "موجودی", "مانده", "سقف", "ریال", "تومان", "تومن",
        "درصد", "هزار", "میلیون", "میلیارد",
        // Identifiers that are not codes.
        "شماره گیری", "شمارهگیری", "شماره", "تلفن", "تماس", "کارت", "حساب", "شبا",
        "پیگیری", "سفارش", "پشتیبانی", "صندوق",
        // Time, dates, volumes, marketing.
        "اعتبار", "زمان", "مهلت", "ساعت", "تاریخ", "حجم", "بسته", "گیگ", "مگ",
        "دقیقه", "ثانیه", "تخفیف", "هدیه", "لغو",
    ]

    /// Words that, when they *follow* a digit run closely, prove it was a
    /// quantity rather than a code. Persian reads "مبلغ 500000 ریال", so the
    /// unit trails the number.
    private static let trailingUnits: [String] = [
        "ریال", "تومان", "تومن", "درصد", "%", "گیگابایت", "گیگ", "مگابایت", "مگ",
        "دقیقه", "ثانیه", "روزه", "روز", "ماهه", "ماه", "ساله", "سال", "بار",
        "هزار", "میلیون", "میلیارد", "نفر", "امتیاز",
    ]

    /// How far back a cue may sit and still be considered to govern a digit run.
    /// Wide enough for "کد ورود شما به هومکا:\nCode: " style preambles, narrow
    /// enough that an unrelated earlier line does not claim the run.
    private static let cueWindow = 28

    /// How far ahead a trailing unit may sit and still disqualify a run.
    private static let unitWindow = 8

    // MARK: - Entry point

    public static func extract(from rawBody: String, rule: SenderRule? = nil) -> ExtractionResult? {
        let normalized = DigitNormalizer.normalize(rawBody)
        let chars = Array(normalized)

        // 1. A configured pattern is authoritative. If the user wrote a regex
        //    for this sender and it does not match, we return nil rather than
        //    guessing with the generic strategies: the whole point of the
        //    override is to stop us grabbing the wrong number.
        // An unparseable pattern is treated as absent rather than as a veto,
        // so a typo in config.json degrades to the generic strategies instead
        // of silently disabling the sender.
        if let pattern = rule?.pattern, !pattern.isEmpty,
           let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            return matchSenderPattern(regex, in: normalized)
                .map { ExtractionResult(code: $0, strategy: .senderPattern) }
        }

        let tokens = tokenize(chars)
        let urlRanges = tokens.filter { isURLLike($0.text) }.map(\.range)

        // 2. The standardized domain-bound line, e.g.
        //    "@auth.digikala.com #12345". When a sender emits it, it is the
        //    single most reliable signal in the message.
        if let code = domainBoundCode(tokens: tokens) {
            return ExtractionResult(code: code, strategy: .domainBound)
        }

        let runs = digitRuns(in: chars).filter {
            isPlausible($0, chars: chars, urlRanges: urlRanges)
        }
        if runs.isEmpty { return nil }

        let cueList = cues(in: chars, extraPositive: rule?.keywords ?? [])

        // 3. Keyword anchoring: the nearest cue *before* the run decides. A
        //    negative cue vetoes the run outright, which is how the amount in a
        //    bank OTP gets dropped while the code two lines later survives.
        var anchored: [(run: DigitRun, gap: Int)] = []
        for run in runs {
            guard let cue = nearestPrecedingCue(cueList, before: run.range.lowerBound) else { continue }
            let gap = run.range.lowerBound - cue.range.upperBound
            guard gap <= cueWindow else { continue }
            if cue.positive {
                anchored.append((run, gap))
            }
            // A negative nearest-cue means this run is vetoed: it is not added
            // here, and `vetoed` below keeps it out of the fallback too.
        }
        if let best = anchored.min(by: { lhs, rhs in
            if lhs.gap != rhs.gap { return lhs.gap < rhs.gap }
            return lengthRank(lhs.run) < lengthRank(rhs.run)
        }) {
            return ExtractionResult(code: best.run.text, strategy: .keywordAnchored)
        }

        // 4. Last resort: no cue anchored anything, so take the most
        //    code-shaped run that no negative cue vetoed. This is what catches
        //    "G-123456 is your Google verification code", where the keyword
        //    trails the code instead of leading it.
        let survivors = runs.filter { run in
            guard let cue = nearestPrecedingCue(cueList, before: run.range.lowerBound) else { return true }
            let gap = run.range.lowerBound - cue.range.upperBound
            guard gap <= cueWindow else { return true }
            return cue.positive
        }
        guard let best = survivors.min(by: { lhs, rhs in
            let l = lengthRank(lhs), r = lengthRank(rhs)
            if l != r { return l < r }
            return lhs.range.lowerBound < rhs.range.lowerBound
        }) else { return nil }
        return ExtractionResult(code: best.text, strategy: .standalone)
    }

    // MARK: - Sender pattern

    private static func matchSenderPattern(_ regex: NSRegularExpression, in normalized: String) -> String? {
        let ns = normalized as NSString
        guard let m = regex.firstMatch(in: normalized, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        // Prefer the first capture group; fall back to the whole match.
        let range = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound
            ? m.range(at: 1)
            : m.range
        let candidate = ns.substring(with: range)
        let digits = candidate.filter { $0.isASCII && $0.isNumber }
        guard digits.count == candidate.count,
              (minDigits...maxDigits).contains(digits.count) else { return nil }
        return digits
    }

    // MARK: - Digit runs

    struct DigitRun {
        let range: Range<Int>
        let text: String
    }

    private static func digitRuns(in chars: [Character]) -> [DigitRun] {
        var runs: [DigitRun] = []
        var i = 0
        while i < chars.count {
            guard isASCIIDigit(chars[i]) else { i += 1; continue }
            var j = i
            while j < chars.count, isASCIIDigit(chars[j]) { j += 1 }
            runs.append(DigitRun(range: i..<j, text: String(chars[i..<j])))
            i = j
        }
        return runs
    }

    /// Length preference: real OTPs cluster at 6 then 5 digits. Ranks lower is
    /// better.
    private static func lengthRank(_ run: DigitRun) -> Int {
        switch run.text.count {
        case 6: return 0
        case 5: return 1
        case 4: return 2
        case 7: return 3
        default: return 4
        }
    }

    private static func isPlausible(_ run: DigitRun, chars: [Character], urlRanges: [Range<Int>]) -> Bool {
        let len = run.text.count
        guard (minDigits...maxDigits).contains(len) else { return false }

        // Inside a URL: the digits belong to a path or a shortlink slug.
        if urlRanges.contains(where: { $0.lowerBound <= run.range.lowerBound && run.range.upperBound <= $0.upperBound }) {
            return false
        }

        let before: Character? = run.range.lowerBound > 0 ? chars[run.range.lowerBound - 1] : nil
        let after: Character? = run.range.upperBound < chars.count ? chars[run.range.upperBound] : nil

        // Part of a longer alphanumeric token: a promo code like "A1RT12345678"
        // or a shortlink slug like "EAT1C22".
        if let b = before, b.isLetter { return false }
        if let a = after, a.isLetter { return false }

        // A time such as "12:34:56", or a clock validity window.
        if before == ":" || after == ":" { return false }

        // A USSD string such as "*140*11" or "#123*".
        if before == "*" || after == "*" { return false }
        // A "#123456" token is either a USSD tail or the domain-bound duplicate
        // of the code, and the domain-bound strategy already ran by this point.
        if before == "#" || after == "#" { return false }

        // A date or a path fragment: "1404/05/30".
        if before == "/" || after == "/" { return false }

        // A grouped number: "12,345,678" or "1.234.567". The separator only
        // disqualifies when a digit sits on its far side, so a code ending a
        // sentence ("رمز 123456.") still counts.
        if isGroupingSeparator(before, neighbor: run.range.lowerBound >= 2 ? chars[run.range.lowerBound - 2] : nil) { return false }
        if isGroupingSeparator(after, neighbor: run.range.upperBound + 1 < chars.count ? chars[run.range.upperBound + 1] : nil) { return false }

        // A trailing unit proves it was a quantity: "500000 ریال", "30 روزه".
        if hasTrailingUnit(after: run.range.upperBound, chars: chars) { return false }

        return true
    }

    private static func isGroupingSeparator(_ ch: Character?, neighbor: Character?) -> Bool {
        guard let ch, ch == "," || ch == "." else { return false }
        guard let neighbor else { return false }
        return isASCIIDigit(neighbor)
    }

    private static func hasTrailingUnit(after index: Int, chars: [Character]) -> Bool {
        var i = index
        let limit = min(chars.count, index + unitWindow)
        while i < limit {
            if chars[i].isWhitespace || chars[i] == ":" { i += 1; continue }
            for unit in trailingUnits where matches(chars, at: i, phrase: unit) {
                return true
            }
            // Only the first non-space token after the run counts as its unit.
            return false
        }
        return false
    }

    // MARK: - Cues

    private struct Cue {
        let range: Range<Int>
        let positive: Bool
    }

    private static func cues(in chars: [Character], extraPositive: [String]) -> [Cue] {
        // Longest phrase first, so "کد تخفیف" is tested before "کد".
        let positives = (positiveCues + extraPositive.map { DigitNormalizer.normalize($0).lowercased() })
            .sorted { $0.count > $1.count }
        let negatives = negativeCues.sorted { $0.count > $1.count }

        var found: [Cue] = []
        var i = 0
        while i < chars.count {
            var hit: (len: Int, positive: Bool)? = nil
            // Negatives and positives compete on length; ties go to the
            // negative, which keeps "کد تخفیف" from being read as "کد".
            for phrase in negatives where matches(chars, at: i, phrase: phrase) {
                hit = (phrase.count, false); break
            }
            for phrase in positives where matches(chars, at: i, phrase: phrase) {
                if hit == nil || phrase.count > hit!.len { hit = (phrase.count, true) }
                break
            }
            if let hit {
                found.append(Cue(range: i..<(i + hit.len), positive: hit.positive))
                i += hit.len
            } else {
                i += 1
            }
        }
        return found
    }

    private static func nearestPrecedingCue(_ cues: [Cue], before index: Int) -> Cue? {
        var best: Cue? = nil
        for cue in cues where cue.range.upperBound <= index {
            if best == nil || cue.range.upperBound > best!.range.upperBound { best = cue }
        }
        return best
    }

    // MARK: - Tokens and URLs

    struct Token {
        let range: Range<Int>
        let text: String
    }

    private static func tokenize(_ chars: [Character]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            guard !chars[i].isWhitespace else { i += 1; continue }
            var j = i
            while j < chars.count, !chars[j].isWhitespace { j += 1 }
            tokens.append(Token(range: i..<j, text: String(chars[i..<j])))
            i = j
        }
        return tokens
    }

    /// Heuristic, not a validator. A token counts as a URL when it carries a
    /// scheme, or when it looks like `host.tld[/path]` with at least two
    /// letters in the TLD position. That last condition is what keeps
    /// "1.234.567" out.
    private static func isURLLike(_ token: String) -> Bool {
        if token.contains("://") { return true }
        guard let lastDot = token.lastIndex(of: ".") else { return false }
        let tail = token[token.index(after: lastDot)...]
        let leadingLetters = tail.prefix { $0.isLetter && $0.isASCII }
        guard leadingLetters.count >= 2 else { return false }
        // Require something host-like before the dot.
        let head = token[token.startIndex..<lastDot]
        return head.contains { $0.isLetter || $0.isNumber }
    }

    /// The Apple/WebOTP domain-bound format: a line ending in
    /// `@example.com #123456`. Observed on Digikala, Snapp, Wallgold and others.
    /// The hash token is the code repeated, which makes it unambiguous.
    private static func domainBoundCode(tokens: [Token]) -> String? {
        for (index, token) in tokens.enumerated() where token.text.hasPrefix("@") && token.text.count > 1 {
            guard index + 1 < tokens.count else { continue }
            let next = tokens[index + 1].text
            guard next.hasPrefix("#") else { continue }
            let digits = String(next.dropFirst())
            guard !digits.isEmpty,
                  digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  (minDigits...maxDigits).contains(digits.count) else { continue }
            return digits
        }
        return nil
    }

    // MARK: - Small helpers

    private static func matches(_ chars: [Character], at index: Int, phrase: String) -> Bool {
        let phraseChars = Array(phrase)
        guard index + phraseChars.count <= chars.count else { return false }
        for (offset, pc) in phraseChars.enumerated() {
            let c = chars[index + offset]
            if c == pc { continue }
            if c.lowercased() == pc.lowercased() { continue }
            return false
        }
        return true
    }

    private static func isASCIIDigit(_ c: Character) -> Bool {
        c.isASCII && c.isNumber
    }
}
