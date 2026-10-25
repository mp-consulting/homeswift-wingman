import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    let store = HomeStore()
    private var server: LocalServer?
    private var menuBar: MenuBarBridge?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let port = UInt16(ProcessInfo.processInfo.environment["SIDECAR_PORT"] ?? "") ?? LocalServer.defaultPort
        let server = LocalServer(store: store, port: port)
        server.start()
        self.server = server
        menuBar = MenuBarBridge(store: store, port: port)
        store.onChange = { [weak self] in self?.menuBar?.refresh() }
        store.start()
        return true
    }
}

/// The app lives in the menu bar: the window UIKit opens at launch is closed at once.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
    }
}
