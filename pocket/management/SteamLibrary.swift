import Foundation

/// Where Steam keeps its games on this Mac: its own library in Application
/// Support, then any other library it lists in libraryfolders.vdf (a second
/// drive, say). A game sits in <library>/steamapps/common/<folder>, its app
/// sometimes a folder further down (Brighter Shores keeps its app in x64arm64/).
enum SteamLibrary {
    static var steam: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
    }

    /// The steamapps folders, Steam's own first.
    static func libraries() -> [URL] {
        var roots = [steam]
        let listing = steam.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: listing, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if let match = line.wholeMatch(of: /\s*"path"\s+"([^"]+)"\s*/) {
                    let root = URL(fileURLWithPath: String(match.1), isDirectory: true)
                    if !roots.contains(where: { $0.standardizedFileURL == root.standardizedFileURL }) { roots.append(root) }
                }
            }
        }
        return roots.map { $0.appendingPathComponent("steamapps", isDirectory: true) }
    }

    /// The profile's source folder in a Steam library: common/<destination>,
    /// or a folder in it, that holds the executable.
    static func find(_ profile: AppProfile) -> URL? {
        for library in libraries() {
            let game = library.appendingPathComponent("common", isDirectory: true).appendingPathComponent(profile.destination, isDirectory: true)
            if let folder = profile.folderHoldingExecutable(at: game, ancestors: false) { return folder }
        }
        return nil
    }
}

extension AppProfile {
    /// The folder that holds the executable as the profile expects it: `url`
    /// itself, one of its folders (a game's folder whose app is a level down),
    /// or, with `ancestors`, a folder above it (the app itself was chosen).
    func folderHoldingExecutable(at url: URL, ancestors: Bool = true) -> URL? {
        let fileManager = FileManager.default
        func holds(_ folder: URL) -> Bool { fileManager.isExecutableFile(atPath: executable(inSource: folder).path) }
        if holds(url) { return url }
        let children = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        if let child = children.sorted(by: { $0.path < $1.path }).first(where: holds) { return child }
        guard ancestors else { return nil }
        var candidate = url.deletingLastPathComponent()
        while candidate.path != "/" {
            if holds(candidate) { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}
