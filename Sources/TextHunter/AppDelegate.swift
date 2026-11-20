import Cocoa
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var icon: StatusIcon!
    private let captureItem = NSMenuItem(title: "Start Capture", action: #selector(startCapture), keyEquivalent: "")
    private let scratchpadItem = NSMenuItem(title: "Open \(Scratchpad.name)", action: #selector(toggleScratchpad), keyEquivalent: "")
    private var busy = false
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        icon = StatusIcon()
        HotKeyManager.shared.resetSuspension()
        NSApp.mainMenu = makeMainMenu()

        let menu = NSMenu()
        captureItem.target = self
        menu.addItem(captureItem)
        scratchpadItem.target = self
        menu.addItem(scratchpadItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let permissions = NSMenuItem(title: "Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit TextHunter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        icon.item.menu = menu

        HotKeyManager.shared.onPress = { [weak self] action in
            switch action {
            case .capture: self?.startCapture()
            case .scratchpad: self?.toggleScratchpad()
            }
        }
        Prefs.shared.activateShortcuts()
        Prefs.shared.$shortcuts.combineLatest(Prefs.shared.$inactiveShortcuts)
            .sink { [weak self] shortcuts, inactive in
                guard let self else { return }
                Self.show(inactive.contains(.capture) ? nil : shortcuts[.capture], in: self.captureItem)
                Self.show(inactive.contains(.scratchpad) ? nil : shortcuts[.scratchpad], in: self.scratchpadItem)
            }
            .store(in: &cancellables)

        // Development aid: open the Scratchpad at launch (to check the real window).
        if ProcessInfo.processInfo.environment["TEXTHUNTER_OPEN_SCRATCHPAD"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ScratchpadController.shared.show() }
        }

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
        edit.addItem(.separator())
        for (title, key, action) in [("Find…", "f", NSTextFinder.Action.showFindInterface),
                                     ("Find Next", "g", .nextMatch), ("Find Previous", "G", .previousMatch)] {
            let item = NSMenuItem(title: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            item.tag = action.rawValue
            edit.addItem(item)
        }
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
        ScratchpadController.shared.flushSave()
    }

    private static func show(_ shortcut: Shortcut?, in item: NSMenuItem) {
        item.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
        item.keyEquivalentModifierMask = shortcut?.flags ?? []
    }

    @objc func toggleScratchpad() {
        ScratchpadController.shared.toggle()
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
            let label = Prefs.shared.labelSpecialText
            DispatchQueue.global(qos: .userInitiated).async {
                // Debug only (`defaults write local.texthunter.TextHunter debugKeepLastCapture -bool true`):
                // keeps the last capture in ~/Library/Caches/TextHunter to reproduce a wrong reading.
                if UserDefaults.standard.bool(forKey: "debugKeepLastCapture") {
                    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TextHunter")
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    if let d = CGImageDestinationCreateWithURL(dir.appendingPathComponent("last-capture.png") as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(d, image, nil)
                        CGImageDestinationFinalize(d)
                    }
                }
                let lines = (try? TextRecognizer.recognize(image, labelSpecialText: label)) ?? []
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
