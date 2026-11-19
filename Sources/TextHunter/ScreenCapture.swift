import Cocoa

enum ScreenCapture {
    /// Shows the native macOS area selection (the same as ⇧⌘4) and returns the selected area as an
    /// image, or nil if the selection was cancelled with Esc. The temporary file is deleted at once.
    static func selectArea(completion: @escaping (CGImage?) -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextHunter-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive selection, -x no sound, -o no window shadow (window mode, Space key).
        process.arguments = ["-i", "-x", "-o", url.path]
        process.terminationHandler = { _ in
            let image = loadAndDelete(url)
            DispatchQueue.main.async { completion(image) }
        }
        do {
            try process.run()
        } catch {
            completion(nil)
        }
    }

    /// Reads the image fully into memory, then deletes the file. Image sources decode lazily, so
    /// the pixels must be read before the file is gone (otherwise the image comes back blank).
    static func loadAndDelete(_ url: URL) -> CGImage? {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let lazy = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        // Draw into a fresh bitmap so the result owns its pixels.
        guard let ctx = CGContext(data: nil, width: lazy.width, height: lazy.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return lazy }
        ctx.draw(lazy, in: CGRect(x: 0, y: 0, width: lazy.width, height: lazy.height))
        return ctx.makeImage() ?? lazy
    }
}
