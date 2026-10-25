import Foundation

@main struct UpdateTests {
    static func main() throws {
        precondition(AppVersion("1.10.0")! > AppVersion("1.9.0")!)
        precondition(AppVersion("v1.2") == AppVersion("1.2.0"))
        precondition(AppVersion("1.2.0-beta") == nil)
        func data(_ url: String, name: String = "HomeswiftWingman-1.2.0.dmg") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["tag_name": "v1.2.0", "html_url": "https://github.com/mp-consulting/homeswift-wingman/releases/tag/v1.2.0", "assets": [["name": name, "browser_download_url": url]]])
        }
        let good = "https://github.com/mp-consulting/homeswift-wingman/releases/download/v1.2.0/HomeswiftWingman-1.2.0.dmg"
        let release = try Release(gitHubJSON: data(good))
        precondition(release.version == AppVersion("1.2.0"))
        for url in ["https://evil.test/update.dmg", "http://github.com/mp-consulting/homeswift-wingman/releases/download/update.dmg", "https://github.com/mp-consulting/other/releases/download/update.dmg"] {
            do { _ = try Release(gitHubJSON: data(url)); fatalError("Accepted foreign update") }
            catch Release.Failure.noDiskImage { }
        }
        do { _ = try Release(gitHubJSON: data(good, name: "Other.dmg")); fatalError("Accepted wrong asset") }
        catch Release.Failure.noDiskImage { }
        do { _ = try Release(gitHubJSON: Data("{}".utf8)); fatalError("Accepted malformed response") }
        catch Release.Failure.unreadable { }
        let now = Date()
        precondition(UpdateSchedule.isDue(lastCheck: nil, now: now))
        precondition(!UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        precondition(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-90000), now: now))
        precondition(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
        print("PASS: update versions, release assets, foreign download rejection and daily schedule")
    }
}
