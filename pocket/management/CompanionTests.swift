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
