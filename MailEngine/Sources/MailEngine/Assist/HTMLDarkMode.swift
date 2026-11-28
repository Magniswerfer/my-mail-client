import Foundation

/// Dark mode for message bodies: plain and lightly-styled mail is recoloured to match the
/// system; designed mail (its own background colours) keeps its colours on a light card.
public enum HTMLDarkMode {
    /// True when the HTML sets no background colours other than white-ish or transparent.
    public static func canDarken(_ html: String) -> Bool {
        let lower = html.lowercased()
        var values: [String] = []
        for m in lower.matches(of: /bgcolor\s*=\s*["']?([^"'\s>]+)/) { values.append(String(m.output.1)) }
        for m in lower.matches(of: /background(?:-color)?\s*:\s*([^;"'}]+)/) { values.append(String(m.output.1)) }
        return values.allSatisfy(isLightOrClear)
    }

    static func isLightOrClear(_ raw: String) -> Bool {
        let v = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "!important", with: "")
            .trimmingCharacters(in: .whitespaces)
        if ["white", "transparent", "none", "inherit", "initial", "unset", "#fff", "#ffffff", "#fefefe", "#fdfdfd", "#fcfcfc"].contains(v) { return true }
        if v.hasPrefix("url(") { return false }
        if let (r, g, b, a) = rgba(v) { return a < 0.05 || (0.2126 * r + 0.7152 * g + 0.0722 * b) > 0.97 }
        return false
    }

    /// #rgb, #rrggbb, rgb(…), rgba(…) → 0…1 components.
    static func rgba(_ v: String) -> (Double, Double, Double, Double)? {
        let first = v.split(separator: " ").first.map(String.init) ?? v
        if first.hasPrefix("#") {
            var hex = String(first.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let n = UInt64(hex, radix: 16) else { return nil }
            let shift = hex.count == 8 ? 8 : 0
            let alpha = hex.count == 8 ? Double(n & 0xFF) / 255 : 1
            return (Double((n >> (16 + shift)) & 0xFF) / 255, Double((n >> (8 + shift)) & 0xFF) / 255,
                    Double((n >> shift) & 0xFF) / 255, alpha)
        }
        guard let open = v.firstIndex(of: "("), let close = v.firstIndex(of: ")"), v.hasPrefix("rgb") else { return nil }
        let parts = v[v.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .compactMap { Double($0.replacingOccurrences(of: "%", with: "")) }
        guard parts.count >= 3 else { return nil }
        return (parts[0] / 255, parts[1] / 255, parts[2] / 255, parts.count > 3 ? parts[3] : 1)
    }

    /// CSS that recolours a darkenable message for dark mode.
    public static let darkCSS = """
        :root { color-scheme: dark; }
        html, body { background: transparent !important; color: #e8e8ea !important; }
        body * { color: inherit !important; background-color: transparent !important; border-color: #48484a !important; }
        a, a * { color: #64aaff !important; }
        blockquote { border-left: 2px solid #48484a !important; color: #a1a1a6 !important; }
        hr { border-color: #48484a !important; }
        """
}
