import Cocoa
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var icon: StatusIcon!
    private let captureItem = NSMenuItem(title: "Start Capture", action: #selector(startCapture), keyEquivalent: "")
    private var busy = false
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        icon = StatusIcon()
        HotKeyManager.shared.resetSuspension()
        NSApp.mainMenu = makeMainMenu()

        let menu = NSMenu()
        captureItem.target = self
        menu.addItem(captureItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let permissions = NSMenuItem(title: "Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit TextHunter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        icon.item.menu = menu

        HotKeyManager.shared.onPress = { [weak self] in self?.startCapture() }
        Prefs.shared.activateShortcut()
        Prefs.shared.$shortcut.combineLatest(Prefs.shared.$shortcutActive)
            .sink { [weak self] shortcut, active in self?.showShortcutInMenu(active ? shortcut : nil) }
            .store(in: &cancellables)

        // First launch after installation: ask for the permissions together, as a welcome.
        if !UserDefaults.standard.bool(forKey: Permissions.welcomeKey) {
            WelcomeWindow.shared.show()
        }
    }

    /// A menu bar app shows no menu bar, but its main menu still handles the standard key
    /// equivalents (⌘W, ⌘Q, ⌘, and editing) while one of its windows is in front.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "TextHunter")
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit TextHunter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    @objc private func openPermissions() {
        WelcomeWindow.shared.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.resumeAfterRecording()
    }

    private func showShortcutInMenu(_ shortcut: Shortcut?) {
        captureItem.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
        captureItem.keyEquivalentModifierMask = shortcut?.flags ?? []
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc func startCapture() {
        guard !busy else { return }
        guard Permissions.hasScreenRecording else {
            Permissions.showScreenRecordingAlert()
            return
        }
        busy = true
        ScreenCapture.selectArea { [weak self] image in
            guard let self else { return }
            guard let image else { // Esc: nothing happens
                self.busy = false
                return
            }
            self.icon.beginWorking()
            let join = Prefs.shared.joinWrappedLines
            DispatchQueue.global(qos: .userInitiated).async {
                let lines = (try? TextRecognizer.recognize(image)) ?? []
                let text = ParagraphJoiner.text(from: lines, joinWrappedLines: join)
                    .trimmingCharacters(in: TextRecognizer.blank)
                DispatchQueue.main.async {
                    self.busy = false
                    if text.isEmpty {
                        self.icon.showNothingFound()
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        self.icon.showSuccess()
                    }
                }
            }
        }
    }
}
