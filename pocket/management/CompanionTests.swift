import XCTest
@testable import Tolkara_Management

/// Brighter Pocket Companion's own updates and release notes (pocket/patches/0034).
final class CompanionTests: XCTestCase {
    func testChangelogSections() {
        let text = """
        # Changelog

        Intro text.

        ## [Unreleased]

        ## [0.2.0] - 2026-12-01

        ### Added

        - One thing, which goes on
          over two lines.
        - Another.

        ## [0.1.0] - 2026-11-20

        ### Fixed

        - A fix.

        [0.2.0]: https://example.com
        """
        let sections = ChangelogSection.parse(text)
        XCTAssertEqual(sections.map(\.version), ["0.2.0", "0.1.0"])
        XCTAssertEqual(sections[0].date, "2026-12-01")
        XCTAssertEqual(sections[0].lines, ["### Added", "- One thing, which goes on over two lines.", "- Another."])
        XCTAssertEqual(sections[1].lines, ["### Fixed", "- A fix."])
    }

    func testTheRepositoryChangelogHasThisVersion() throws {
        let url = try XCTUnwrap(Bundle(for: Updater.self).url(forResource: "CHANGELOG", withExtension: "md")
            ?? Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"), "the app carries CHANGELOG.md")
        let sections = ChangelogSection.parse(try String(contentsOf: url, encoding: .utf8))
        let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        if version.first?.isNumber == true, version != "0.0" {
            XCTAssertTrue(sections.contains { $0.version == version && !$0.lines.isEmpty }, "CHANGELOG.md has notes for \(version)")
        }
    }

    func testSparkleKeys() {
        XCTAssertTrue(Updater.isEdKey("pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ="))
        XCTAssertFalse(Updater.isEdKey(""))
        XCTAssertFalse(Updater.isEdKey("$(POCKET_SPARKLE_PUBLIC_KEY)"))
        XCTAssertFalse(Updater.isEdKey("c2hvcnQ="))
    }

    @MainActor func testUpdatesAreOffWhileTestsHostTheApp() {
        XCTAssertFalse(Updater.shared.isAvailable)
    }
}

/// The plain-words failures and the weekly renewal (pocket/patches/0037).
final class GuidanceTests: XCTestCase {
    func testNarrowCausesComeFirst() {
        // A free account's log names "Personal Team" whatever went wrong: the narrow cause wins.
        let threeApps = "error: Personal Team \"Me\": The maximum number of apps for free development profiles has been reached."
        XCTAssertEqual(Diagnoser.diagnose(threeApps, source: nil)?.title, "Your free Apple Account has 3 apps already")
        XCTAssertEqual(Diagnoser.diagnose("Your maximum App ID limit has been reached. You may create up to 10 App IDs every 7 days.", source: nil)?.title,
                       "Apple's weekly limit for new apps is reached")
        XCTAssertEqual(Diagnoser.diagnose("iOS 27.2 is not installed. To use with Xcode, first download and install the platform", source: nil)?.step, .mac)
        XCTAssertEqual(Diagnoser.diagnose("error: Provisioning profile \"iOS Team Provisioning Profile\" has expired.", source: nil)?.step, .install)
        XCTAssertEqual(Diagnoser.diagnose("The app has not been explicitly trusted by the user.", source: nil)?.title,
                       "Your iPhone or iPad does not trust your Apple Account yet")
    }

    func testThePersonalTeamRuleSkipsAFreeTeam() {
        let refusal = "error: Personal development teams, including \"Me\", do not support the Network Extensions capability."
        XCTAssertEqual(Diagnoser.diagnose(refusal, source: nil)?.step, .membership)
        XCTAssertNil(Diagnoser.diagnose(refusal, source: nil, freeTeam: true))
    }

