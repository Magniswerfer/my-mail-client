import Foundation

/// Linear-time scans over untrusted HTML.
///
/// Lazy regexes like `<a[^>]*>(.*?)</a>` rescan to the end of the text from every unclosed
/// `<a`, so a 2 MB message of `<a<a<a…` costs ~10^12 steps and stalls whatever runs it (sync,
/// the reader). These scans move forward only.
public enum HTMLScan {
    /// One `<tag …>inner</tag>` element.
    public struct Element: Sendable {
        /// The opening tag, `<a href="…">`.
        public var open: String
        /// What's between the opening and closing tags (raw HTML).
        public var inner: String
    }

    /// Every closed `<tag …>…</tag>` element, in order. Elements without a closing tag are
    /// skipped (and, as there is no later closing tag, so is everything after them).
    public static func elements(_ tag: String, in html: String) -> [Element] {
        let b = Array(html.utf8)
        let open = Array("<\(tag.lowercased())".utf8)
        let close = Array("</\(tag.lowercased())".utf8)
        var result: [Element] = []
        var i = 0
        while let start = find(open, in: b, from: i, boundary: true) {
            guard let gt = b[(start + open.count)...].firstIndex(of: UInt8(ascii: ">")) else { break }
            guard let end = find(close, in: b, from: gt + 1, boundary: true) else { break }
            result.append(Element(open: String(decoding: b[start...gt], as: UTF8.self),
                                  inner: String(decoding: b[(gt + 1)..<end], as: UTF8.self)))
            i = (b[end...].firstIndex(of: UInt8(ascii: ">")) ?? (b.count - 1)) + 1
        }
        return result
    }

    /// The HTML without these elements (opening tag through closing tag). An unclosed one is
    /// left in place, as the old regex left it.
    public static func removingElements(_ tags: [String], from html: String) -> String {
        var s = html
        for tag in tags { s = removing(open: "<\(tag.lowercased())", close: "</\(tag.lowercased())", closeEnd: true, from: s, boundary: true) }
        return s
    }

    /// The HTML without `<!-- … -->` comments (an unclosed one is left in place).
    public static func removingComments(from html: String) -> String {
        removing(open: "<!--", close: "-->", closeEnd: false, from: html, boundary: false)
    }

    /// Replaces each `open … close` span with a space, scanning forward only.
    static func removing(open: String, close: String, closeEnd: Bool, from html: String, boundary: Bool) -> String {
        let b = Array(html.utf8)
        let o = Array(open.utf8), c = Array(close.utf8)
        guard find(o, in: b, from: 0, boundary: boundary) != nil else { return html }
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while let start = find(o, in: b, from: i, boundary: boundary) {
            out.append(contentsOf: b[i..<start])
            out.append(UInt8(ascii: " "))
            // Unclosed: keep the rest as it is (no later closing tag exists either).
            guard let end = find(c, in: b, from: start + o.count, boundary: boundary) else { i = start; break }
            var next = end + c.count
            if closeEnd, let gt = b[min(next, b.count)...].firstIndex(of: UInt8(ascii: ">")) { next = gt + 1 }
            i = min(next, b.count)
        }
        if i < b.count { out.append(contentsOf: b[i...]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// The first case-insensitive (ASCII) occurrence of `needle` at or after `from`. With
    /// `boundary`, the next byte must end a tag name (`<a` doesn't match `<abbr`).
    static func find(_ needle: [UInt8], in b: [UInt8], from: Int, boundary: Bool) -> Int? {
        guard !needle.isEmpty, from >= 0, b.count >= needle.count else { return nil }
        var i = from
        let last = b.count - needle.count
        while i <= last {
            var matched = true
            for k in 0..<needle.count where lower(b[i + k]) != needle[k] { matched = false; break }
            if matched {
                let after = i + needle.count
                if !boundary || after >= b.count || !isNameByte(b[after]) { return i }
            }
            i += 1
        }
        return nil
    }

    @inline(__always) static func lower(_ c: UInt8) -> UInt8 { (65...90).contains(c) ? c + 32 : c }
    @inline(__always) static func isNameByte(_ c: UInt8) -> Bool {
        (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == UInt8(ascii: "-") || c == UInt8(ascii: ":")
    }
}
