import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    let store = HomeStore()
    let pairing = Pairing()
    let panel = LoginSettings()
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
        return true
    }
}

/// Catalyst is only the HomeKit host. All UI lives in the AppKit menu-bar panel.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        hideHostWindows(in: scene)
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        hideHostWindows(in: scene)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        hideHostWindows(in: scene)
        // Catalyst can finish restoring its host window after the activation callback.
        // Hide that window on the next main-loop turn as well. The AppKit menu panel
        // is not a UIWindow and is deliberately unaffected.
        DispatchQueue.main.async { [weak self, weak scene] in
            guard let scene else { return }
            self?.hideHostWindows(in: scene)
        }
    }

    private func hideHostWindows(in scene: UIScene) {
        guard let scene = scene as? UIWindowScene else { return }
        for window in scene.windows { window.isHidden = true }
    }
}
