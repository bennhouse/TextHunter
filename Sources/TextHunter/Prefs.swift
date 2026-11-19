import Cocoa
import ServiceManagement

/// A short line of feedback shown under the shortcut field in Settings (no alerts).
struct ShortcutStatus: Equatable {
    var message: String
    /// A shortcut used by macOS, waiting for the user to confirm the takeover.
    var pending: Shortcut?
    var pendingSystemID: Int?
    /// Shows a button that opens System Settings › Keyboard › Keyboard Shortcuts.
    var keyboardSettingsLink = false
    /// Shows a button that asks for Accessibility access.
    var accessibilityLink = false
}

final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let defaults = UserDefaults.standard

    @Published private(set) var shortcut: Shortcut
    /// False when the shortcut could not be registered because another app owns it.
    @Published private(set) var shortcutActive = true
    @Published private(set) var shortcutStatus: ShortcutStatus?
    @Published var joinWrappedLines: Bool {
        didSet { defaults.set(joinWrappedLines, forKey: "joinWrappedLines") }
    }
    @Published var labelSpecialText: Bool {
        didSet { defaults.set(labelSpecialText, forKey: "labelSpecialText") }
    }
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginNote: String?
    private var clearStatus: DispatchWorkItem?

    private init() {
        defaults.register(defaults: ["joinWrappedLines": true, "labelSpecialText": true])
        joinWrappedLines = defaults.bool(forKey: "joinWrappedLines")
        labelSpecialText = defaults.bool(forKey: "labelSpecialText")
        if let data = defaults.data(forKey: "shortcut"), let s = try? JSONDecoder().decode(Shortcut.self, from: data) {
            shortcut = s
        } else {
            shortcut = .default
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Registers the saved shortcut at launch.
    func activateShortcut() {
        shortcutActive = HotKeyManager.shared.register(shortcut)
        if !shortcutActive {
            show(ShortcutStatus(message: "\(shortcut.displayString) is used by another app. Choose a different shortcut."))
        }
    }

    // MARK: - Changing the shortcut

    /// Called with the keys the user just recorded.
    func proposeShortcut(_ new: Shortcut) {
        if new == shortcut && shortcutActive {
            show(ShortcutStatus(message: "TextHunter already uses \(new.displayString)."), autoClear: true)
            return
        }
        if let conflict = ShortcutConflicts.systemConflict(for: new) {
            if let id = conflict.id {
                show(ShortcutStatus(
                    message: "macOS uses \(new.displayString) for “\(conflict.name)”. TextHunter can take it over and turn the macOS shortcut off.",
                    pending: new, pendingSystemID: id))
            } else {
                show(ShortcutStatus(
                    message: "macOS uses \(new.displayString) for a system action TextHunter can’t turn off. Turn it off in Keyboard Shortcuts, or choose another shortcut.",
                    pending: new, keyboardSettingsLink: true))
            }
            return
        }
        apply(new, disablingSystemShortcut: nil)
    }

    func confirmPending() {
        guard let status = shortcutStatus, let new = status.pending else { return }
        apply(new, disablingSystemShortcut: status.pendingSystemID)
    }

    private static let recordingMessage = "Recording: other shortcuts are paused. Esc cancels."

    /// While recording. Without Accessibility access, keys already in use can't reach the field.
    func showRecordingHint() {
        if AXIsProcessTrusted() {
            show(ShortcutStatus(message: Self.recordingMessage))
        } else {
            show(ShortcutStatus(
                message: "Keys that macOS or another app already uses can only be recorded with Accessibility access.",
                accessibilityLink: true))
        }
    }

    /// Recording ended without a new shortcut: remove the recording hint.
    func clearRecordingHint() {
        if shortcutStatus?.message == Self.recordingMessage || shortcutStatus?.accessibilityLink == true { show(nil) }
    }

    func cancelPending() {
        show(nil)
    }

    private func apply(_ new: Shortcut, disablingSystemShortcut id: Int?) {
        guard HotKeyManager.shared.register(new) else {
            show(ShortcutStatus(message: "\(new.displayString) is used by another app. Choose a different shortcut."))
            return
        }
        ShortcutConflicts.restoreDisabled(keeping: new)
        shortcut = new
        shortcutActive = true
        defaults.set(try? JSONEncoder().encode(new), forKey: "shortcut")

        if let id {
            if ShortcutConflicts.disable(id, shortcut: new) {
                show(ShortcutStatus(message: "Shortcut set to \(new.displayString). The macOS shortcut is now off."), autoClear: true)
            } else {
                show(ShortcutStatus(
                    message: "Shortcut set to \(new.displayString), but macOS hasn’t released it yet. Turn it off in Keyboard Shortcuts.",
                    keyboardSettingsLink: true))
            }
        } else {
            show(ShortcutStatus(message: "Shortcut set to \(new.displayString)."), autoClear: true)
        }
    }

    private func show(_ status: ShortcutStatus?, autoClear: Bool = false) {
        clearStatus?.cancel()
        shortcutStatus = status
        guard autoClear, let status else { return }
        let work = DispatchWorkItem { [weak self] in
            if self?.shortcutStatus == status { self?.shortcutStatus = nil }
        }
        clearStatus = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLoginNote = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLoginNote = error.localizedDescription
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status == .requiresApproval {
            launchAtLoginNote = "Allow TextHunter in System Settings › General › Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
