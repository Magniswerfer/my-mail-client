import Foundation

/// Keeps text that came from (or goes into) a header on one line.
///
/// A sender controls decoded header text: `=?utf-8?Q?Hi=0D=0ABcc:_x@evil?=` decodes to a subject
/// with a line break in it. If that reached an outgoing header unchanged (a reply's "Re: …", a
/// reaction, an invite answer), the sender would be writing headers, or a whole body, into mail
/// sent as the user. Everything that builds headers or SMTP commands goes through here.
public enum HeaderText {
    /// The text with every control character (CR, LF, tab, NUL, DEL, C1, and the Unicode line and
    /// paragraph separators) turned into a space.
    public static func singleLine(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: isControl) else { return s }
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars { out.append(isControl(scalar) ? " " : scalar) }
        return String(out)
    }

    /// An address, Message-ID or Content-ID for use between `<` and `>`: no controls, no spaces,
    /// no angle brackets, no commas.
    public static func token(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !isControl($0) && !" <>,".unicodeScalars.contains($0) }))
    }

    /// True when the address is safe to put in a header or an SMTP command as-is.
    public static func isSafeAddress(_ s: String) -> Bool {
        !s.isEmpty && s.contains("@") && token(s) == s && !s.contains("\"") && !s.contains(";")
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029: return true
        default: return false
        }
    }
}