    func testNoPlayerTextNamesDeveloperService() {
        for text in ["Enrollment did not complete", "free provisioning", "is locked"] {
            let advice = Diagnoser.diagnose(text, source: nil).map { $0.title + " " + $0.advice } ?? ""
            XCTAssertFalse(advice.localizedCaseInsensitiveContains("developer service"), advice)
            XCTAssertFalse(advice.localizedCaseInsensitiveContains("VPN"), advice)
        }
    }

    func testRenewalIsDueTwoDaysAhead() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(SetupModel.renewalDue(expiry: nil, now: now))
        XCTAssertFalse(SetupModel.renewalDue(expiry: now.addingTimeInterval(3 * 86400), now: now))
        XCTAssertTrue(SetupModel.renewalDue(expiry: now.addingTimeInterval(86400), now: now))
        XCTAssertTrue(SetupModel.renewalDue(expiry: now.addingTimeInterval(-60), now: now), "already run out")
    }

    func testSteamAppID() {
        XCTAssertEqual(SetupModel.steamAppID(URL(string: "https://store.steampowered.com/app/2791440/Brighter_Shores/")!), "2791440")
        XCTAssertNil(SetupModel.steamAppID(URL(string: "https://example.com/app/2791440/")!))
        XCTAssertNil(SetupModel.steamAppID(URL(string: "https://store.steampowered.com/about/")!))
    }

    func testStepOrder() {
        XCTAssertEqual(Array(SetupStep.setup.prefix(3)), [.welcome, .mac, .membership], "This Mac (Xcode) comes before signing in to Xcode")
    }
}

/// Brighter Shores only: a state saved when the companion still kept games per
/// profile loads into the one game's fields.
final class OneGameTests: XCTestCase {
    func decode(_ json: String) throws -> SetupState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SetupState.self, from: Data(json.utf8))
    }

    func testAStateFromBeforeLoads() throws {
        let state = try decode("""
        {"welcomed":true,"device":"D","mode":"local-signing","profiles":["brighter-shores"],"riskAccepted":{},
         "sources":{"brighter-shores":"/Games/Brighter Shores","wow-forever":"/Games/WoW"},
         "copied":{"brighter-shores":{"bundleID":"b","device":"D","source":"/Games/Brighter Shores","date":"2026-11-12T10:00:00Z"}},
         "installed":{"commit":"c","team":"T","bundleID":"b","device":"D","profiles":["brighter-shores"],"date":"2026-11-12T09:00:00Z",
                      "executables":{"brighter-shores":"abc"},"mode":"local-signing"}}
        """)
        XCTAssertEqual(state.gameFolder, "/Games/Brighter Shores")
        XCTAssertEqual(state.gameCopy?.source, "/Games/Brighter Shores")
        XCTAssertEqual(state.installed?.executable, "abc")
        XCTAssertEqual(state.installed?.mode, .localSigning)

        // Saved again, it reads back the same, in the new keys only.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let saved = try encoder.encode(state)
        let text = String(decoding: saved, as: UTF8.self)
        for old in ["\"profiles\"", "\"riskAccepted\"", "\"sources\"", "\"copied\"", "\"executables\""] { XCTAssertFalse(text.contains(old), old) }
        XCTAssertEqual(try decode(text), state)
    }

    /// Joe's own state: nothing chosen by hand and nothing copied yet.
    func testAnEmptyStateFromBeforeLoads() throws {
        let state = try decode("""
        {"checkForUpdates":true,"copied":{},"device":"00008160-001C196C14780036","deviceName":"phone","deviceType":"iPhone",
         "mode":"local-signing","profiles":["brighter-shores"],"riskAccepted":{},"sources":{},
         "team":{"evidence":"Provisioning profile","id":"V3J492AP4B","kind":3,"name":"Me (Personal Team)"},"welcomed":false}
        """)
        XCTAssertEqual(state.device, "00008160-001C196C14780036")
        XCTAssertEqual(state.team?.id, "V3J492AP4B")
        XCTAssertNil(state.gameFolder)
        XCTAssertNil(state.gameCopy)
    }
}
