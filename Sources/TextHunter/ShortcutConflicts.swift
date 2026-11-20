import Carbon
import Cocoa

/// Finds macOS system shortcuts (System Settings › Keyboard › Keyboard Shortcuts) that use the same
/// keys as TextHunter's shortcut, and turns them off or back on. System shortcuts are handled before
/// any app's hot key, so TextHunter can only take one over by turning the system one off.
enum ShortcutConflicts {
    struct SystemConflict {
        /// ID in com.apple.symbolichotkeys; nil when the shortcut cannot be identified (and so cannot be turned off).
        var id: Int?
        var name: String
    }

    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString
    private static let disabledKey = "disabledSystemShortcuts"
    private static let cocoaMask = Shortcut.relevantModifiers.rawValue
    private static let carbonMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    /// The enabled system shortcut that uses the same keys as `shortcut`, if any.
    static func systemConflict(for shortcut: Shortcut) -> SystemConflict? {
        guard activeSystemShortcutExists(shortcut) else { return nil }
        let stored = symbolicHotKeys() ?? [:]
        // Look for the ID among the shortcuts stored in the preferences...
        for (idString, entry) in stored {
            guard let id = Int(idString), let e = entry as? [String: Any], (e["enabled"] as? Bool) == true,
                  let combo = combo(of: e), combo == shortcut else { continue }
            return SystemConflict(id: id, name: names[id] ?? "a macOS keyboard shortcut")
        }
        // ...then among the macOS defaults that were never changed (and so are not stored).
        for (id, combo) in defaults where combo == shortcut && stored[String(id)] == nil {
            return SystemConflict(id: id, name: names[id] ?? "a macOS keyboard shortcut")
        }
        return SystemConflict(id: nil, name: "a macOS keyboard shortcut")
    }

