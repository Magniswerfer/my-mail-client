import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

/// The few things that differ between the Mac and iPhone apps, in one place, so shared views and
/// models stay free of `#if`.
enum Platform {
    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// The user's full name for a new identity (Mac: the login name; iPhone: unknown, so blank).
    static var fullUserName: String {
        #if os(macOS)
        NSFullUserName()
        #else
        ""
        #endif
    }

    static func clipboardString() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }

    /// Whether some app handles this URL (e.g. Things). iOS lists the schemes in Info.plist.
    @MainActor static func canOpen(_ url: URL) -> Bool {
        #if os(macOS)
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        #else
        UIApplication.shared.canOpenURL(url)
        #endif
    }

    static var remindersSettingsHint: String {
        #if os(macOS)
        String(localized: "Allow Reminders access in System Settings › Privacy & Security › Reminders.")
        #else
        String(localized: "Allow Reminders access in Settings › Apps › Tidings › Reminders.")
        #endif
    }

    @MainActor static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    /// Brings the app to the front (a notification was clicked).
    @MainActor static func activateApp() {
        #if os(macOS)
        NSApplication.shared.activate()
        #endif
    }

    @MainActor static func openExternally(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// Where to turn calendar access back on (or why there's none, in the dev copy).
    @MainActor static var calendarSettingsHint: String {
        guard CalendarBridge.shared.isEnabled else {
            return String(localized: "The dev copy doesn't touch your calendar or reminders.")
        }
        #if os(macOS)
        return String(localized: "Allow calendar access in System Settings › Privacy & Security › Calendars.")
        #else
        return String(localized: "Allow calendar access in Settings › Apps › Tidings › Calendars.")
        #endif
    }
}

extension PlatformColor {
    static var tidingsLabel: PlatformColor {
        #if os(macOS)
        .labelColor
        #else
        .label
        #endif
    }

    static var tidingsSecondaryLabel: PlatformColor {
        #if os(macOS)
        .secondaryLabelColor
        #else
        .secondaryLabel
        #endif
    }
}

extension Color {
    /// The window/screen background, for tinted glass that must stay legible.
    static var windowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

/// Bold/italic on fonts, without AppKit's NSFontManager (shared by both editors and the HTML export).
enum FontTraits {
    static func isBold(_ font: PlatformFont) -> Bool {
        #if os(macOS)
        font.fontDescriptor.symbolicTraits.contains(.bold)
        #else
        font.fontDescriptor.symbolicTraits.contains(.traitBold)
        #endif
    }

    static func isItalic(_ font: PlatformFont) -> Bool {
        #if os(macOS)
        font.fontDescriptor.symbolicTraits.contains(.italic)
        #else
        font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        #endif
    }

    static func adding(bold: Bool = false, italic: Bool = false, to font: PlatformFont) -> PlatformFont {
        #if os(macOS)
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
        #else
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }
}

extension View {
    /// A fixed size for Mac sheets and popovers; on iPhone the system sizes them.
    @ViewBuilder func macFrame(width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        #if os(macOS)
        frame(width: width, height: height)
        #else
        self
        #endif
    }

    @ViewBuilder func macFrame(minWidth: CGFloat, minHeight: CGFloat, idealHeight: CGFloat? = nil) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, minHeight: minHeight, idealHeight: idealHeight)
        #else
        self
        #endif
    }

    /// A sheet's buttons. On iPhone they go in the navigation toolbar. On the Mac they sit in a
    /// bar under the content: toolbar items in a sheet opened from another sheet get clipped or
    /// dropped there, and lose Escape and VoiceOver with them.
    @ViewBuilder func sheetButtons<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        #if os(macOS)
        VStack(spacing: 0) {
            self
            Divider()
            HStack(spacing: 8) {
                leading()
                Spacer()
                trailing()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        #else
        toolbar {
            ToolbarItemGroup(placement: .cancellationAction) { leading() }
            ToolbarItemGroup(placement: .primaryAction) { trailing() }
        }
        #endif
    }
}
