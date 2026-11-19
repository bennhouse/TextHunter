import Carbon
import Cocoa

/// A keyboard shortcut: a virtual key code plus Cocoa modifier flags (⌘ ⌥ ⌃ ⇧ only).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt

    static let `default` = Shortcut(keyCode: UInt16(kVK_ANSI_2), modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.relevantModifiers.rawValue
    }

    init(event: NSEvent) {
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags.intersection(Self.relevantModifiers).rawValue)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// A global shortcut needs ⌘, ⌥ or ⌃ (⇧ alone would stop normal typing); F-keys are allowed alone.
    var isValid: Bool {
        !flags.intersection([.command, .option, .control]).isEmpty || Self.functionKeys[keyCode] != nil
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// e.g. "⇧⌘2"
    var displayString: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + keyName
    }

    var keyName: String {
        if let name = Self.functionKeys[keyCode] ?? Self.specialKeys[keyCode] { return name }
        return Self.character(for: keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    /// Key equivalent for the menu item, so the menu shows the shortcut next to "Start Capture".
    var menuKeyEquivalent: String {
        if let f = Self.functionKeys[keyCode], let n = Int(f.dropFirst()), let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
            return String(Character(scalar))
        }
        let map: [Int: Int] = [kVK_Space: 0x20, kVK_Return: 0x0D, kVK_Tab: 0x09, kVK_Delete: 0x08, kVK_Escape: 0x1B,
                               kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
                               kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
                               kVK_ForwardDelete: NSDeleteFunctionKey]
        if let code = map[Int(keyCode)], let scalar = UnicodeScalar(code) { return String(Character(scalar)) }
        return Self.character(for: keyCode)?.lowercased() ?? ""
    }

    /// The character the key types on the current keyboard layout, without modifiers.
    static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }

    static let functionKeys: [UInt16: String] = {
        let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return Dictionary(uniqueKeysWithValues: codes.enumerated().map { (UInt16($1), "F\($0 + 1)") })
    }()

    static let specialKeys: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_Escape): "⎋", UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘", UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
    ]
}
