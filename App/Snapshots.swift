import UIKit

/// `--snapshot DIR` (an argument of the app): opens the window, draws each tab in dark and light to PNG, then quits.
/// For the README and design work. The Bridges tab is drawn a second time with a made-up bridge and pairing code
/// (`panel-bridges-demo`), so the pairing block shows without pairing anything.
@MainActor
enum Snapshots {
    static func render(_ panel: PanelModel, to folder: URL, open: () -> Void) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Let HomeKit load the homes first.
        try? await Task.sleep(for: .seconds(5))
        open()
        try? await Task.sleep(for: .seconds(2))
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0.delegate as? SceneDelegate)?.window }).first else {
            NSLog("Wingman: no window to snapshot")
            exit(1)
        }
        let real = panel.data
        var demo = real
        demo["serving"] = true
        demo["pairingCode"] = "482913"
        demo["pairingUntil"] = Date().addingTimeInterval(9 * 60 + 41).timeIntervalSince1970
        demo["fingerprint"] = String(repeating: "3f9a0c71", count: 8)
        demo["bridges"] = [["id": "demo", "name": "Synology DS923+", "pairedAt": Date().addingTimeInterval(-86_400 * 3).timeIntervalSince1970,
                            "lastSeenAt": Date().addingTimeInterval(-40).timeIntervalSince1970]]
        demo["headline"] = "Serving 1 bridge on port 8619"
        demo["level"] = "ok"
        for (style, suffix) in [(UIUserInterfaceStyle.dark, ""), (.light, "-light")] {
            window.overrideUserInterfaceStyle = style
            for tab in PanelTab.allCases {
                panel.tab = tab
                await save(window, to: folder.appendingPathComponent("panel-\(tab.rawValue.lowercased())\(suffix).png"))
            }
            panel.data = demo
            panel.tab = .bridges
            await save(window, to: folder.appendingPathComponent("panel-bridges-demo\(suffix).png"))
            panel.data = real
        }
        exit(0)
    }

    private static func save(_ window: UIWindow, to url: URL) async {
        try? await Task.sleep(for: .milliseconds(700))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: url)
    }
}
