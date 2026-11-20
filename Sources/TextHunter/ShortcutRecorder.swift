import Cocoa
import SwiftUI

/// SwiftUI wrapper of the AppKit recorder field.
struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject private var prefs = Prefs.shared
    var action: ShortcutAction = .capture

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        let action = action
        field.action = action
        field.onRecord = { Prefs.shared.proposeShortcut($0, for: action) }
        field.onStart = { Prefs.shared.cancelPending() }
        return field
    }

    func updateNSView(_ field: RecorderField, context: Context) {
        field.shortcut = prefs.shortcut(for: action)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecorderField, context: Context) -> CGSize? {
        CGSize(width: 104, height: 22)
    }
}

/// A compact field that records a shortcut. Click it (or Tab to it and press Space), then press the
/// keys: the modifiers appear as you hold them. While it records, every other shortcut is paused, so
/// recording lasts only as long as needed: it ends with Esc, a click, ⌘W/⌘Q/⌘, (which then do their
/// usual job), switching to another window or app, or after 10 seconds without keys.
/// It takes keyboard focus like a text field, so keys come straight to it; a local event monitor
/// also catches ⌘-combinations before any menu can claim them.
final class RecorderField: NSView {
    var onRecord: ((Shortcut) -> Void)?
    var onStart: (() -> Void)?
    var action: ShortcutAction = .capture
    var shortcut: Shortcut = .default { didSet { if !recording { refresh() } } }

    private let label = NSTextField(labelWithString: "")
    private var recording = false
    private var monitor: Any?
    private var hint: String?
    private var idleTimer: Timer?
    private var appObserver: NSObjectProtocol?

    /// Standard window and app commands are never recorded: they end recording and run as usual.
    private static let passThrough: Set<UInt16> = [13, 12, 43] // W, Q, comma (with ⌘ only)

    deinit { stop() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -8),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 104, height: 22) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill() }

    override func mouseDown(with event: NSEvent) {
        if recording {
            stop()
        } else {
            SettingsWindow.bringToFront(window)
            window?.makeFirstResponder(self)
            start()
        }
    }

    override func keyDown(with event: NSEvent) {
        // Space starts recording when the field has focus but isn't recording yet (keyboard access).
        if !recording && event.keyCode == 49 { start() } else if recording { handle(event) } else { super.keyDown(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        stop()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned), name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned), name: NSWindow.willCloseNotification, object: window)
        } else {
            stop()
        }
    }

    @objc private func windowResigned() {
        stop()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    // MARK: - Recording

    private func start() {
        guard !recording else { return }
        recording = true
        hint = nil
        onStart?()
        HotKeyManager.shared.pauseForRecording()
        Prefs.shared.showRecordingHint(for: action)
        appObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop()
        }
        restartIdleTimer()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.recording else { return event }
            self.restartIdleTimer()
            if event.type == .keyDown, Self.passThrough.contains(event.keyCode),
               event.modifierFlags.intersection(Shortcut.relevantModifiers) == .command {
                self.stop()
                return event
            }
            if event.type == .flagsChanged {
                self.showModifiers(event.modifierFlags)
                return event
            }
            self.handle(event)
            return nil
        }
        refresh()
    }

    private func handle(_ event: NSEvent) {
        let s = Shortcut(event: event)
        if event.keyCode == 53 && s.flags.isEmpty { // Esc
            stop()
        } else if s.isValid {
            stop()
            onRecord?(s)
        } else {
            hint = "Add ⌘ ⌥ or ⌃"
            refresh()
        }
    }

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in self?.stop() }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        idleTimer?.invalidate()
        idleTimer = nil
        if let appObserver { NotificationCenter.default.removeObserver(appObserver) }
        appObserver = nil
        HotKeyManager.shared.resumeAfterRecording()
        Prefs.shared.clearRecordingHint()
        refresh()
    }

    private var liveModifiers = ""

    private func showModifiers(_ flags: NSEvent.ModifierFlags) {
        let f = flags.intersection(Shortcut.relevantModifiers)
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        liveModifiers = s
        hint = nil
        refresh()
    }

    private func refresh() {
        let text: String
        if recording {
            text = hint ?? (liveModifiers.isEmpty ? "Type keys…" : liveModifiers)
        } else {
            liveModifiers = ""
            text = shortcut.displayString
        }
        label.stringValue = text
        label.font = .systemFont(ofSize: 12, weight: recording && liveModifiers.isEmpty ? .regular : .medium)
        label.textColor = recording && liveModifiers.isEmpty ? .secondaryLabelColor : .labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = (recording ? NSColor.controlAccentColor.withAlphaComponent(0.8) : NSColor.separatorColor).cgColor
        }
        layer?.borderWidth = recording ? 1.5 : 1
    }
}
