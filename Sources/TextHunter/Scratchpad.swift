import Cocoa
import SwiftUI
import UniformTypeIdentifiers

/// The Scratchpad: a floating note for short-lived text. It keeps its text from one opening to the
/// next and across restarts (saved in ~/Library/Application Support/TextHunter/Scratchpad.md).
/// Unpinned, it closes when you click elsewhere; pinned, it stays open until closed.
enum Scratchpad {
    static let name = "Scratchpad"
}

final class ScratchpadController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = ScratchpadController()

    @Published var text: String = "" { didSet { if text != oldValue { scheduleSave() } } }
    @Published private(set) var isPinned = false
    @Published var isPreviewing = false
    @Published var showsFormatBar = UserDefaults.standard.bool(forKey: "scratchpadFormatBar") {
        didSet { UserDefaults.standard.set(showsFormatBar, forKey: "scratchpadFormatBar") }
    }
    /// The last save failed, or the saved note could not be read (then it is never overwritten).
    @Published private(set) var saveFailed = false

    weak var textView: NSTextView?
    private var panel: ScratchpadPanel?
    private var saveWork: DispatchWorkItem?
    private var readFailed = false
    /// Developer render mode: never write the note.
    var savingDisabled = false
    /// A dialog (export) is open: the panel losing focus to it must not close it.
    private var dialogOpen = false

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TextHunter", isDirectory: true)
        return dir.appendingPathComponent("Scratchpad.md")
    }()

    private override init() {
        super.init()
        let url = Self.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            if let saved = try? String(contentsOf: url, encoding: .utf8) {
                text = saved
            } else {
                readFailed = true
                saveFailed = true
            }
        }
        saveWork?.cancel() // loading is not an edit
    }

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Showing

    /// The shortcut: opens the pad, or closes it when it is already in front.
    func toggle() {
        if let panel, panel.isVisible, panel.isKeyWindow {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // A non-activating panel takes the keyboard without bringing TextHunter forward, so the app
        // in use stays active (and macOS never refuses the switch).
        panel.orderFrontRegardless()
        panel.makeKey()
        if !isPreviewing, let textView { panel.makeFirstResponder(textView) }
        startWatchingClicks()
    }

    /// An unpinned pad closes at a click in another app (a non-activating panel is not always told
    /// it lost the keyboard then).
    private var clickMonitor: Any?

    private func startWatchingClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, !self.isPinned, !self.dialogOpen, !self.pointerIsOnPad else { return }
            self.hide()
        }
    }

    /// The pointer is over the pad: a click there (or a drag of its top bar, which the window server
    /// runs) is not a click elsewhere.
    private var pointerIsOnPad: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    private func stopWatchingClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        flushSave()
        stopWatchingClicks()
        panel.orderOut(nil)
        isPinned = false
        isPreviewing = false
        // Give the keyboard back to the app in use before, unless another TextHunter window is open.
        let others = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeKey && !$0.className.contains("StatusBar") }
        if NSApp.isActive && !others { NSApp.hide(nil) }
    }

    func togglePin() {
        isPinned.toggle()
    }

    private func makePanel() -> ScratchpadPanel {
        let panel = ScratchpadPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                                    styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.title = Scratchpad.name
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.minSize = NSSize(width: 320, height: 220)
        panel.delegate = self

        let background = NSVisualEffectView()
        background.material = .hudWindow // see-through like Vorssaint's pad
        background.blendingMode = .behindWindow
        background.state = .active
        let host = NSHostingView(rootView: ScratchpadView())
        host.safeAreaRegions = [] // the header starts at the top edge, not under an invisible title bar
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background

        panel.center()
        panel.setFrameAutosaveName("Scratchpad")
        return panel
    }

    // MARK: - Window delegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide() // ⌘W and the close button only hide the pad: its text stays
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isPinned, !dialogOpen else { return }
        // A click elsewhere closes an unpinned pad. Wait a moment: the key window may only be moving
        // to a sheet or the find bar of the pad itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let panel = self.panel, !panel.isKeyWindow, !self.isPinned, !self.dialogOpen,
                  panel.attachedSheet == nil, !self.pointerIsOnPad else { return }
            self.hide()
        }
    }

    // MARK: - Actions

    func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportText() {
        let save = NSSavePanel()
        save.allowedContentTypes = [.plainText] // .txt by default; another extension typed in the name is kept
        save.allowsOtherFileTypes = true
        save.canCreateDirectories = true
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd HH.mm"
        save.nameFieldStringValue = "\(Scratchpad.name) \(date.string(from: Date())).txt"
        save.level = .modalPanel
        dialogOpen = true
        NSApp.activate() // the save dialog needs TextHunter in front to take typing
        let response = save.runModal()
        dialogOpen = false
        panel?.makeKeyAndOrderFront(nil)
        guard response == .OK, let url = save.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert(error: error)
            dialogOpen = true
            alert.runModal()
            dialogOpen = false
        }
    }

    /// Clearing goes through the text view, so ⌘Z brings the text back.
    func clear() {
        if isPreviewing { isPreviewing = false }
        guard !text.isEmpty else { return }
        if let textView {
            if textView.hasMarkedText() { textView.unmarkText() }
            let all = NSRange(location: 0, length: (textView.string as NSString).length)
            textView.insertText("", replacementRange: all)
            panel?.makeFirstResponder(textView)
        } else {
            text = ""
        }
    }

    func togglePreview() {
        isPreviewing.toggle()
        if !isPreviewing, let textView { DispatchQueue.main.async { self.panel?.makeFirstResponder(textView) } }
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes the text now (also at quit).
    func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        guard !readFailed, !savingDisabled else { return } // never replace a note that could not be read
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            if saveFailed { saveFailed = false }
        } catch {
            saveFailed = true
        }
    }
}

