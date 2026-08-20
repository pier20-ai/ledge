import AppKit
import Carbon.HIToolbox

/// ⌃⌥Space → the notch, from anywhere (G3, Manu's ask: "trigger the notch
/// open without hover").
///
/// `RegisterEventHotKey`, not an `NSEvent` global monitor, for two reasons
/// that matter here: the Carbon registration needs **no** Accessibility or
/// Input Monitoring consent (a monitor needs both to see keys), and it
/// *consumes* the chord — Space does not also land in whatever app is
/// frontmost, which for a key pressed mid-meeting is the whole job.
///
/// One fixed chord for now. The moment a second binding exists this grows a
/// table and Settings grows a row; until then a "configurable" single hotkey
/// would be a preference nobody asked for wearing code three times this size.
@MainActor
final class HotkeyCenter {
    /// The chord: ⌃⌥Space. Space is `kVK_Space`; the modifier mask is
    /// Carbon's, not `NSEvent`'s — the two disagree on every bit.
    private static let keyCode = UInt32(kVK_Space)
    private static let modifiers = UInt32(controlKey | optionKey)
    private static let signature = OSType(0x4C44_4745) // 'LDGE'

    /// `nonisolated(unsafe)` for the deinit's sake: both are written once in
    /// init (on main) and read once in deinit, and Carbon refs are not
    /// Sendable in the compiler's eyes however single-threaded their life is.
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    /// Registration can fail (another app holds the chord); the shell then
    /// simply has no hotkey, which is worth one log line and nothing else.
    init(onPress: @escaping () -> Void) {
        self.onPress = onPress

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // The context pointer rides the C callback; `self` outlives the
        // handler because deinit unregisters it.
        let context = Unmanaged.passUnretained(self).toOpaque()
        var installed: EventHandlerRef?
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, context -> OSStatus in
                guard let context else { return noErr }
                let center = Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue()
                // Carbon dispatches on the main thread; the assumption makes
                // that a checked fact rather than a comment.
                MainActor.assumeIsolated { center.onPress() }
                return noErr
            },
            1,
            &eventType,
            context,
            &installed
        )
        handlerRef = installed

        var registered: EventHotKeyRef?
        let status = RegisterEventHotKey(
            Self.keyCode,
            Self.modifiers,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetEventDispatcherTarget(),
            0,
            &registered
        )
        if status == noErr {
            hotKeyRef = registered
        } else {
            NSLog("[ledge] hotkey ⌃⌥Space unavailable (%d) — another app may hold it", status)
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
