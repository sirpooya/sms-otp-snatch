import Foundation

/// Normalizes SMS bodies so that digit extraction and keyword matching can
/// assume plain ASCII digits and a single spelling of each Persian letter.
///
/// Every transform here exists because it was observed in real traffic:
///
/// - Persian and Arabic-Indic digits: senders mix all three digit families,
///   sometimes inside one message.
/// - Bidi controls and ZWNJ: Persian SMS is full of them, and bad senders put
///   them *inside* a number, which splits an otherwise contiguous code.
/// - Arabic yeh/kaf: Iranian bank gateways commonly emit `ريال` and `خريد`
///   with U+064A / U+0643 rather than the Persian U+06CC / U+06A9. Without
///   folding these, keyword and unit matching silently misses those senders.
public enum DigitNormalizer {

    /// Characters removed outright.
    ///
    /// U+200C (ZWNJ) is stripped per the spec, which means words can fuse
    /// (`همراه‌من` becomes `همراهمن`). That is acceptable because the normalized
    /// string is only ever used for matching, never displayed, and keyword
    /// tables below carry both spaced and unspaced spellings.
    private static let stripped: Set<UInt32> = [
        0x200C,           // ZERO WIDTH NON-JOINER
        0x200D,           // ZERO WIDTH JOINER
        0x200E, 0x200F,   // LRM, RLM
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E, // LRE, RLE, PDF, LRO, RLO
        0x2066, 0x2067, 0x2068, 0x2069,         // LRI, RLI, FSI, PDI
        0xFEFF,           // ZERO WIDTH NO-BREAK SPACE / BOM
        0x0640,           // ARABIC TATWEEL (decorative elongation)
    ]

    public static func normalize(_ input: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(input.unicodeScalars.count)

        for scalar in input.unicodeScalars {
            let v = scalar.value

            if stripped.contains(v) { continue }

            switch v {
            case 0x0660...0x0669:               // Arabic-Indic ٠١٢٣٤٥٦٧٨٩
                out.append(asciiDigit(v - 0x0660))
            case 0x06F0...0x06F9:               // Extended Arabic-Indic ۰۱۲۳۴۵۶۷۸۹
                out.append(asciiDigit(v - 0x06F0))
            case 0x0643:                        // ARABIC KAF -> KEHEH
                out.append(Unicode.Scalar(0x06A9)!)
            case 0x0649, 0x064A:                // ALEF MAKSURA, ARABIC YEH -> FARSI YEH
                out.append(Unicode.Scalar(0x06CC)!)
            case 0x0622, 0x0623, 0x0625:        // ALEF WITH MADDA/HAMZA -> ALEF
                out.append(Unicode.Scalar(0x0627)!)
            case 0x0629:                        // TEH MARBUTA -> HEH
                out.append(Unicode.Scalar(0x0647)!)
            case 0x06C0:                        // HEH WITH YEH ABOVE -> HEH
                out.append(Unicode.Scalar(0x0647)!)
            case 0x00A0, 0x2007, 0x202F, 0x2060: // non-breaking spaces -> plain space
                out.append(" ")
            case 0x066B:                        // ARABIC DECIMAL SEPARATOR -> '.'
                out.append(".")
            case 0x066C:                        // ARABIC THOUSANDS SEPARATOR -> ','
                out.append(",")
            case 0x060C:                        // ARABIC COMMA -> ','
                out.append(",")
            case 0x066A:                        // ARABIC PERCENT SIGN -> '%'
                out.append("%")
            default:
                out.append(scalar)
            }
        }

        return String(out)
    }

    private static func asciiDigit(_ offset: UInt32) -> Unicode.Scalar {
        Unicode.Scalar(0x30 + offset)!
    }
}