    private static func activeSystemShortcutExists(_ shortcut: Shortcut) -> Bool {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr,
              let list = array?.takeRetainedValue() as? [[String: Any]] else { return false }
        return list.contains { d in
            (d[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && (d[kHISymbolicHotKeyCode as String] as? Int) == Int(shortcut.keyCode)
                && UInt32((d[kHISymbolicHotKeyModifiers as String] as? Int) ?? 0) & carbonMask == shortcut.carbonModifiers
        }
    }

    /// Turns off system shortcut `id` and remembers it, so it can be turned back on later.
    /// Returns false if macOS still reports the shortcut as active afterwards.
    @discardableResult
    static func disable(_ id: Int, shortcut: Shortcut) -> Bool {
        // Never write back a table that could not be read: it would wipe the user's other shortcuts.
        guard var all = symbolicHotKeys(), !all.isEmpty else { return false }
        var entry = all[String(id)] as? [String: Any] ?? [
            "value": ["parameters": [65535, Int(shortcut.keyCode), Int(shortcut.modifiers)], "type": "standard"],
        ]
        entry["enabled"] = false
        all[String(id)] = entry
        save(all)

        var remembered = UserDefaults.standard.array(forKey: disabledKey) as? [Int] ?? []
        if !remembered.contains(id) { remembered.append(id) }
        UserDefaults.standard.set(remembered, forKey: disabledKey)
        return !activeSystemShortcutExists(shortcut)
    }

    /// Turns back on the system shortcuts TextHunter turned off, except those that use one of `kept`
    /// (the shortcuts TextHunter still uses).
    static func restoreDisabled(keeping kept: [Shortcut]) {
        let remembered = UserDefaults.standard.array(forKey: disabledKey) as? [Int] ?? []
        guard !remembered.isEmpty else { return }
        guard var all = symbolicHotKeys(), !all.isEmpty else { return }
        var still: [Int] = []
        var changed = false
        for id in remembered {
            guard var entry = all[String(id)] as? [String: Any] else { continue }
            if let c = combo(of: entry), kept.contains(c) { still.append(id); continue }
            entry["enabled"] = true
            all[String(id)] = entry
            changed = true
        }
        if changed { save(all) }
        UserDefaults.standard.set(still, forKey: disabledKey)
    }

    static func openKeyboardShortcutsSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    // MARK: - Preferences

    private static func symbolicHotKeys() -> [String: Any]? {
        CFPreferencesCopyAppValue(key, domain) as? [String: Any]
    }

    private static func save(_ all: [String: Any]) {
        CFPreferencesSetAppValue(key, all as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
        // Makes the running system pick up the change without logging out.
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        tool.arguments = ["-u"]
        try? tool.run()
        tool.waitUntilExit()
    }

    private static func combo(of entry: [String: Any]) -> Shortcut? {
        guard let value = entry["value"] as? [String: Any], let p = value["parameters"] as? [Int], p.count == 3,
              p[1] != 65535 else { return nil }
        return Shortcut(keyCode: UInt16(p[1]), modifiers: UInt(p[2]) & cocoaMask)
    }

    // MARK: - Known system shortcuts

    private static let names: [Int: String] = {
        var n: [Int: String] = [
            7: "Move focus to the menu bar", 8: "Move focus to the Dock", 9: "Move focus to active or next window",
            10: "Move focus to the window toolbar", 11: "Move focus to the floating window",
            12: "Turn keyboard access on or off", 13: "Change the way Tab moves focus",
            15: "Turn zoom on or off", 17: "Zoom in", 19: "Zoom out", 21: "Invert colors",
            25: "Increase contrast", 26: "Decrease contrast", 27: "Move focus to next window",
            28: "Save picture of screen as a file", 29: "Copy picture of screen to the clipboard",
            30: "Save picture of selected area as a file", 31: "Copy picture of selected area to the clipboard",
            32: "Mission Control", 33: "Application windows", 36: "Show Desktop",
            52: "Turn Dock hiding on/off", 57: "Move focus to status menus",
            60: "Select the previous input source", 61: "Select next source in Input menu",
            64: "Show Spotlight search", 65: "Show Finder search window",
            79: "Move left a space", 81: "Move right a space", 98: "Show Help menu",
            160: "Show Launchpad", 163: "Show Notification Center",
            184: "Screenshot and recording options", 190: "Quick Note", 222: "Turn Stage Manager on/off",
        ]
        for i in 0..<16 { n[118 + i] = "Switch to Desktop \(i + 1)" }
        return n
    }()

    /// Factory defaults, used when a shortcut was never changed and so is not in the preferences.
    private static let defaults: [Int: Shortcut] = {
        let cmd = NSEvent.ModifierFlags.command, shift = NSEvent.ModifierFlags.shift
        let ctrl = NSEvent.ModifierFlags.control, opt = NSEvent.ModifierFlags.option
        func s(_ key: Int, _ m: NSEvent.ModifierFlags) -> Shortcut { Shortcut(keyCode: UInt16(key), modifiers: m.rawValue) }
        return [
            28: s(kVK_ANSI_3, [cmd, shift]), 29: s(kVK_ANSI_3, [cmd, shift, ctrl]),
            30: s(kVK_ANSI_4, [cmd, shift]), 31: s(kVK_ANSI_4, [cmd, shift, ctrl]),
            184: s(kVK_ANSI_5, [cmd, shift]), 64: s(kVK_Space, [cmd]), 65: s(kVK_Space, [cmd, opt]),
            60: s(kVK_Space, [ctrl]), 61: s(kVK_Space, [ctrl, opt]), 27: s(kVK_ANSI_Grave, [cmd]),
            52: s(kVK_ANSI_D, [cmd, opt]), 98: s(kVK_ANSI_Slash, [cmd, shift]),
            32: s(kVK_UpArrow, [ctrl]), 33: s(kVK_DownArrow, [ctrl]),
            79: s(kVK_LeftArrow, [ctrl]), 81: s(kVK_RightArrow, [ctrl]),
        ]
    }()
}
