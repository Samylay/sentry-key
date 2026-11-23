/// Checks text before the phone shows it in an approval prompt.
///
/// The user name in a login request comes from the Mac, which we do not
/// trust. A compromised Mac could hide part of a name with invisible
/// characters, or reorder it with bidirectional overrides (for example to
/// show `deploy` while the real name is something else). The phone refuses
/// such text instead of trying to clean it.
public enum DisplayText {
    /// True when `text` is non-empty, at most `maxLength` characters, and
    /// has no control, format (invisible, bidi) or separator characters
    /// other than the plain space.
    public static func isSafe(_ text: String, maxLength: Int) -> Bool {
        guard !text.isEmpty, text.count <= maxLength else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            if scalar == " " { return true }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned,
                 .lineSeparator, .paragraphSeparator, .spaceSeparator:
                return false
            default:
                return true
            }
        }
    }
}
