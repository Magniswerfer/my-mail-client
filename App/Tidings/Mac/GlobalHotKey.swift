#if os(macOS)
import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut (SPEC §5: "Global hotkey: copy latest OTP"). Carbon's hot key API
/// works in the sandbox and needs no Accessibility permission.
@MainActor final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var ref: EventHotKeyRef?
    private var installed = false
    nonisolated(unsafe) private static var action: (@MainActor () -> Void)?
    /// "TDNG": identifies Tidings' hot keys to Carbon.
    private static let signature = OSType(0x5444_4E47)

    /// ⌃⌥C → Copy Latest Login Code.
    func registerCopyCode(_ action: @escaping @MainActor () -> Void) {
        Self.action = action
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.action?() } }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        guard ref == nil else { return }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}
#endif
