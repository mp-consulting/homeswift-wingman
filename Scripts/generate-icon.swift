import AppKit

/// Run: swiftc MenuBar/WingmanIcon.swift Scripts/generate-icon.swift -o /tmp/wingman-icon && /tmp/wingman-icon
@main struct GenerateIcon {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: "App/Assets.xcassets")
        let folder = root.appendingPathComponent("AppIcon.appiconset")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var images: [[String: String]] = []
        func render(_ pixels: Int, filename: String, mac: Bool = true) throws {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: mac ? 4 : 3, hasAlpha: mac, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            let inset = mac ? Double(pixels) * 0.05 : 0
            WingmanIcon.badge(in: NSRect(x: inset, y: inset, width: Double(pixels) - inset * 2, height: Double(pixels) - inset * 2), rounded: mac)
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(filename))
        }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let file = "icon-\(size)@\(scale)x.png"
                try render(size * scale, filename: file)
                images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": file])
            }
        }
        try render(1024, filename: "icon-1024.png", mac: false)
        images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-1024.png"])
        let info: [String: Any] = ["author": "xcode", "version": 1]
        try JSONSerialization.data(withJSONObject: ["images": images, "info": info], options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("Contents.json"))
        try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("Contents.json"))
    }
}
