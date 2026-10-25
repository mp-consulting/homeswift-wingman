import ServiceManagement

@MainActor
final class LoginSettings {
    // MARK: Open at login

    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    var launchAtLoginError: String?

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

