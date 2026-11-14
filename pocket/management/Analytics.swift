import AppKit

/// Anonymous usage counts for Brighter Pocket Companion, through Umami (Joe, 2026-11-14: how many people
/// download and use it, which setup step they reach and where they stop), wired in by pocket/patches/0041.
///
/// Each count is an event sent to Umami Cloud, to Brighter Atlas's website under the companion's own
/// hostname (brighteratlas.com's page counts are webapp/src/analytics.ts in brighter-atlas): the step on
/// screen as a page view (/companion/<step>, so Umami's funnels show where people stop), and a few named
/// events with small values: the companion opened, a job's outcome (install, copy, pairing) with the title
/// of its diagnosis, the kind of Apple Account and device chosen. Never an Apple Account, team or device
/// name, an email, a Steam account, a path or anything of the game's. Umami keeps no cookies and tells
/// visits apart by a hash that changes daily. On by default; Settings turns it off (`AnonymousUsageCounts`
/// in the defaults), and it is off while tests host the app and with BRIGHTER_POCKET_NO_ANALYTICS=1.
/// A send that fails is never noticed.
@MainActor @Observable
final class Analytics {
    static let shared = Analytics()

    nonisolated static let defaultsKey = "AnonymousUsageCounts"
    private static let endpoint = URL(string: "https://gateway.umami.is/api/send")!
    private static let website = "ed0c3362-b0f0-4045-85ef-66e465141ddb"
    private static let hostname = "companion.brighteratlas.com"

    /// The switch in Settings.
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.defaultsKey) }
    }

    @ObservationIgnored private let blocked: Bool
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var lastStep: String?

    private init() {
        let environment = ProcessInfo.processInfo.environment
        blocked = environment["XCTestConfigurationFilePath"] != nil || environment["BRIGHTER_POCKET_NO_ANALYTICS"] == "1"
        enabled = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    nonisolated static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// The step on screen, as a page view (once each time it changes).
    func step(_ name: String) {
        guard name != lastStep else { return }
        lastStep = name
        send(url: "/companion/\(name)", name: nil, data: nil)
    }

    /// A named event with a few small values (strings, numbers, booleans; nothing that names a person).
    func event(_ name: String, _ data: [String: Any] = [:]) {
        send(url: "/companion/\(lastStep ?? "app")", name: name, data: data.isEmpty ? nil : data)
    }

    private func send(url: String, name: String?, data: [String: Any]?) {
        guard enabled, !blocked else { return }
        let screen = NSScreen.main?.frame.size ?? .zero
        var payload: [String: Any] = [
            "website": Self.website,
            "hostname": Self.hostname,
            "language": Locale.preferredLanguages.first ?? "en",
            "screen": "\(Int(screen.width))x\(Int(screen.height))",
            "title": "Brighter Pocket Companion",
            "url": url,
        ]
        if let name { payload["name"] = name }
        if let data { payload["data"] = data }
        guard let body = try? JSONSerialization.data(withJSONObject: ["type": "event", "payload": payload]) else { return }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // (a browser-like agent naming the app: Umami turns away agents it takes for bots, and reads the OS from it)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        request.setValue("Mozilla/5.0 (Macintosh; Mac OS X \(os.majorVersion)_\(os.minorVersion)) AppleWebKit/605.1.15 "
                         + "(KHTML, like Gecko) BrighterPocketCompanion/\(Self.version)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { _, _, _ in }.resume()
    }
}
