import SwiftUI

/// What changed in this version of Brighter Pocket Companion (pocket/patches/0034): its
/// section of CHANGELOG.md, which the app carries. Shown once after the app updates
/// itself (not on a first install, which opens on the welcome), and from Help > What's New.
@MainActor @Observable
final class WhatsNew {
    static let shared = WhatsNew()
    private static let seenKey = "WhatsNewSeenVersion"

    var isShown = false

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    /// This version's notes, or the newest section there is (a development build is
    /// often ahead of its changelog).
    var notes: ChangelogSection? {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let sections = ChangelogSection.parse(text)
        return sections.first { $0.version == version } ?? sections.first { !$0.lines.isEmpty }
    }

    /// At launch: once for each new version, never on the first one.
    func showIfUpdated() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil, !version.isEmpty else { return }
        let defaults = UserDefaults.standard
        let seen = defaults.string(forKey: Self.seenKey)
        defaults.set(version, forKey: Self.seenKey)
        if let seen, seen != version, notes != nil { isShown = true }
    }
}

/// One "## [version] - date" section of a Keep a Changelog file.
struct ChangelogSection: Equatable {
    var version: String
    var date: String
    var lines: [String]

    static func parse(_ text: String) -> [ChangelogSection] {
        var sections: [ChangelogSection] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("## ["), let close = line.firstIndex(of: "]") {
                let version = String(line[line.index(line.startIndex, offsetBy: 4)..<close])
                let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                let date = rest.hasPrefix("-") ? String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) : rest
                sections.append(ChangelogSection(version: version, date: date, lines: []))
            } else if line.hasPrefix("[") && line.contains("]: ") {
                continue   // a link reference at the end of the file
            } else if !sections.isEmpty {
                sections[sections.count - 1].lines.append(line)
            }
        }
        // Continuation lines join the bullet above them; blank lines go.
        return sections.map { section in
            var joined: [String] = []
            for line in section.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if line.hasPrefix(" "), let last = joined.last, last.hasPrefix("- ") {
                    joined[joined.count - 1] = last + " " + trimmed
                } else {
                    joined.append(trimmed)
                }
            }
            var section = section
            section.lines = joined
            return section
        }.filter { $0.version.lowercased() != "unreleased" || !$0.lines.isEmpty }
    }
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    var section: ChangelogSection?
    var version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New").font(.title2.bold())
                    Text("Brighter Pocket Companion \(version)").foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let section {
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                            Self.row(line)
                        }
                    } else {
                        Text("No notes for this version.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(minHeight: 160, maxHeight: 360)
            HStack {
                Link("All Releases", destination: URL(string: "https://github.com/joenye/brighter-pocket/releases")!)
                Spacer()
                Button("Continue") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder private static func row(_ line: String) -> some View {
        if line.hasPrefix("### ") {
            Text(String(line.dropFirst(4))).font(.headline).padding(.top, 4)
        } else if line.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(markdown(String(line.dropFirst(2))))
            }
        } else {
            Text(markdown(line))
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