final class ScratchpadPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - View

struct ScratchpadView: View {
    @ObservedObject private var pad = ScratchpadController.shared
    @State private var copied = false
    private var isEmpty: Bool { pad.text.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            if pad.saveFailed {
                Label("The Scratchpad can’t be saved. Copy or export the text to keep it.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 6)
            }
            ZStack {
                ScratchpadEditor(text: $pad.text)
                    .opacity(pad.isPreviewing ? 0 : 1)
                    .allowsHitTesting(!pad.isPreviewing)
                    .overlay(alignment: .topLeading) {
                        if isEmpty && !pad.isPreviewing {
                            Text("Write something…")
                                .font(.system(size: ScratchpadEditor.fontSize))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, ScratchpadEditor.inset.width + 5)
                                .padding(.top, ScratchpadEditor.inset.height)
                                .allowsHitTesting(false)
                        }
                    }
                if pad.isPreviewing {
                    MarkdownPreview(text: pad.text)
                }
            }
            if pad.showsFormatBar && !pad.isPreviewing {
                formatBar
            }
            footer
        }
        .frame(minWidth: 320, minHeight: 220)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(Scratchpad.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .overlay(WindowDragArea()) // the whole bar moves the window, except the buttons
            Button { pad.togglePin() } label: {
                Image(systemName: pad.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pad.isPinned ? Color.accentColor : Color.secondary)
            .help(pad.isPinned ? "Close when clicking elsewhere" : "Keep open")
            Button { pad.hide() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 40)
    }

    private var formatBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(MarkdownMark.allCases, id: \.self) { mark in
                    Button { MarkdownMark.apply(mark, in: pad.textView) } label: {
                        Group {
                            if let glyph = mark.glyph {
                                Text(verbatim: glyph).font(.system(size: 13, weight: .semibold))
                            } else {
                                Image(systemName: mark.symbol).font(.system(size: 12, weight: .medium))
                            }
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(mark.label)
                }
            }
            .padding(.horizontal, 10)
        }
        .scrollIndicators(.hidden)
        .frame(height: 30)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            footerButton("textformat", "Formatting", tint: pad.showsFormatBar && !pad.isPreviewing ? .accentColor : nil) {
                withAnimation(.easeOut(duration: 0.15)) { pad.showsFormatBar.toggle() }
            }
            .disabled(pad.isPreviewing)

            Group {
                footerButton(pad.isPreviewing ? "pencil" : "eye", pad.isPreviewing ? "Edit text" : "Preview formatting",
                             tint: pad.isPreviewing ? .accentColor : nil) {
                    pad.togglePreview()
                }
                footerButton(copied ? "checkmark" : "doc.on.doc", copied ? "Copied" : "Copy all", tint: copied ? .green : nil) {
                    pad.copyAll()
                    withAnimation(.easeOut(duration: 0.15)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation(.easeOut(duration: 0.2)) { copied = false }
                    }
                }
                footerButton("square.and.arrow.down", "Export…") { pad.exportText() }
                Spacer()
                footerButton("trash", "Clear (⌘Z brings it back)") { pad.clear() }
            }
            .disabled(isEmpty)
            .opacity(isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private func footerButton(_ symbol: String, _ label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A transparent strip that moves the window when dragged (the pad has no visible title bar).
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
            window?.makeKey() // keep typing in the pad after moving it
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

// MARK: - Editor

/// Plain text editing with undo, ⌘F search and lists that continue on Return.
struct ScratchpadEditor: NSViewRepresentable {
    @Binding var text: String
    static let fontSize: CGFloat = 14
    static let inset = NSSize(width: 12, height: 12)

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = scroll.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: Self.fontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = Self.inset
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = text
        ScratchpadController.shared.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                return MarkdownMark.continueList(in: textView)
            }
            return false
        }
    }
}

// MARK: - Formatting marks

enum MarkdownMark: CaseIterable {
    case heading, bold, italic, strikethrough, bullet, numbered, task, quote, code, link

