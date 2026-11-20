import Cocoa

/// Developer mode: `TextHunter --selftest-scratchpad` checks the Scratchpad's editing helpers
/// (formatting marks, list continuation, clear and undo) on an off-screen text view.
enum ScratchpadSelfTest {
    static func run() -> Bool {
        var failures = 0
        func check(_ name: String, _ got: String, _ expected: String) {
            if got == expected { print("ok    \(name)") } else {
                failures += 1
                print("FAIL  \(name)\n      got:      \(got.debugDescription)\n      expected: \(expected.debugDescription)")
            }
        }
        func view(_ text: String, _ selection: NSRange) -> NSTextView {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            let tv = NSTextView(frame: window.contentView!.bounds)
            tv.isRichText = false
            tv.allowsUndo = true
            window.contentView!.addSubview(tv)
            window.makeFirstResponder(tv)
            tv.string = text
            tv.setSelectedRange(selection)
            return tv
        }

        var tv = view("hello world", NSRange(location: 6, length: 5))
        MarkdownMark.apply(.bold, in: tv)
        check("bold wraps selection", tv.string, "hello **world**")
        check("bold keeps selection", (tv.string as NSString).substring(with: tv.selectedRange()), "world")

        tv = view("abc", NSRange(location: 3, length: 0))
        MarkdownMark.apply(.italic, in: tv)
        check("italic at cursor", tv.string, "abc**")
        check("cursor between marks", "\(tv.selectedRange().location)", "4")

        tv = view("one\ntwo\nthree", NSRange(location: 0, length: 13))
        MarkdownMark.apply(.bullet, in: tv)
        check("bullet lines", tv.string, "- one\n- two\n- three")
        MarkdownMark.apply(.bullet, in: tv)
        check("bullet toggles off", tv.string, "one\ntwo\nthree")
        MarkdownMark.apply(.numbered, in: tv)
        check("numbered lines", tv.string, "1. one\n2. two\n3. three")
        MarkdownMark.apply(.task, in: tv)
        check("checklist replaces numbers", tv.string, "- [ ] one\n- [ ] two\n- [ ] three")

        tv = view("Title\nbody", NSRange(location: 2, length: 0))
        MarkdownMark.apply(.heading, in: tv)
        check("heading on current line", tv.string, "# Title\nbody")
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        MarkdownMark.apply(.heading, in: tv)
        check("heading toggles off", tv.string, "Title\nbody")

        tv = view("- milk", NSRange(location: 6, length: 0))
        check("Return continues bullet", MarkdownMark.continueList(in: tv) ? tv.string : "not handled", "- milk\n- ")
        check("Return on empty item ends list", MarkdownMark.continueList(in: tv) ? tv.string : "not handled", "- milk\n")

        tv = view("3. c", NSRange(location: 4, length: 0))
        _ = MarkdownMark.continueList(in: tv)
        check("Return numbers next item", tv.string, "3. c\n4. ")

        tv = view("- [x] done", NSRange(location: 10, length: 0))
        _ = MarkdownMark.continueList(in: tv)
        check("Return adds an unchecked box", tv.string, "- [x] done\n- [ ] ")

        tv = view("plain", NSRange(location: 5, length: 0))
        check("Return in plain text is normal", MarkdownMark.continueList(in: tv) ? "handled" : "normal", "normal")

        tv = view("- item", NSRange(location: 3, length: 0))
        _ = MarkdownMark.continueList(in: tv)
        check("Return mid-item splits it", tv.string, "- i\n- tem")

        // Clear through the text view, then undo.
        let pad = ScratchpadController.shared
        pad.savingDisabled = true
        tv = view("keep me", NSRange(location: 0, length: 0))
        pad.textView = tv
        pad.text = "keep me"
        pad.clear()
        check("clear empties the text", tv.string, "")
        tv.undoManager?.undo()
        check("undo brings it back", tv.string, "keep me")

        let rendered = MarkdownPreview.render("# H\n- [x] a **b**").string
        check("preview text", rendered, "H\n☑\ta b")

        // Shortcuts: the bare binary keeps its own defaults (domain "TextHunter"), not the app's.
        let prefs = Prefs.shared
        let capture = prefs.shortcut(for: .capture)
        let free = Shortcut(keyCode: 40, modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue) // ⌃⌥⌘K
        let oldPad = prefs.shortcut(for: .scratchpad)
        prefs.proposeShortcut(free, for: .scratchpad)
        check("free keys become the Scratchpad shortcut", prefs.shortcut(for: .scratchpad).displayString, free.displayString)
        check("capture shortcut unchanged", prefs.shortcut(for: .capture).displayString, capture.displayString)
        check("Scratchpad hot key registered", HotKeyManager.shared.current[.scratchpad]?.displayString ?? "none", free.displayString)
        prefs.proposeShortcut(capture, for: .scratchpad)
        check("capture's keys are refused for the Scratchpad", prefs.shortcut(for: .scratchpad).displayString, free.displayString)
        check("refusal says why", prefs.shortcutStatus?.message.contains("Start Capture") == true ? "yes" : (prefs.shortcutStatus?.message ?? "none"), "yes")
        check("refusal shows under the Scratchpad field", prefs.shortcutStatus?.action == .scratchpad ? "yes" : "no", "yes")
        prefs.proposeShortcut(oldPad, for: .scratchpad)
        // While TextHunter itself runs, it owns those keys exclusively, and the refusal is the right answer.
        let restored = prefs.shortcut(for: .scratchpad) == oldPad
        let ownedElsewhere = prefs.shortcutStatus?.message.contains("used by another app") == true
        check("back to the previous shortcut (or told it's taken)", restored || ownedElsewhere ? "yes" : "no", "yes")
        UserDefaults.standard.removeObject(forKey: ShortcutAction.scratchpad.defaultsKey)

        print(failures == 0 ? "All Scratchpad checks passed." : "\(failures) Scratchpad check(s) failed.")
        return failures == 0
    }
}
