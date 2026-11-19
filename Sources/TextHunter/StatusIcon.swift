import Cocoa

/// The menu bar icon. It is drawn by an image view inside the status button because SF Symbol
/// transitions (replace, wiggle, pulse) are only animated by NSImageView.
final class StatusIcon {
    let item: NSStatusItem
    private let imageView = PassthroughImageView()
    private let normal = StatusIcon.symbol("text.viewfinder")
    private let done = StatusIcon.symbol("checkmark")
    private var revert: DispatchWorkItem?
    private var pulse: DispatchWorkItem?

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let button = item.button!
        button.setAccessibilityLabel("TextHunter")
        imageView.image = normal
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
    }

    private static func symbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
        image.isTemplate = true
        return image
    }

    /// Recognition started. Pulses gently only if it takes long enough to notice.
    func beginWorking() {
        revert?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.imageView.addSymbolEffect(.pulse, options: .repeating)
        }
        pulse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func endWorking() {
        pulse?.cancel()
        pulse = nil
        imageView.removeAllSymbolEffects(animated: true)
    }

    /// Text copied: the icon turns into a check mark, then back.
    func showSuccess() {
        endWorking()
        imageView.setSymbolImage(done, contentTransition: .replace.downUp.wholeSymbol)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.imageView.setSymbolImage(self.normal, contentTransition: .replace.upUp.wholeSymbol)
        }
        revert = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// No text in the selected area: a short wiggle, the clipboard is left alone.
    func showNothingFound() {
        endWorking()
        if imageView.image !== normal {
            imageView.setSymbolImage(normal, contentTransition: .replace)
        }
        imageView.addSymbolEffect(.wiggle.left, options: .nonRepeating)
    }
}

/// Lets clicks through to the status button underneath.
private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
