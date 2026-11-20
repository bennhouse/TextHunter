import Carbon
import Cocoa

/// Global shortcut through Carbon hot keys: works in every app and needs no extra permission.
/// A registered hot key is handled before the frontmost app sees the key, so it wins over
/// in-app shortcuts.
/// What a global shortcut does. The raw value is the Carbon hot key id.
enum ShortcutAction: UInt32, CaseIterable {
    case capture = 1
    case scratchpad = 2

    var defaultsKey: String { self == .capture ? "shortcut" : "scratchpadShortcut" }
    var defaultShortcut: Shortcut { self == .capture ? .default : .scratchpadDefault }
    /// How the action is named in messages ("… is already used for Start Capture").
    var title: String { self == .capture ? "Start Capture" : "Open \(Scratchpad.name)" }
}

final class HotKeyManager {
    static let shared = HotKeyManager()

    var onPress: ((ShortcutAction) -> Void)?
    private(set) var current: [ShortcutAction: Shortcut] = [:]
    private var hotKeyRefs: [ShortcutAction: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotKeyManager.signature, let action = ShortcutAction(rawValue: id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { HotKeyManager.shared.onPress?(action) }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    private static let signature = OSType(0x5478_4874) // 'TxHt'

    /// Registers `shortcut` for `action`, replacing its current one. Returns false if another app already
    /// owns it; in that case the previous shortcut stays registered.
    @discardableResult
    func register(_ shortcut: Shortcut, for action: ShortcutAction) -> Bool {
        let previous = current[action]
        unregister(action)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id,
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if status == noErr, let ref {
            hotKeyRefs[action] = ref
            current[action] = shortcut
            return true
        }
        if let previous, previous != shortcut { register(previous, for: action) }
        return false
    }

    func unregister(_ action: ShortcutAction) {
        if let ref = hotKeyRefs[action] { UnregisterEventHotKey(ref) }
        hotKeyRefs[action] = nil
        current[action] = nil
    }

    /// While a new shortcut is being recorded, every global shortcut is suspended (TextHunter's own,
    /// other apps' and the macOS ones), so the keys reach the recorder instead of triggering an action.
    /// Two mechanisms, the window server's global hot key mode and Carbon's symbolic hot key mode;
    /// macOS applies them only if TextHunter has Accessibility access. Without it, keys that macOS or
    /// another app already uses never reach the recorder.
    private var pausedShortcuts: [ShortcutAction: Shortcut] = [:]
    private var symbolicModeToken: UnsafeMutableRawPointer?
    private(set) var isPaused = false

    func pauseForRecording() {
        guard !isPaused else { return }
        isPaused = true
        pausedShortcuts = current
        for action in ShortcutAction.allCases { unregister(action) }
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
        for (action, shortcut) in pausedShortcuts where current[action] == nil { register(shortcut, for: action) }
        pausedShortcuts = [:]
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
