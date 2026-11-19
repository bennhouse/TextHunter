import Cocoa
import SwiftUI

// Developer mode: `TextHunter --ocr <image> [--raw] [--plain]` prints the text the app would copy
// and exits, so recognition and line joining can be checked without the interactive capture.
let args = CommandLine.arguments
if args.count >= 3, args[1] == "--ocr" {
    guard let image = NSImage(contentsOfFile: args[2])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("Cannot read image \(args[2])\n".data(using: .utf8)!)
        exit(1)
    }
    let lines = (try? TextRecognizer.recognize(image, labelSpecialText: !args.contains("--plain"))) ?? []
    print(ParagraphJoiner.text(from: lines, joinWrappedLines: !args.contains("--raw")))
    exit(0)
}

// Developer mode: `TextHunter --render-settings <png> [--conflict | --welcome]` draws the Settings (or Welcome) window
// to an image, to check the layout.
if args.count >= 3, args[1] == "--render-settings" {
    _ = NSApplication.shared
    if args.contains("--conflict") {
        Prefs.shared.proposeShortcut(Shortcut(keyCode: 21, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue))
    }
    let host: NSView = args.contains("--welcome") ? NSHostingView(rootView: WelcomeView {}) : NSHostingView(rootView: SettingsView())
    let size = host.fittingSize
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.layoutIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
