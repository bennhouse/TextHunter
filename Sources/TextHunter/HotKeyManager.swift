import Carbon
import Cocoa

/// Global shortcut through Carbon hot keys: works in every app and needs no extra permission.
/// A registered hot key is handled before the frontmost app sees the key, so it wins over
/// in-app shortcuts.
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onPress: (() -> Void)?
    private(set) var current: Shortcut?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKeyManager.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    /// Registers `shortcut`, replacing the current one. Returns false if another app already owns it;
    /// in that case the previous shortcut stays registered.
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        let previous = current
        unregister()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5478_4874), id: 1) // 'TxHt'
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id,
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if status == noErr, let ref {
            hotKeyRef = ref
            current = shortcut
            return true
        }
        if let previous, previous != shortcut { register(previous) }
        return false
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        current = nil
    }

    /// While a new shortcut is being recorded, every global shortcut is suspended (TextHunter's own,
    /// other apps' and the macOS ones), so the keys reach the recorder instead of triggering an action.
    /// Two mechanisms, the window server's global hot key mode and Carbon's symbolic hot key mode;
    /// macOS applies them only if TextHunter has Accessibility access. Without it, keys that macOS or
    /// another app already uses never reach the recorder.
    private var pausedShortcut: Shortcut?
    private var symbolicModeToken: UnsafeMutableRawPointer?
    private(set) var isPaused = false

    func pauseForRecording() {
        guard !isPaused else { return }
        isPaused = true
        pausedShortcut = current
        unregister()
        GlobalHotKeyMode.set(disabled: true)
        symbolicModeToken = PushSymbolicHotKeyMode(OptionBits(kHIHotKeyModeAllDisabled))
    }

    /// Makes sure no suspension is left over (at launch).
    func resetSuspension() {
        GlobalHotKeyMode.set(disabled: false)
    }

    func resumeAfterRecording() {
        guard isPaused else { return }
        isPaused = false
        if let token = symbolicModeToken { PopSymbolicHotKeyMode(token) }
        symbolicModeToken = nil
        GlobalHotKeyMode.set(disabled: false)
        if current == nil, let pausedShortcut { register(pausedShortcut) }
        pausedShortcut = nil
    }
}

/// The window server's global hot key operating mode (private CoreGraphics API, looked up at run
/// time so a future macOS without it just skips this step). Disabling it stops all global hot keys
/// for as long as this app's connection asks for it; macOS restores them if the app quits.
private enum GlobalHotKeyMode {
    private typealias MainConnection = @convention(c) () -> UInt32
    private typealias SetMode = @convention(c) (UInt32, Int32) -> Int32

    static func set(disabled: Bool) {
        let handle = dlopen(nil, RTLD_NOW)
        guard let c = dlsym(handle, "CGSMainConnectionID"), let s = dlsym(handle, "CGSSetGlobalHotKeyOperatingMode") else { return }
        let connection = unsafeBitCast(c, to: MainConnection.self)()
        _ = unsafeBitCast(s, to: SetMode.self)(connection, disabled ? 1 : 0)
    }
}
