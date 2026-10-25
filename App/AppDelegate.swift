import SwiftUI
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    let store = HomeStore()
    let pairing = Pairing()
    let panel = PanelModel()
    private var server: LocalServer?
    private var menuBar: MenuBarBridge?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Settings.register()
        var problem: String?
        do {
            let server = LocalServer(store: store, pairing: pairing, identity: try Identity.load())
            server.start()
            self.server = server
        } catch {
            // An unsigned build has no keychain access group, so no identity: it serves nothing rather than serving in the clear.
            problem = "No TLS identity: \(error)"
            NSLog("Wingman: \(problem!)")
        }
        let menuBar = MenuBarBridge(store: store, pairing: pairing, server: server, panel: panel, problem: problem)
        self.menuBar = menuBar
        store.onChange = { [weak self] in
            self?.server?.homesChanged()
            self?.menuBar?.refresh()
        }
        pairing.onChange = { [weak self] in self?.menuBar?.refresh() }
        store.onEvent = { [weak self] in self?.server?.eventsArrived() }
        server?.onChange = { [weak self] in self?.menuBar?.refresh() }
        store.start()
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            Task { await Snapshots.render(panel, to: URL(fileURLWithPath: arguments[index + 1]), open: { menuBar.openWindow() }) }
        }
        return true
    }
}

/// The app lives in the menu bar: the window UIKit opens at launch is closed at once, and Wingman's window
/// (`MenuBarBridge.openWindow`) is a scene asked for with `windowActivity`.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    static let windowActivity = "com.mpconsulting.HomeswiftWingman.window"
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene,
              connectionOptions.userActivities.contains(where: { $0.activityType == Self.windowActivity }),
              let delegate = UIApplication.shared.delegate as? AppDelegate
        else {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
            return
        }
        scene.title = "Homeswift Wingman"
        scene.sizeRestrictions?.minimumSize = CGSize(width: 400, height: 600)
        scene.sizeRestrictions?.maximumSize = CGSize(width: 560, height: 1000)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: PanelView(model: delegate.panel))
        window.makeKeyAndVisible()
        self.window = window
    }

    /// Closed windows are not brought back at the next launch.
    func sceneDidDisconnect(_ scene: UIScene) {
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
    }
}
