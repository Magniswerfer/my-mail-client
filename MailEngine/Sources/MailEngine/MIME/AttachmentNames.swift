import Foundation

/// Attachment filenames come from the sender. They are shown, and used as names on disk.
public enum AttachmentNames {
    /// Characters that reorder or hide text: an RTL override makes `invoice‮fdp.command` show
    /// as a PDF. Removed, with control characters, everywhere a filename appears.
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0x061C, 0xFEFF, 0x180E: return true
        default: return HeaderText.isControl(scalar)
        }
    }

    /// A name that shows what it is and is safe as a file name: no direction overrides or
    /// invisible characters, no path separators, never `.`/`..` or a leading dot, at most 200
    /// characters (the extension kept), never empty.
    public static func sanitize(_ raw: String) -> String {
        var name = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !isInvisible($0) }))
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        if name.count > 200 {
            let ext = (name as NSString).pathExtension
            let keep = ext.isEmpty || ext.count > 16 ? "" : "." + ext
            name = String(name.prefix(200 - keep.count)) + keep
        }
        return name.isEmpty ? "attachment" : name
    }

    /// Extensions that run code, install software or point somewhere else when opened.
    public static let riskyExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "bash", "zsh", "csh", "ksh", "fish", "py", "pl", "rb", "php", "js", "jse",
        "pkg", "mpkg", "dmg", "iso", "img", "sparseimage", "jar", "class", "scpt", "scptd", "applescript", "workflow",
        "action", "shortcut", "webloc", "inetloc", "fileloc", "url", "desktop", "plugin", "kext", "bundle", "framework",
        "dylib", "so", "prefpane", "saver", "osax", "mobileconfig", "configprofile", "exe", "msi", "bat", "cmd", "com", "scr",
        "ps1", "vbs", "lnk", "hta", "reg", "html", "htm", "svg", "xhtml", "shtml", "mht",
    ]

    /// True when opening the file could do more than show a document.
    public static func isRisky(_ filename: String) -> Bool {
        riskyExtensions.contains((sanitize(filename) as NSString).pathExtension.lowercased())
    }
}