    var label: String {
        switch self {
        case .heading: "Heading"
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .bullet: "Bulleted list"
        case .numbered: "Numbered list"
        case .task: "Checklist"
        case .quote: "Quote"
        case .code: "Code"
        case .link: "Link"
        }
    }

    var glyph: String? { self == .heading ? "H" : nil }

    var symbol: String {
        switch self {
        case .heading: "textformat.size"
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .bullet: "list.bullet"
        case .numbered: "list.number"
        case .task: "checklist"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        }
    }

    static func apply(_ mark: MarkdownMark, in textView: NSTextView?) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        switch mark {
        case .bold: wrap(textView, "**", "**")
        case .italic: wrap(textView, "*", "*")
        case .strikethrough: wrap(textView, "~~", "~~")
        case .code: wrap(textView, "`", "`")
        case .link: wrap(textView, "[", "](https://)")
        case .heading: prefixLines(textView) { _ in "# " }
        case .bullet: prefixLines(textView) { _ in "- " }
        case .numbered: prefixLines(textView) { "\($0 + 1). " }
        case .task: prefixLines(textView) { _ in "- [ ] " }
        case .quote: prefixLines(textView) { _ in "> " }
        }
    }

    /// Puts the marks around the selection (or around the cursor, ready to type).
    private static func wrap(_ textView: NSTextView, _ left: String, _ right: String) {
        let range = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: range)
        textView.insertText(left + selected + right, replacementRange: range)
        let leftLength = (left as NSString).length
        textView.setSelectedRange(NSRange(location: range.location + leftLength, length: (selected as NSString).length))
    }

    private static let listPrefix = try! NSRegularExpression(pattern: #"^(\s*)(#{1,6} |[-*+] \[[ xX]\] |[-*+] |\d+\. |> )"#)

    /// Adds the prefix to every selected line, or removes it when every line already has it.
    private static func prefixLines(_ textView: NSTextView, _ prefix: (Int) -> String) {
        let string = textView.string as NSString
        let lineRange = string.lineRange(for: textView.selectedRange())
        var block = string.substring(with: lineRange)
        let endsWithNewline = block.hasSuffix("\n")
        if endsWithNewline { block.removeLast() }
        let lines = block.components(separatedBy: "\n")
        let marker = prefix(0).replacingOccurrences(of: "1. ", with: "")
        let isNumbered = prefix(0) == "1. "
        let alreadyMarked = lines.allSatisfy { line in
            line.isEmpty || (isNumbered ? line.range(of: #"^\d+\. "#, options: .regularExpression) != nil : line.hasPrefix(marker))
        } && lines.contains { !$0.isEmpty }
        var index = 0
        let changed = lines.map { line -> String in
            if alreadyMarked {
                if let r = line.range(of: isNumbered ? #"^\d+\. "# : NSRegularExpression.escapedPattern(for: marker), options: .regularExpression) {
                    return String(line[r.upperBound...])
                }
                return line
            }
            guard !line.isEmpty || lines.count == 1 else { return line }
            // Replace a different list or heading marker instead of stacking two.
            var body = line
            let ns = line as NSString
            if let match = listPrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                body = ns.substring(with: match.range(at: 1)) + ns.substring(from: match.range.upperBound)
            }
            let indent = body.prefix { $0 == " " || $0 == "\t" }
            defer { index += 1 }
            return indent + prefix(index) + body.dropFirst(indent.count)
        }
        let result = changed.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        textView.insertText(result, replacementRange: lineRange)
        let length = (result as NSString).length - (endsWithNewline ? 1 : 0)
        textView.setSelectedRange(lines.count == 1 ? NSRange(location: lineRange.location + length, length: 0)
                                                   : NSRange(location: lineRange.location, length: length))
    }

    private static let continuable = try! NSRegularExpression(pattern: #"^(\s*)([-*+] \[[ xX]\] |[-*+] |(\d+)\. |> )"#)

    /// Return in a list item starts the next item; Return on an empty item ends the list.
    static func continueList(in textView: NSTextView) -> Bool {
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let lineRange = string.lineRange(for: NSRange(location: selection.location, length: 0))
        let lineStart = lineRange.location
        let line = string.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        let ns = line as NSString
        guard let match = continuable.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return false }
        let rest = ns.substring(from: match.range.upperBound)
        let fullLine = string.substring(with: lineRange).trimmingCharacters(in: .newlines)
        if rest.trimmingCharacters(in: .whitespaces).isEmpty && (fullLine as NSString).length == ns.length {
            // Empty item: remove its marker and stop the list.
            textView.insertText("", replacementRange: NSRange(location: lineStart, length: match.range.length))
            return true
        }
        let indent = ns.substring(with: match.range(at: 1))
        var marker = ns.substring(with: match.range(at: 2))
        if match.range(at: 3).location != NSNotFound, let n = Int(ns.substring(with: match.range(at: 3))) {
            marker = "\(n + 1). "
        } else if marker.contains("[") {
            marker = String(marker.prefix(2)) + "[ ] "
        }
        textView.insertText("\n" + indent + marker, replacementRange: selection)
        return true
    }
}

// MARK: - Preview

/// The text with its Markdown formatting shown: headings, lists, checkboxes, quotes, code and
/// inline marks. Read-only but selectable.
struct MarkdownPreview: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = ScratchpadEditor.inset
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? NSTextView)?.textStorage?.setAttributedString(Self.render(text))
    }

    static func render(_ markdown: String) -> NSAttributedString {
        let base = ScratchpadEditor.fontSize
        let out = NSMutableAttributedString()
        var inCode = false
        let lines = markdown.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let newline = i < lines.count - 1 ? "\n" : ""
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode {
                out.append(NSAttributedString(string: raw + newline, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: base - 1, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.quaternaryLabelColor,
                ]))
                continue
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 4
            var font = NSFont.systemFont(ofSize: base)
            var color = NSColor.labelColor
            var lead = ""
            var body = raw
            var strike = false
            let indentWidth: CGFloat = 20

            if let r = raw.range(of: #"^#{1,6} "#, options: .regularExpression) {
                let level = raw[r].count - 1
                let sizes: [CGFloat] = [1.6, 1.35, 1.18, 1.08, 1.0, 1.0]
                font = .systemFont(ofSize: (base * sizes[level - 1]).rounded(), weight: level <= 2 ? .bold : .semibold)
                body = String(raw[r.upperBound...])
                paragraph.paragraphSpacingBefore = 6
            } else if let r = raw.range(of: #"^\s*[-*+] \[[ xX]\] "#, options: .regularExpression) {
                let done = raw[r].lowercased().contains("[x]")
                lead = done ? "☑\t" : "☐\t"
                strike = done
                if done { color = .secondaryLabelColor }
                body = String(raw[r.upperBound...])
            } else if let r = raw.range(of: #"^\s*[-*+] "#, options: .regularExpression) {
                lead = "•\t"
                body = String(raw[r.upperBound...])
            } else if let r = raw.range(of: #"^\s*\d+\. "#, options: .regularExpression) {
                lead = raw[r].trimmingCharacters(in: .whitespaces) + "\t"
                body = String(raw[r.upperBound...])
            } else if let r = raw.range(of: #"^\s*> ?"#, options: .regularExpression) {
                lead = "┃\t"
                color = .secondaryLabelColor
                body = String(raw[r.upperBound...])
            } else if trimmed.range(of: #"^([-*_])( ?\1){2,}$"#, options: .regularExpression) != nil {
                out.append(NSAttributedString(string: String(repeating: "─", count: 30) + newline,
                                              attributes: [.foregroundColor: NSColor.separatorColor, .font: font]))
                continue
            }
            if !lead.isEmpty {
                let level = CGFloat(raw.prefix { $0 == " " || $0 == "\t" }.count / 2)
                paragraph.headIndent = indentWidth * (level + 1)
                paragraph.firstLineHeadIndent = indentWidth * level
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indentWidth * (level + 1))]
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            out.append(NSAttributedString(string: lead, attributes: attributes))
            if strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(inline(body, attributes: attributes))
            out.append(NSAttributedString(string: newline, attributes: attributes))
        }
        return out
    }

    /// Bold, italic, strikethrough, code and links inside a line.
    private static func inline(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: text, attributes: attributes)
        }
        let out = NSMutableAttributedString()
        let baseFont = attributes[.font] as? NSFont ?? .systemFont(ofSize: ScratchpadEditor.fontSize)
        for run in parsed.runs {
            var attrs = attributes
            let intent = run.inlinePresentationIntent ?? []
            var font = baseFont
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)
                attrs[.backgroundColor] = NSColor.quaternaryLabelColor
            }
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty {
                font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)),
                              size: font.pointSize) ?? font
            }
            attrs[.font] = font
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        return out
    }
}
