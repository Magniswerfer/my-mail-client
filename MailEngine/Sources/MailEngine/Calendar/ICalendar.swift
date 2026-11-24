import Foundation

/// A minimal RFC 5545 reader: content lines → nested components with properties and parameters.
/// It is lenient (invites in the wild are often slightly off) and only knows the syntax; the
/// meaning lives in `CalendarInvite`.
public struct ICalComponent: Sendable, Hashable {
    public var name: String
    public var properties: [ICalProperty]
    public var children: [ICalComponent]

    public func property(_ name: String) -> ICalProperty? {
        properties.first { $0.name == name }
    }

    public func properties(_ name: String) -> [ICalProperty] {
        properties.filter { $0.name == name }
    }

    public func children(_ name: String) -> [ICalComponent] {
        children.filter { $0.name == name }
    }
}

public struct ICalProperty: Sendable, Hashable {
    /// Upper-cased name, e.g. `DTSTART`.
    public var name: String
    /// Upper-cased parameter names; values unquoted.
    public var parameters: [String: String]
    /// The raw value (still escaped for TEXT values; use `text` for those).
    public var value: String

    public func parameter(_ name: String) -> String? { parameters[name] }

    /// The value as TEXT: `\n`, `\,`, `\;` and `\\` unescaped.
    public var text: String { ICalendar.unescape(value) }
}

public enum ICalendar {
    /// Parses a VCALENDAR (or any component stream). Returns the top-level components.
    public static func parse(_ source: String) -> [ICalComponent] {
        var stack: [ICalComponent] = []
        var roots: [ICalComponent] = []
        for line in unfold(source) {
            guard let property = parseLine(line) else { continue }
            switch property.name {
            case "BEGIN":
                stack.append(ICalComponent(name: property.value.uppercased().trimmingCharacters(in: .whitespaces),
                                           properties: [], children: []))
            case "END":
                guard let done = stack.popLast() else { continue }
                if stack.isEmpty { roots.append(done) } else { stack[stack.count - 1].children.append(done) }
            default:
                if !stack.isEmpty { stack[stack.count - 1].properties.append(property) }
            }
        }
        // Tolerate a missing END: keep what we have.
        while let open = stack.popLast() {
            if stack.isEmpty { roots.append(open) } else { stack[stack.count - 1].children.append(open) }
        }
        return roots
    }

    /// Joins folded lines (a line starting with a space or tab continues the previous one).
    static func unfold(_ source: String) -> [String] {
        var lines: [String] = []
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(String(raw))
            }
        }
        return lines
    }

    /// `NAME;PARAM=a;PARAM2="b:c":value` — colons and semicolons inside quotes don't split.
    static func parseLine(_ line: String) -> ICalProperty? {
        var name = ""
        var parameters: [String: String] = [:]
        var index = line.startIndex
        // Name.
        while index < line.endIndex, line[index] != ";", line[index] != ":" {
            name.append(line[index]); index = line.index(after: index)
        }
        guard !name.isEmpty, index < line.endIndex else { return nil }
        // Parameters.
        while index < line.endIndex, line[index] == ";" {
            index = line.index(after: index)
            var key = ""
            while index < line.endIndex, line[index] != "=", line[index] != ";", line[index] != ":" {
                key.append(line[index]); index = line.index(after: index)
            }
            var value = ""
            if index < line.endIndex, line[index] == "=" {
                index = line.index(after: index)
                var quoted = false
                while index < line.endIndex {
                    let c = line[index]
                    if c == "\"" { quoted.toggle() } else if !quoted, c == ";" || c == ":" { break } else { value.append(c) }
                    index = line.index(after: index)
                }
            }
            if !key.isEmpty { parameters[key.uppercased().trimmingCharacters(in: .whitespaces)] = value }
        }
        guard index < line.endIndex, line[index] == ":" else { return nil }
        let value = String(line[line.index(after: index)...])
        return ICalProperty(name: name.uppercased().trimmingCharacters(in: .whitespaces), parameters: parameters, value: value)
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var escaping = false
        for c in s {
            if escaping {
                switch c {
                case "n", "N": out.append("\n")
                default: out.append(c)       // \, \; \\ and anything unknown → the character
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Folds a content line at 75 octets without splitting a UTF-8 sequence (RFC 5545 §3.1).
    static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var out = ""
        var current = ""
        var limit = 75
        for ch in line {
            if current.utf8.count + String(ch).utf8.count > limit {
                out += current + "\r\n "
                current = ""
                limit = 74   // the leading space counts
            }
            current.append(ch)
        }
        return out + current
    }
}
