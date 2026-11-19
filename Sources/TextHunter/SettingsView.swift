import Cocoa
import SwiftUI

final class SettingsWindow {
    static let shared = SettingsWindow()
    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = [.preferredContentSize] // the window follows the content's height
            let w = NSWindow(contentViewController: host)
            w.title = "TextHunter Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        SettingsWindow.bringToFront(window)
    }

    /// A menu bar app is never frontmost on its own: ask to be activated (both the current and the
    /// older API, since macOS 14 may decline the polite request) and put the window in front.
    static func bringToFront(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.activate()
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject private var prefs = Prefs.shared
    private let detailWidth: CGFloat = 250

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 20) {
            GridRow {
                label("Shortcut:")
                VStack(alignment: .leading, spacing: 6) {
                    ShortcutRecorder()
                    ShortcutStatusView(width: detailWidth)
                }
            }
            GridRow {
                label("Text:")
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Join wrapped lines", isOn: $prefs.joinWrappedLines)
                    caption("Lines that break only for lack of room are joined, so paragraphs copy as running text.")
                    Toggle("Label special text", isOn: $prefs.labelSpecialText)
                        .padding(.top, 4)
                    caption("The main text stays as it is. Titles, subtitles, captions, notes, superscripts, subscripts and text on coloured bubbles are marked, e.g. [title: Chapter 1], [caption: Figure 1…], [superscript: 17] or [blue bubble: Source 1].")
                }
            }
            GridRow {
                label("Startup:")
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch at login", isOn: Binding(get: { prefs.launchAtLogin },
                                                           set: { prefs.setLaunchAtLogin($0) }))
                    if let note = prefs.launchAtLoginNote { caption(note) }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .fixedSize()
    }

    private func label(_ text: String) -> some View {
        Text(text).gridColumnAlignment(.trailing)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .frame(width: detailWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The grey line under the shortcut field: a hint, or the outcome of the last recording.
struct ShortcutStatusView: View {
    @ObservedObject private var prefs = Prefs.shared
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prefs.shortcutStatus?.message ?? "Click the field, then press the new keys.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .id(prefs.shortcutStatus?.message) // cross-fade when the text changes
                .transition(.opacity)
            if let status = prefs.shortcutStatus, status.pending != nil || status.keyboardSettingsLink || status.accessibilityLink {
                HStack(spacing: 8) {
                    if status.pending != nil {
                        Button("Use Shortcut") { prefs.confirmPending() }
                        Button("Cancel") { prefs.cancelPending() }
                    }
                    if status.accessibilityLink {
                        Button("Allow Accessibility…") { Permissions.requestAccessibility() }
                    }
                    if status.keyboardSettingsLink {
                        Button("Keyboard Shortcuts…") { ShortcutConflicts.openKeyboardShortcutsSettings() }
                    }
                }
                .controlSize(.small)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: prefs.shortcutStatus)
    }
}

