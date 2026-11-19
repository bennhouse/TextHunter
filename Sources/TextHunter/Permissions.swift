import Cocoa
import SwiftUI

/// The permissions TextHunter uses, asked for together on the first launch after installation.
/// - Screen Recording (required): without it macOS only shows the desktop background to the capture.
/// - Accessibility (optional): lets the shortcut recorder suspend shortcuts that macOS or another app
///   already uses, so those keys can be recorded too.
enum Permissions {
    static let welcomeKey = "welcomeDone"
    /// Screen Recording was requested once: macOS shows its prompt only the first time.
    static let screenAskedKey = "screenRecordingAsked"

    enum State { case granted, notGranted, needsRelaunch }

    static var screenRecording: State {
        if CGPreflightScreenCaptureAccess() { return .granted }
        // The answer is cached per process: after it is turned on, macOS asks to Quit & Reopen.
        return UserDefaults.standard.bool(forKey: screenAskedKey) ? .needsRelaunch : .notGranted
    }

    static var accessibility: State { AXIsProcessTrusted() ? .granted : .notGranted }

    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func requestScreenRecording() {
        let firstTime = !UserDefaults.standard.bool(forKey: screenAskedKey)
        UserDefaults.standard.set(true, forKey: screenAskedKey)
        // The first time macOS shows its own prompt and adds TextHunter to the list; afterwards the
        // call does nothing, so open the settings page instead.
        if !CGRequestScreenCaptureAccess() && !firstTime { openSettings("Privacy_ScreenCapture") }
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary) { openSettings("Privacy_Accessibility") }
    }

    static func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    /// Shown when a capture is started without the permission.
    static func showScreenRecordingAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Needed"
        alert.informativeText = """
            TextHunter needs permission to record the screen to read the text in the area you select.

            Turn on TextHunter in System Settings › Privacy & Security › Screen & System Audio Recording, \
            then quit and reopen TextHunter.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { openSettings("Privacy_ScreenCapture") }
    }
}

final class WelcomeWindow {
    static let shared = WelcomeWindow()
    private var window: NSWindow?

    /// On the first launch after installation (and from the menu, Permissions…).
    func show() {
        if window == nil {
            let host = NSHostingController(rootView: WelcomeView { [weak self] in self?.window?.close() })
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.title = "Welcome to TextHunter"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            // Closing it in any way (button, ⌘W, red dot) counts as seen: it's shown once.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                UserDefaults.standard.set(true, forKey: Permissions.welcomeKey)
            }
            window = w
        }
        SettingsWindow.bringToFront(window)
    }
}

/// Welcome screen: the permissions, what each is for, and a button to ask for all of them.
struct WelcomeView: View {
    let onDone: () -> Void

    @State private var screen = Permissions.screenRecording
    @State private var ax = Permissions.accessibility
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to TextHunter").font(.title3.weight(.semibold))
                    Text("TextHunter copies the text in any area of the screen. Allow these permissions now so it’s ready when you need it.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                row("rectangle.dashed", "Screen Recording",
                    screen == .needsRelaunch
                        ? "If you have turned it on, quit and reopen TextHunter to use it."
                        : "Read the text in the area you select. Required.",
                    screen) { Permissions.requestScreenRecording(); screen = Permissions.screenRecording }
                Divider()
                row("keyboard", "Accessibility",
                    "Record a shortcut that macOS or another app already uses. Optional.",
                    ax) { Permissions.requestAccessibility() }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))

            Text("Nothing leaves your Mac: the text is read on-device. You can open this window again from the TextHunter menu (Permissions…).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(allGranted ? "Done" : "Not Now") { finish() }
                    .keyboardShortcut(allGranted ? .defaultAction : .cancelAction)
                if !allGranted {
                    Button("Allow All") { allowAll() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 440)
        .onReceive(timer) { _ in refresh() }
    }

    private var allGranted: Bool { screen == .granted && ax == .granted }

    @ViewBuilder
    private func row(_ symbol: String, _ title: String, _ detail: String, _ state: Permissions.State,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch state {
            case .granted:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 16))
                    .transition(.scale.combined(with: .opacity))
            case .needsRelaunch:
                Button("Quit & Reopen") { relaunch() }.controlSize(.small)
            case .notGranted:
                Button("Allow", action: action).controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    private func refresh() {
        screen = Permissions.screenRecording
        ax = Permissions.accessibility
    }

    /// Asks in a row; Accessibility last, since it opens System Settings.
    private func allowAll() {
        let askScreen = screen == .notGranted
        if askScreen { Permissions.requestScreenRecording() }
        refresh()
        guard ax != .granted else { return }
        // After the Screen Recording prompt, so the two macOS dialogs don't pile up.
        DispatchQueue.main.asyncAfter(deadline: .now() + (askScreen ? 1.5 : 0)) { Permissions.requestAccessibility() }
    }

    private func relaunch() {
        UserDefaults.standard.set(true, forKey: Permissions.welcomeKey)
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Permissions.welcomeKey)
        onDone()
    }
}
